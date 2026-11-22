import SwiftUI

/// `/settings/server` — Server. Lets the
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
struct SettingsServerScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(AuthStore.self) private var authStore

    @State private var versionState: VersionState = .loading
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Only without a container (previews). Otherwise the sheet is open while
    /// the container's draft holds an address, so it reopens with
    /// what was typed after the privacy shield rebuilt the window.
    @State private var localSheetPresented = false
    /// How many proxy headers are stored; read on every appear
    /// (also after Access headers pops), so a body evaluation never hits the Keychain.
    @State private var accessHeaderCount = 0
    @State private var refreshTick: Int = 0

    enum VersionState: Equatable {
        case loading
        case loaded(ServerVersionInfo)
        case failed(String)
    }

    var body: some View {
        HLPage {
            currentServerCard
            versionCard
        }
        // QoL-A2 (Glass H1) — scroll-edge glass now owned centrally by the
        // `HLPage` inner ScrollView; no outer-layer patch here.
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        // The task identity is the configured-server value snapshot, so
        // an environment revision (a server switch) re-runs the version probe
        // while an ordinary body evaluation costs no Keychain query at all.
        .task(id: currentBaseURL) {
            await loadVersion()
        }
        .refreshable {
            await loadVersion()
            refreshTick &+= 1
        }
        // Success-tick confirms pull-to-refresh round-trip.
        .sensoryFeedback(.success, trigger: refreshTick)
        .onAppear {
            if let container {
                accessHeaderCount = ServerAccessHeaders.load(keychain: container.keychain).count
            }
        }
        .sheet(isPresented: changeServerPresented) {
            ChangeServerSheet(onCommitted: {
                changeServerPresented.wrappedValue = false
            })
        }
    }

    // MARK: - Cards

    private var currentServerCard: some View {
        HLCard("Current server") {
            identifierRow(label: "Address", value: currentHostDisplay)
                .accessibilityIdentifier("settings.server.hostRow")
            statRow(label: "Region", value: regionLabel)
                .accessibilityIdentifier("settings.server.regionRow")
            accessHeadersRow
            // The switch is a row of the card it changes; its own
            // card repeated "Change server" as title and row.
            if isPairedAuth {
                changeServerRow
            }
        }
    }

    /// R2/R5 — der Subtitle buchstabierte nur den Kartentitel aus
    /// („Server version" ⇄ „The build currently running on the server.") und
    /// fällt die Abdeck-Probe.
    private var versionCard: some View {
        HLCard("Server version") {
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
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
                HLLinkButton(HLControlWord.retry.key) {
                    Task { await loadVersion() }
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
    /// Der frühere `.ghost`-Vollbreitenknopf war in Wahrheit eine Zeile
    /// in einer Karte, die ein Sheet öffnet. Die Zeile steht jetzt
    /// in der Karte „Aktueller Server"; die eigene Karte trug denselben Titel
    /// wie ihre einzige Zeile.
    private var changeServerRow: some View {
        HLSettingsActionRow(
            title: "Change server",
            presents: .sheet
        ) {
            changeServerPresented.wrappedValue = true
        }
        .accessibilityIdentifier("settings.server.changeServerButton")
    }

    /// Proxy credentials for a server behind Cloudflare Access,
    /// Pangolin or a similar gate.
    private var accessHeadersRow: some View {
        HLSettingsActionRow(
            title: "Access headers",
            subtitle: accessHeaderCount == 0
                ? "For Cloudflare Access, Pangolin and similar proxies"
                : "Headers set: \(accessHeaderCount)",
            presents: .push,
            // #153 follow-up — a value on the More stack, so the
            // page comes back after the privacy shield. The count above is
            // re-read from the Keychain when this page appears again.
            value: SettingsRoute.serverAccessHeaders
        )
        .accessibilityIdentifier("settings.server.accessHeadersRow")
    }

    // MARK: - Helpers

    private var changeServerPresented: Binding<Bool> {
        Binding(
            get: { container.map { $0.onboardingDraft.changeServerAddress != nil } ?? localSheetPresented },
            set: { shown in
                guard let draft = container?.onboardingDraft else {
                    localSheetPresented = shown
                    return
                }
                if shown {
                    if draft.changeServerAddress == nil {
                        draft.changeServerAddress = currentBaseURL?.absoluteString ?? ""
                    }
                } else if scenePhase == .active {
                    // A dismissal by the privacy shield keeps the draft.
                    draft.changeServerAddress = nil
                }
            }
        )
    }

    /// One in-memory read of the already-resolved configured server.
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
        HLSettingsStatRow(label: Text(label), value: value)
    }

    /// The address is read off and typed into another device, so it breaks
    /// only at its dots, never with a hyphen; under its label at AX sizes.
    private func identifierRow(label: LocalizedStringKey, value: String) -> some View {
        HLRowLayout(
            title: Text(label),
            subtitle: nil,
            indicator: .hidden,
            configuration: .stat,
            leading: { EmptyView() },
            trailing: {
                if dynamicTypeSize.isAccessibilitySize {
                    HLIdentifierText(value)
                } else {
                    HLIdentifierText(value).trailing()
                }
            }
        )
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
            versionState = .failed(Self.versionFailureText(for: error))
        }
    }

    /// The sentence under "Version unavailable". `HLError` does not
    /// conform to `LocalizedError`, so `localizedDescription` printed
    /// "(HealthLog.HLError-Fehler 2.)" here — the shared user-facing sentence
    /// instead, like every store.
    nonisolated static func versionFailureText(for error: Error) -> String {
        HLError.userFacingText(for: error)
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

    let onCommitted: () -> Void

    /// Only without a container (previews); otherwise the draft holds it.
    @State private var localURLString: String = ""
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
        // The commit is the primary button in the content, not the bar: it
        // probes the address before it switches. The bar keeps only the X.
        HLSheetScaffold(
            "Change server",
            closeWord: HLControlWord.cancel.key,
            closeIdentifier: "settings.server.changeSheet.cancel"
        ) {
            ScrollView {
                // No lead card: it held only "you must sign in
                // again", which the button "Switch and sign in again" says.
                VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                    urlInputCard
                    statusRow
                    Spacer(minLength: HLSpace.lg)
                    actionButtons
                }
                .padding(.horizontal, HLLayout.cardInset)
                .padding(.top, HLSpace.md)
                .padding(.bottom, HLLayout.pageBottom)
            }
        }
        .onAppear {
            urlFocused = true
        }
    }

    /// The typed address, kept in the container's draft.
    private var urlString: String {
        get { container?.onboardingDraft.changeServerAddress ?? localURLString }
        nonmutating set {
            if let draft = container?.onboardingDraft {
                draft.changeServerAddress = newValue
            } else {
                localURLString = newValue
            }
        }
    }

    private var urlBinding: Binding<String> {
        Binding(get: { urlString }, set: { urlString = $0 })
    }

    private var urlInputCard: some View {
        HLCard(
            "Address",
            subtitle: "https:// is added automatically."
        ) {
            TextField("e.g. myserver.example.com", text: urlBinding)
                .focused($urlFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .hlText(.objectName)
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
            // Der abschließende Commit dieses Ablaufs; genau ein
            // `.primary` auf dem Sheet.
            HLButton(
                "Switch and sign in again",
                systemImage: "arrow.right",
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
                .hlText(.prose)
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
                // The container coordinator is the sole switch-server
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
                probeState = .unreachable(String(localized: "Couldn't save URL: \(HLError.userFacingText(for: error))"))
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
        // Transport + cert-pinning extracted to the shared
        // `ServerReachabilityProbe` (Services layer). The View only maps
        // the typed outcome onto its own localized copy.
        let outcome = await ServerReachabilityProbe().probe(
            url: url,
            userAgent: "HealthLog-iOS-Settings/1",
            accessHeaders: container.map { ServerAccessHeaders.load(keychain: $0.keychain) } ?? []
        )
        switch outcome {
        case .malformedURL:
            return .unreachable(String(localized: "URL could not be expanded."))
        case .reachable:
            return .reachable
        case .notHealthLogServer:
            return .unreachable(String(localized: "This server does not appear to be a HealthLog server."))
        case .serverStarting:
            return .unreachable(String(localized: "Your server is starting up. Try again in a moment."))
        case let .unexpectedStatus(code):
            return .unreachable(String(localized: "Server responded with status \(code)."))
        case let .redirectedToOtherHost(host):
            return .unreachable(
                String(
                    localized: "The server forwarded to \(host). If it sits behind Cloudflare Access or Pangolin, set up the access headers first."
                )
            )
        case .nonHTTPResponse:
            return .unreachable(String(localized: "Received a response without an HTTP status."))
        case let .transportFailure(description):
            return .unreachable(String(localized: "Connection failed: \(description)"))
        }
    }
}
