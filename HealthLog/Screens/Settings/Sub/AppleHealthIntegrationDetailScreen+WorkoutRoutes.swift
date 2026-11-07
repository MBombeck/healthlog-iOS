import Observation
import SwiftUI

/// **1.5 ROUTES (#149, server v1.44.0) — "Send routes", under Settings,
/// Apple Health, „Erweitert".**
///
/// Off by default. Turning it on asks Apple Health for the route permission
/// (the only place that ever happens), then tells the server to keep tracks;
/// only after the server confirmed does this phone start reading routes of new
/// workouts (``WorkoutRouteOptIn``). Turning it off stops reading and sending
/// on this phone first, then tells the server; tracks already stored stay
/// until their workout is deleted, and the card says so.
@MainActor
@Observable
final class WorkoutRoutesSettingModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed
        /// The server has no such setting (older build, module off).
        case unavailable
    }

    enum SaveFailure: Equatable {
        case on
        case off
    }

    /// POLISH-B B10 — the explicit pass for routes of older workouts.
    enum BackfillPhase: Equatable {
        case idle
        case running
        case done(WorkoutRouteBackfillSummary)
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var isOn = false
    private(set) var isSaving = false
    private(set) var saveFailure: SaveFailure?
    private(set) var backfillPhase: BackfillPhase = .idle

    private let service: any WorkoutRoutesSettingServing
    private let ownerUserID: String?
    private let defaults: UserDefaults
    private let requestAuthorization: @Sendable () async throws -> Void
    /// `nil` on a server not known to attach routes to stored workouts
    /// (before v1.47.1): no pass, and the footer keeps "new workouts".
    private let backfill: (@Sendable () async throws -> WorkoutRouteBackfillSummary)?

    init(
        service: any WorkoutRoutesSettingServing,
        ownerUserID: String?,
        defaults: UserDefaults = .standard,
        requestAuthorization: @escaping @Sendable () async throws -> Void,
        backfill: (@Sendable () async throws -> WorkoutRouteBackfillSummary)? = nil
    ) {
        self.service = service
        self.ownerUserID = ownerUserID
        self.defaults = defaults
        self.requestAuthorization = requestAuthorization
        self.backfill = backfill
        isOn = WorkoutRouteOptIn.isOn(ownerUserID: ownerUserID, defaults: defaults)
    }

    /// The server can take routes for older workouts.
    var offersBackfill: Bool {
        backfill != nil
    }

    /// The pass is offered only while the switch is on.
    var showsBackfill: Bool {
        offersBackfill && isOn && phase == .ready
    }

    /// Sends the routes of the last 12 months once, after a tap. Nothing
    /// happens while the switch is off or a pass is running.
    func runBackfill() async {
        guard showsBackfill, backfillPhase != .running, let backfill else { return }
        backfillPhase = .running
        do {
            let summary = try await backfill()
            backfillPhase = .done(summary)
        } catch {
            backfillPhase = .failed
        }
    }

    /// Reads the server's answer. Off there (never on, or turned off on the
    /// web) clears this phone's mark too; on there counts here only once it
    /// was switched on in this app, where the permission was asked.
    func load() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            let answer = try await service.fetch()
            if !answer.storeWorkoutRoutes {
                WorkoutRouteOptIn.set(false, ownerUserID: ownerUserID, defaults: defaults)
            }
            isOn = answer.storeWorkoutRoutes
                && WorkoutRouteOptIn.isOn(ownerUserID: ownerUserID, defaults: defaults)
            phase = .ready
        } catch {
            phase = Self.isUnavailable(error) ? .unavailable : .failed
        }
    }

    func setOn(_ newValue: Bool) async {
        guard !isSaving, newValue != isOn, phase == .ready else { return }
        isSaving = true
        saveFailure = nil
        defer { isSaving = false }
        if newValue {
            await switchOn()
        } else {
            await switchOff()
        }
    }

    private func switchOn() async {
        do {
            try await requestAuthorization()
            let answer = try await service.update(storeWorkoutRoutes: true)
            WorkoutRouteOptIn.set(answer.storeWorkoutRoutes, ownerUserID: ownerUserID, defaults: defaults)
            isOn = answer.storeWorkoutRoutes
            if !answer.storeWorkoutRoutes { saveFailure = .on }
        } catch {
            saveFailure = .on
        }
    }

    /// Local first: the phone stops at once, whatever the request does.
    private func switchOff() async {
        WorkoutRouteOptIn.set(false, ownerUserID: ownerUserID, defaults: defaults)
        isOn = false
        backfillPhase = .idle
        do {
            _ = try await service.update(storeWorkoutRoutes: false)
        } catch {
            saveFailure = .off
        }
    }

    private static func isUnavailable(_ error: any Error) -> Bool {
        switch error as? HLError {
        case .moduleDisabled:
            true
        case let .server(status, _, _):
            status == 404 || status == 405
        default:
            false
        }
    }
}

extension AppleHealthIntegrationDetailScreen {
    /// The „Erweitert" link with the route switch, only where it can work:
    /// a server of v1.44.0 or newer and the workouts module on.
    @ViewBuilder
    var workoutRoutesAdvanced: some View {
        if let container, backend.hasServer,
           WorkoutRouteOptIn.serverSupportsRoutes(),
           container.moduleGate.isEnabled(.workouts)
        {
            AppleHealthWorkoutRoutesAdvanced(makeModel: {
                let healthKit = container.healthKit
                let keychain = container.keychain
                let owner = keychain.getString(forKey: KeychainKey.userID)
                return WorkoutRoutesSettingModel(
                    service: WorkoutRoutesSettingRepository(api: container.api),
                    ownerUserID: owner,
                    requestAuthorization: {
                        try await (healthKit as? HealthKitService)?.requestWorkoutRouteAuthorization()
                    },
                    backfill: Self.routeBackfill(
                        healthKit: healthKit as? HealthKitService,
                        repository: container.serverStatsRepos.workouts,
                        ownerUserID: owner
                    )
                )
            })
        }
    }
}

extension AppleHealthIntegrationDetailScreen {
    /// POLISH-B B10 — the pass for older workouts, only on a server of
    /// v1.47.1 or newer and for a signed-in account.
    static func routeBackfill(
        healthKit: HealthKitService?,
        repository: WorkoutsRepository,
        ownerUserID: String?
    ) -> (@Sendable () async throws -> WorkoutRouteBackfillSummary)? {
        guard let healthKit, let ownerUserID, !ownerUserID.isEmpty,
              WorkoutRouteBackfill.serverSupportsBackfill() else { return nil }
        let pass = WorkoutRouteBackfill.live(store: healthKit.store, repository: repository, ownerUserID: ownerUserID)
        return { try await pass.run() }
    }
}

/// The centred „Erweitert" link and, once open, the route card.
struct AppleHealthWorkoutRoutesAdvanced: View {
    let makeModel: @MainActor () -> WorkoutRoutesSettingModel
    @State private var expanded = false
    @State private var model: WorkoutRoutesSettingModel?

    var body: some View {
        VStack(spacing: HLSpace.sm) {
            Button {
                withHLAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Text("Advanced")
                        .font(.hlSubhead.weight(.semibold))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.hlIcon(HLIconSize.sm))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(HLText.secondary)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.applehealth.advanced")
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded, let model {
                WorkoutRoutesCard(model: model)
                    .transition(.opacity)
            }
        }
        .task(id: expanded) {
            guard expanded else { return }
            let model = model ?? makeModel()
            self.model = model
            if model.phase == .idle || model.phase == .failed {
                await model.load()
            }
        }
    }
}

/// The card itself, store-free so the render tests drive every state.
struct WorkoutRoutesCard: View {
    let model: WorkoutRoutesSettingModel

    var body: some View {
        HLSettingsCard(
            icon: "map",
            title: "settings.applehealth.routes.title",
            subtitle: "settings.applehealth.routes.subtitle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                switch model.phase {
                case .idle, .loading:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, HLSpace.sm)
                case .ready:
                    readyContent
                case .failed:
                    failedContent
                case .unavailable:
                    Text("settings.applehealth.routes.unavailable")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // No identifier on the card: on a container it would replace the
        // toggle's own `settings.applehealth.routes.toggle`.
    }

    @ViewBuilder
    private var readyContent: some View {
        HLSettingsToggleRow(
            title: "settings.applehealth.routes.toggle",
            description: model.offersBackfill
                ? "settings.applehealth.routes.footer.backfill"
                : "settings.applehealth.routes.footer",
            isOn: Binding(
                get: { model.isOn },
                set: { newValue in Task { await model.setOn(newValue) } }
            ),
            isBusy: model.isSaving,
            isEnabled: !model.isSaving,
            accessibilityID: "settings.applehealth.routes.toggle"
        )
        if let failure = model.saveFailure {
            Text(failure == .on ? "settings.applehealth.routes.error.on" : "settings.applehealth.routes.error.off")
                .font(.hlCaption)
                .foregroundStyle(HLColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.applehealth.routes.error")
        }
        if model.showsBackfill {
            backfillContent
        }
    }

    /// POLISH-B B10 — "Send routes of older workouts", after a tap only.
    @ViewBuilder
    private var backfillContent: some View {
        let running = model.backfillPhase == .running
        HLButton(
            "settings.applehealth.routes.backfill.action",
            icon: "arrow.up.circle",
            variant: .secondary,
            size: .regular,
            isLoading: running
        ) {
            Task { await model.runBackfill() }
        }
        .disabled(running)
        .accessibilityIdentifier("settings.applehealth.routes.backfill")
        if let line = Self.backfillLine(model.backfillPhase) {
            Text(verbatim: line)
                .font(.hlCaption)
                .foregroundStyle(model.backfillPhase == .failed ? HLColor.statusBad : HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.applehealth.routes.backfill.result")
        }
    }

    /// The one line under the button, from the counts the server answered.
    static func backfillLine(_ phase: WorkoutRoutesSettingModel.BackfillPhase) -> String? {
        switch phase {
        case .idle:
            nil
        case .running:
            String(localized: "settings.applehealth.routes.backfill.running")
        case let .done(summary) where summary.attached > 0:
            String(localized: "settings.applehealth.routes.backfill.done \(summary.attached)")
        case .done:
            String(localized: "settings.applehealth.routes.backfill.none")
        case .failed:
            String(localized: "settings.applehealth.routes.backfill.failed")
        }
    }

    @ViewBuilder
    private var failedContent: some View {
        Text("settings.applehealth.routes.error.load")
            .font(.hlCaption)
            .foregroundStyle(HLColor.statusBad)
            .fixedSize(horizontal: false, vertical: true)
        HLButton(String(localized: "Try again"), icon: "arrow.clockwise", variant: .secondary, size: .regular) {
            Task { await model.load() }
        }
        .accessibilityIdentifier("settings.applehealth.routes.retry")
    }
}
