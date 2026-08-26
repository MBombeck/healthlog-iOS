import SwiftUI

/// `/settings/server` — Server. v0.5.5.2 W-IMPL-SERVER-EDITOR: lets the
/// operator inspect the currently-targeted server (host + region) and
/// the running build version, and edit the server URL post-onboarding
/// without re-running the whole onboarding flow.
///
/// **Why a dedicated screen and not a row on About:** the operator
/// feedback was explicit — "Auch sollte der Server editiert werden
/// können und auch welche Version dieser einsetzt." Server identity +
/// drift between iOS app + backend deserves its own surface so a
/// version-mismatch question can be answered with one tap.
///
/// **Editing flow (server-mode only):** tap "Server wechseln" → sheet
/// presents the same URL-input + health-probe as
/// `Onboarding/ServerURLStep.swift` (validation logic shared via
/// `AppEnvironment.validate`). On confirm the sheet hands the staged URL
/// to `AppContainer.switchServer(to:)` (06-05) — the sole switch-server
/// terminal path, which tears the old session down completely
/// (invalidate → drain → cleanup), wipes the old auth tokens locally,
/// only then persists the new URL and flips `AuthStore.phase` to
/// `.unauthenticated` so `RootView` returns to onboarding. It
/// deliberately does **not** call `AuthService.logout()` — the
/// server-side revoke would hit the *new* host with the *old* refresh
/// token and either fail or contaminate the new server's audit log.
///
/// **Standalone-mode:** the screen still renders the read-only host
/// + version cards (so the operator can confirm "where would my data
/// go if I paired now"), but the "Server wechseln" action is hidden
/// — standalone has no tokens to wipe and the URL only matters once
/// pairing fires.
struct SettingsServerScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(AuthStore.self) private var authStore

    @State private var versionState: VersionState = .loading
    @State private var presentChangeServerSheet = false
    @State private var refreshTick: Int = 0

    enum VersionState: Equatable {
        case loading
        case loaded(ServerVersionInfo)
        case failed(String)
    }

    var body: some View {
        HLSettingsPage(title: "Server") {
            currentServerCard
            versionCard
            if isPairedAuth {
                changeServerCard
            }
        }
        // QoL-A2 (Glass H1) — scroll-edge glass now owned centrally by the
        // `HLSettingsPage` inner ScrollView; no outer-layer patch here.
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        // 09-03 — the task identity is the configured-server value snapshot, so
        // an environment revision (a server switch) re-runs the version probe
        // while an ordinary body evaluation costs no Keychain query at all.
        .task(id: currentBaseURL) {
            await loadVersion()
        }
        .refreshable {
            await loadVersion()
            refreshTick &+= 1
        }
        // POLISH-SWEEP: success-tick confirms pull-to-refresh round-trip.
        .sensoryFeedback(.success, trigger: refreshTick)
        .sheet(isPresented: $presentChangeServerSheet) {
            ChangeServerSheet(onCommitted: {
                presentChangeServerSheet = false
            })
            .hlSheetPresentation(.form)
        }
    }

    // MARK: - Cards

    private var currentServerCard: some View {
        HLSettingsCard(
            icon: "server.rack",
            title: "Aktueller Server",
            subtitle: "Data is synced against this address."
        ) {
            statRow(label: "Address", value: currentHostDisplay)
                .accessibilityIdentifier("settings.server.hostRow")
            statRow(label: "Region", value: regionLabel)
                .accessibilityIdentifier("settings.server.regionRow")
        }
    }

    /// R2/R5 — der Subtitle buchstabierte nur den Kartentitel aus
    /// („Server version" ⇄ „The build currently running on the server.") und
    /// fällt die Abdeck-Probe.
    private var versionCard: some View {
        HLSettingsCard(
            icon: "tag.fill",
            title: "Server version"
        ) {
            versionCardContent
        }
    }

    @ViewBuilder
    private var versionCardContent: some View {
        switch versionState {
        case .loading:
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSkeleton(width: 140, height: 16)
                HLSkeleton(width: 200, height: 14)
                HLSkeleton(width: 160, height: 14)
            }
            .accessibilityIdentifier("settings.server.versionLoading")
        case let .loaded(info):
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                statRow(label: "Version", value: "v\(info.version)")
                    .accessibilityIdentifier("settings.server.versionRow")
                if let sha = info.buildSha {
                    statRow(label: "Commit", value: sha)
                        .accessibilityIdentifier("settings.server.commitRow")
                }
                if let builtAt = info.builtAt {
                    statRow(label: "Build date", value: builtAt)
                        .accessibilityIdentifier("settings.server.builtAtRow")
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HLColor.statusBad)
                    Text("Version unavailable")
                        .font(.hlBody)
                        .foregroundStyle(HLText.primary)
                }
                Text(message)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await loadVersion() }
                } label: {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "arrow.clockwise")
                            .font(.hlIcon(HLIconSize.sm))
                        Text("Try again")
                            .font(.hlSubhead)
                    }
                    .foregroundStyle(.tint)
                }
                .accessibilityIdentifier("settings.server.versionRetry")
            }
            .accessibilityIdentifier("settings.server.versionError")
        }
    }

    /// R2/R5 — der Subtitle buchstabierte den Kartentitel aus. Der Footer
    /// („Du musst dich nach einem Serverwechsel erneut anmelden.") stand
    /// wortgleich einen Tap weiter im Sheet, wo der Wechsel unmittelbar
    /// bevorsteht; R3 gibt die Aussage dem Ort der Handlung.
    ///
    /// R9 — der frühere `.ghost`-Vollbreitenknopf war in Wahrheit eine Zeile
    /// in einer Karte, die ein Sheet öffnet.
    private var changeServerCard: some View {
        HLSettingsCard(
            icon: "arrow.triangle.swap",
            title: "Change server"
        ) {
            HLSettingsActionRow(
                title: "Change server",
                presents: .sheet
            ) {
                presentChangeServerSheet = true
            }
            .accessibilityIdentifier("settings.server.changeServerButton")
        }
    }

    // MARK: - Helpers

    /// 09-03 — one in-memory read of the already-resolved configured server.
    /// The host row, the region row and the version task's identity all derive
    /// from this value; none of them queries the Keychain.
    private var currentBaseURL: URL? {
        container?.configuredServer.baseURL
    }

    private var currentHostDisplay: String {
        guard let host = currentBaseURL?.host else { return "—" }
        return host
    }

    private var regionLabel: String {
        guard let url = currentBaseURL else { return "—" }
        switch AppEnvironment.inferRegion(for: url) {
        // Die App ist self-hosted-only und bringt keinen eigenen Server mehr
        // mit: jede eingetragene Adresse ist eine eigene Instanz. Nur die
        // oeffentliche Demo wird eigens benannt.
        case .demo: return String(localized: "Demo")
        case .selfHosted: return String(localized: "Self-hosted")
        }
    }

    private var isPairedAuth: Bool {
        if case .authenticated = authStore.phase { return true }
        return false
    }

    private func statRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // b146 — match the canonical `HLSettingsRow` label scale
            // (`.hlSubhead`, 15pt). Was `.hlBody` (17pt), which read 2pt larger
            // than every sibling Settings row and lost the label→value step-down
            // (operator: "Server area font feels bigger"). Value stays `.hlBody`.
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            // v0.11.0 W37-P4: value uses the semantic `.hlBody` token like the
            // rest of Settings. The previous `.hlMetric(.body)` + monospaced
            // digits is a numeric/chart font and read visibly different from
            // the surrounding rows for non-numeric values (Address, Region,
            // Version string).
            Text(value)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadVersion() async {
        guard let api = container?.api else {
            versionState = .failed(String(localized: "No server configured."))
            return
        }
        versionState = .loading
        do {
            let info = try await api.fetchServerVersion()
            versionState = .loaded(info)
        } catch {
            versionState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Change-server sheet

/// Modal URL editor presented from `SettingsServerScreen` when the
/// operator taps "Server wechseln". Mirrors `ServerURLStep.swift`'s
/// validate-then-probe contract: the typed string is canonicalised
/// (auto-`https://`), parsed (`URL(string:)` + host check), and a live
/// `GET /api/auth/registration-status` probe confirms the host is
/// actually a HealthLog instance before we persist.
///
/// On commit the sheet delegates to `AppContainer.switchServer(to:)`
/// (06-05): old-session teardown completes first, then the local token
/// wipe, then the persisted server mutation and the transition to
/// `.unauthenticated` so `RootView` returns to onboarding-style sign-in
/// against the new host.
private struct ChangeServerSheet: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    let onCommitted: () -> Void

    @State private var urlString: String = ""
    @State private var probeState: ProbeState = .idle
    @State private var validationError: AppEnvironment.URLValidationError?
    @FocusState private var urlFocused: Bool

    enum ProbeState: Equatable {
        case idle
        case probing
        case reachable
        case unreachable(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    headerCard
                    urlInputCard
                    statusRow
                    Spacer(minLength: HLSpace.lg)
                    actionButtons
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.md)
                .padding(.bottom, HLSpace.xxxl)
            }
            .background(HLSurface.primary)
            .navigationTitle("Change server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("settings.server.changeSheet.cancel")
                }
            }
        }
        .onAppear {
            urlString = currentHostHint
            urlFocused = true
        }
    }

    private var currentHostHint: String {
        container?.configuredServer.baseURL?.absoluteString ?? ""
    }

    private var headerCard: some View {
        HLSettingsCard(
            icon: "exclamationmark.shield.fill",
            title: "New server address",
            // R5 — der Subtitle formulierte den Kartentitel um; der Footer
            // trägt die Folge und ist damit der eine belegte Beitext-Slot.
            footer: "After switching you must sign in again — existing sessions are only valid on the previous server."
        ) {
            EmptyView()
        }
    }

    private var urlInputCard: some View {
        HLSettingsCard(
            icon: "link",
            title: "Address",
            subtitle: "https:// is added automatically."
        ) {
            TextField("e.g. myserver.example.com", text: $urlString)
                .focused($urlFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .padding(HLSpace.md)
                .background(HLSurface.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                .onChange(of: urlString) { _, _ in
                    validationError = nil
                    probeState = .idle
                }
                .accessibilityIdentifier("settings.server.changeSheet.urlField")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let err = validationError {
            inlineMessage(systemImage: "exclamationmark.triangle.fill", tint: HLColor.statusBad, text: errorMessage(for: err))
                .accessibilityIdentifier("settings.server.changeSheet.validationError")
        }
        if case let .unreachable(msg) = probeState {
            inlineMessage(systemImage: "exclamationmark.triangle.fill", tint: HLColor.statusBad, text: msg)
                .accessibilityIdentifier("settings.server.changeSheet.probeError")
        }
        if case .reachable = probeState {
            inlineMessage(systemImage: "checkmark.circle.fill", tint: HLColor.statusOK, text: String(localized: "Server reachable."))
                .accessibilityIdentifier("settings.server.changeSheet.probeOK")
        }
    }

    private var actionButtons: some View {
        VStack(spacing: HLSpace.sm) {
            // R9 — der abschließende Commit dieses Ablaufs; genau ein
            // `.primary` auf dem Sheet.
            HLButton(
                String(localized: "Switch and sign in again"),
                icon: "arrow.right",
                variant: .primary,
                isLoading: probeState == .probing
            ) {
                Task { await commit() }
            }
            .accessibilityIdentifier("settings.server.changeSheet.confirm")
        }
    }

    private func inlineMessage(systemImage: String, tint: Color, text: String) -> some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorMessage(for err: AppEnvironment.URLValidationError) -> String {
        switch err {
        case .empty: String(localized: "Please enter a server address.")
        case .malformed: String(localized: "The address could not be read.")
        case .missingHost: String(localized: "This address has no host part.")
        case .insecureScheme: String(localized: "Only https:// is supported (no http://).")
        }
    }

    @MainActor
    private func commit() async {
        guard let container else { return }
        let url: URL
        do {
            url = try AppEnvironment.validate(serverURLString: urlString)
        } catch let err as AppEnvironment.URLValidationError {
            validationError = err
            return
        } catch {
            validationError = .malformed
            return
        }
        probeState = .probing
        let probed = await probe(url: url)
        switch probed {
        case .reachable:
            do {
                // 06-05 — the container coordinator is the sole switch-server
                // terminal path: it holds the account boundary, completes the
                // old session's invalidate → drain → cleanup cascade FIRST,
                // wipes the old session's tokens (deliberately without a
                // `/api/auth/logout` round-trip — the revoke would hit the
                // NEW host with the OLD refresh token), and only then commits
                // the persisted/runtime server mutation and re-opens pairing.
                try await container.switchServer(to: url)
                probeState = .reachable
                onCommitted()
            } catch {
                probeState = .unreachable(String(localized: "Couldn't save URL: \(error.localizedDescription)"))
            }
        case let .unreachable(reason):
            probeState = .unreachable(reason)
        case .probing, .idle:
            probeState = .unreachable(String(
                localized: "Unknown error during probe.",
                comment: "Server reachability probe — unexpected failure"
            ))
        }
    }

    /// Mirrors `ServerURLStep.probe` — one-shot pinned probe session
    /// via `URLSession.healthLogProbeSession`. Managed-cloud
    /// candidates run through the bundled SPKI pin
    /// set before we wipe local auth tokens and re-target the
    /// session; self-hosted hosts fall back to default server-trust
    /// validation. See H-2.
    private func probe(url: URL) async -> ProbeState {
        // v0.7.1 H-1 — transport + cert-pinning extracted to the shared
        // `ServerReachabilityProbe` (Services layer). The View only maps
        // the typed outcome onto its own localized copy.
        let outcome = await ServerReachabilityProbe().probe(url: url, userAgent: "HealthLog-iOS-Settings/1")
        switch outcome {
        case .malformedURL:
            return .unreachable(String(localized: "URL could not be expanded."))
        case .reachable:
            return .reachable
        case .notHealthLogServer:
            return .unreachable(String(localized: "This server does not appear to be a HealthLog server."))
        case let .unexpectedStatus(code):
            return .unreachable(String(localized: "Server responded with status \(code)."))
        case .nonHTTPResponse:
            return .unreachable(String(localized: "Received a response without an HTTP status."))
        case let .transportFailure(description):
            return .unreachable(String(localized: "Connection failed: \(description)"))
        }
    }
}
