import SwiftUI
#if canImport(UserNotifications) && canImport(UIKit)
    import UserNotifications

    /// **Phase 08 Plan 15 — where engineering detail lives now.**
    ///
    /// The notification and Apple-Health diagnostics screens keep everything a
    /// user can act on: is the permission granted, does a test banner arrive,
    /// how many samples were read and uploaded, when did the last sync run.
    /// What moved here is the half that only means something to somebody
    /// reading a server log next to you — device-token fragments, the APNs
    /// environment, banner-category identifiers, pending local-request
    /// identifiers, background wake timestamps and per-kind HealthKit anchors.
    ///
    /// **The gate is the screen, and the screen is the session.** The session is
    /// a view-local `@State` value (see ``SupportDiagnosticsSession``), so it is
    /// created `.locked` on every mount, dies on `onDisappear`, and cannot be
    /// reached by anything this view does not hand it. Logout unmounts the whole
    /// authenticated shell and a cold launch builds a new one, which is why
    /// there is no separate teardown to forget.
    ///
    /// **Read-only, and no request of its own.** Nothing here writes, uploads,
    /// re-schedules or mutates health data, and appearing on this screen issues
    /// no network call — every value is read from an in-memory snapshot or from
    /// `UNUserNotificationCenter`. The single exception is deliberate and
    /// user-initiated: re-registering the APNs token, which is the support
    /// action a stuck registration needs and which touches no health record.
    struct SettingsSupportDiagnosticsScreen: View {
        /// Which surface asked for support detail. The gate and the session are
        /// identical for both; only the detail below them differs.
        enum Topic: String, Equatable, Sendable {
            case notifications
            case appleHealth
        }

        let topic: Topic

        @Environment(\.appContainer) private var container
        /// The gate. View-local by construction — never injected, never stored.
        @State private var supportSession = SupportDiagnosticsSession()
        @State private var lastRegistration: NotificationService.LastRegistrationSnapshot?
        @State private var categoryRows: [CategoryDetail] = []
        @State private var pendingIdentifiers: [String] = []
        @State private var forceFreshInFlight: Bool = false
        @State private var forceFreshError: String?
        @State private var diagnostics = HKSyncDiagnostics.shared

        var body: some View {
            HLSettingsPage(title: "settings.support.title") {
                gateCard
                if supportSession.isConfirmed {
                    switch topic {
                    case .notifications:
                        registrationCard
                        categoriesCard
                        pendingIdentifiersCard
                    case .appleHealth:
                        wakeChannelsCard
                        anchorsCard
                    }
                }
            }
            .navigationTitle("settings.support.title")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadLocalSnapshot() }
            .onDisappear { endSession() }
        }

        // MARK: - The gate

        /// Two steps, always. The first states what a session exposes and how
        /// long it lasts; the second is the act. Cancelling returns to `.locked`
        /// rather than to some half state.
        private var gateCard: some View {
            HLSettingsCard(
                icon: "lifepreserver",
                title: "settings.support.gate_title",
                subtitle: "settings.support.gate_body"
            ) {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if supportSession.isAwaitingConfirmation {
                        Text("settings.support.gate_consequence")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.supportDiagnostics.consequence")
                        HStack(spacing: HLSpace.md) {
                            Button("settings.support.gate_confirm") { supportSession.confirm() }
                                .font(.hlSubhead.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("settings.supportDiagnostics.confirm")
                            Button("settings.support.gate_cancel") { endSession() }
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("settings.supportDiagnostics.cancel")
                        }
                    } else if supportSession.isConfirmed {
                        Button("settings.support.gate_end") { endSession() }
                            .font(.hlSubhead)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("settings.supportDiagnostics.end")
                    } else {
                        Button("settings.support.gate_start") { supportSession.requestConfirmation() }
                            .font(.hlSubhead.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("settings.supportDiagnostics.start")
                    }
                }
            }
        }

        // MARK: - Notification detail

        private var registrationCard: some View {
            HLSettingsCard(
                icon: "antenna.radiowaves.left.and.right",
                title: "APNs registration",
                footer: "Shows the last POST /api/devices. Token prefix + suffix are enough to find the server log entry — the full token is never stored."
            ) {
                let snap = lastRegistration
                SupportDetailRow(
                    title: "Token prefix",
                    value: SupportDiagnosticsRedaction.fragment(snap?.tokenPrefix) ?? noValuePlaceholder,
                    accessibilityIdentifier: "notif.diagnostics.tokenPrefix"
                )
                Divider().opacity(0.5)
                SupportDetailRow(
                    title: "Token suffix",
                    value: SupportDiagnosticsRedaction.tail(snap?.tokenSuffix) ?? noValuePlaceholder,
                    accessibilityIdentifier: "notif.diagnostics.tokenSuffix"
                )
                Divider().opacity(0.5)
                SupportDetailRow(
                    title: "Environment",
                    value: snap?.environment ?? noValuePlaceholder,
                    accessibilityIdentifier: "notif.diagnostics.environment"
                )
                Divider().opacity(0.5)
                SupportDetailRow(
                    title: "Last attempt",
                    value: snap?.lastRegistrationAttemptAt.map { Self.formatTimestamp($0) } ?? noValuePlaceholder,
                    accessibilityIdentifier: "notif.diagnostics.lastAttempt"
                )
                Divider().opacity(0.5)
                SupportDetailRow(
                    title: "Server status",
                    value: snap?.lastRegistrationServerStatus.map(String.init) ?? noValuePlaceholder,
                    accessibilityIdentifier: "notif.diagnostics.serverStatus"
                )
                if let err = snap?.lastRegistrationError, !err.isEmpty {
                    Divider().opacity(0.5)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("Last error")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Text(err)
                            .font(.hlCaption)
                            .foregroundStyle(HLColor.statusBad)
                            .accessibilityIdentifier("notif.diagnostics.lastError")
                    }
                }
                Divider().opacity(0.5)
                Button {
                    Task { await forceFresh() }
                } label: {
                    HStack(spacing: HLSpace.xs) {
                        if forceFreshInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Re-register APNs token")
                    }
                    .font(.hlSubhead)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(forceFreshInFlight || !(lastRegistration?.hasToken ?? false))
                .accessibilityIdentifier("notif.diagnostics.forceFresh")
                if let forceFreshError {
                    Text(forceFreshError)
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("notif.diagnostics.forceFreshError")
                }
            }
        }

        private var categoriesCard: some View {
            HLSettingsCard(
                icon: "rectangle.stack.fill",
                title: "Buttons on the banner",
                footer: "Actions iOS renders on a banner. If MEDICATION_REMINDER is missing, the Taken / Snooze / Skipped buttons are missing too."
            ) {
                if categoryRows.isEmpty {
                    Text("No banner actions registered — restart the app.")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier("meds.diagnostics.noCategories")
                } else {
                    ForEach(categoryRows, id: \.identifier) { category in
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text(category.identifier)
                                .font(.hlHeadline)
                                .accessibilityIdentifier(
                                    "meds.diagnostics.category.\(category.identifier)"
                                )
                            Text(category.actionsLabel)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                        }
                        if category.identifier != categoryRows.last?.identifier {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }

        private var pendingIdentifiersCard: some View {
            HLSettingsCard(
                icon: "number",
                title: "settings.support.pending_title",
                footer: "settings.support.pending_footer"
            ) {
                if pendingIdentifiers.isEmpty {
                    Text("settings.support.pending_empty")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier("settings.supportDiagnostics.pendingEmpty")
                } else {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        ForEach(pendingIdentifiers, id: \.self) { identifier in
                            Text(identifier)
                                .font(.hlCaption.monospacedDigit())
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.supportDiagnostics.pendingList")
                }
            }
        }

        // MARK: - Apple-Health detail

        /// The four background wake channels. Moved here verbatim from the
        /// Apple-Health diagnostics screen: "iOS woke us at 04:12 over
        /// BGProcessing" is a sentence for a log reader, not for the person
        /// asking whether their weight arrived.
        private var wakeChannelsCard: some View {
            HLSettingsCard(
                icon: "bolt.badge.clock",
                title: "settings.hkdiag.wakes_title",
                subtitle: "settings.hkdiag.wakes_subtitle"
            ) {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    SupportDetailRow(
                        title: "settings.hkdiag.wake_observer",
                        value: relativeOrNever(diagnostics.lastBackgroundObservationAt),
                        accessibilityIdentifier: "settings.supportDiagnostics.wakeObserver"
                    )
                    SupportDetailRow(
                        title: "settings.hkdiag.wake_processing",
                        value: relativeOrNever(diagnostics.lastProcessingWakeAt),
                        accessibilityIdentifier: "settings.supportDiagnostics.wakeProcessing"
                    )
                    SupportDetailRow(
                        title: "settings.hkdiag.wake_apprefresh",
                        value: relativeOrNever(diagnostics.lastAppRefreshWakeAt),
                        accessibilityIdentifier: "settings.supportDiagnostics.wakeAppRefresh"
                    )
                    SupportDetailRow(
                        title: "settings.hkdiag.wake_push",
                        value: relativeOrNever(diagnostics.lastPushWakeAt),
                        accessibilityIdentifier: "settings.supportDiagnostics.wakePush"
                    )
                }
            }
        }

        /// Per-kind anchor advances — the concrete proof an upload round-trip
        /// succeeded, and the number a support conversation actually needs.
        private var anchorsCard: some View {
            HLSettingsCard(
                icon: "arrow.trianglehead.2.clockwise",
                title: "settings.support.anchors_title",
                footer: "settings.support.anchors_footer"
            ) {
                let rows = anchorRows
                if rows.isEmpty {
                    Text("settings.support.anchors_empty")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier("settings.supportDiagnostics.anchorsEmpty")
                } else {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(rows, id: \.title) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title)
                                    .font(.hlSubhead)
                                    .foregroundStyle(HLText.primary)
                                Spacer(minLength: HLSpace.md)
                                Text(row.value)
                                    .font(.hlCaption.monospacedDigit())
                                    .foregroundStyle(HLText.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.supportDiagnostics.anchorList")
                }
            }
        }

        private var anchorRows: [(title: String, value: String)] {
            diagnostics.snapshotByKind()
                .filter { $0.value.lastAnchorAdvancedAt != nil }
                .map { kind, stats in
                    (
                        title: String(localized: kind.descriptor.title),
                        value: relativeOrNever(stats.lastAnchorAdvancedAt)
                    )
                }
                .sorted { $0.title < $1.title }
        }

        // MARK: - Session boundary

        /// The one place the session is torn down, so `onDisappear`, Cancel and
        /// "End session" cannot drift apart. The detail state goes with it —
        /// leaving a token fragment in `@State` behind a locked gate would keep
        /// the value alive for the next `confirm()` in the same mount.
        private func endSession() {
            supportSession.end()
            lastRegistration = nil
            categoryRows = []
            pendingIdentifiers = []
            forceFreshError = nil
        }

        // MARK: - Local reads

        /// Local only. `UNUserNotificationCenter` answers from the OS and
        /// `lastRegistrationSnapshot` / `HKSyncDiagnostics.shared` are in-memory
        /// mirrors, so appearing here contacts no server.
        private func loadLocalSnapshot() async {
            lastRegistration = container?.notifications.lastRegistrationSnapshot
            let center = UNUserNotificationCenter.current()
            let categories = await center.notificationCategories()
            let pending = await center.pendingNotificationRequests()
            categoryRows = categories
                .sorted { $0.identifier < $1.identifier }
                .map {
                    CategoryDetail(
                        identifier: $0.identifier,
                        actionsLabel: $0.actions.isEmpty
                            ? String(localized: "No actions")
                            : $0.actions.map(\.identifier).joined(separator: ", ")
                    )
                }
            pendingIdentifiers = pending
                .map(\.identifier)
                .sorted()
                .prefix(Self.maxPendingIdentifiers)
                .compactMap { SupportDiagnosticsRedaction.fragment($0, keeping: Self.identifierFragmentLength) }
        }

        @MainActor
        private func forceFresh() async {
            guard let notif = container?.notifications else {
                forceFreshError = String(localized: "Service unavailable.")
                return
            }
            forceFreshInFlight = true
            forceFreshError = nil
            defer { forceFreshInFlight = false }
            if await notif.forceRefreshRegistration() == nil {
                forceFreshError =
                    String(
                        localized: "No push token stored yet. Allow notifications, then open the app once."
                    )
            }
            lastRegistration = container?.notifications.lastRegistrationSnapshot
        }

        private var noValuePlaceholder: String {
            String(localized: "— no data yet")
        }

        private func relativeOrNever(_ date: Date?) -> String {
            guard let date else {
                return String(localized: "settings.hkdiag.never")
            }
            return date.formatted(.relative(presentation: .named))
        }

        private static func formatTimestamp(_ date: Date) -> String {
            date.formatted(.dateTime.day().month().hour().minute().second())
        }

        /// A support conversation needs a handful of identifiers, not the whole
        /// schedule — and a long list is where a medication name would leak in.
        private static let maxPendingIdentifiers = 8
        /// Enough to correlate with a log row, short enough that a reminder
        /// identifier cannot carry a readable medication name through.
        private static let identifierFragmentLength = 12
    }

    extension SettingsSupportDiagnosticsScreen {
        /// Pure row model for a registered banner category.
        struct CategoryDetail: Equatable {
            let identifier: String
            let actionsLabel: String
        }
    }

    /// The row primitive for redacted support detail. `title` is a
    /// `LocalizedStringKey` for the same reason `LabeledRow`'s is: the
    /// `StringProtocol` overload of `Text` does not localize, and this screen
    /// carries catalogue keys.
    private struct SupportDetailRow: View {
        let title: LocalizedStringKey
        let value: String
        let accessibilityIdentifier: String

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(value)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
#endif
