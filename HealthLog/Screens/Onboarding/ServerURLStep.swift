import Foundation
import SwiftUI

/// Server-URL entry step.
///
/// v0.10.0 (D12) — self-hosted-only. There is no managed-cloud product and
/// the bundled default host is a private instance
/// that must NOT be teased/offered to other users. The screen is therefore
/// a clean URL entry: the user types the address of their own HealthLog
/// instance. There is no default-instance chip, no pre-fill, and no
/// cloud/standard framing — the field starts empty with a neutral
/// placeholder.
///
/// **Infra note (unchanged):** the bundled default host
/// (`AppEnvironment.productionBaseURL`) and its
/// SPKI cert-pin set stay exactly as before. This change is copy/IA only —
/// it does not touch the pinned host, the `webcredentials:` associated
/// domain, or the bundled URL. The default host is no longer surfaced as a
/// user-facing affordance; the operator (and any self-hoster) types it
/// manually if they want it.
///
/// **Trust-boundary acknowledgement (H-2 carry-over from v0.6.2.9):**
/// when the user enters a host into the editor, the successful probe does
/// not auto-persist. Instead we present a modal sheet that names the host
/// and forces an explicit confirmation before the URL is written to
/// Keychain. This applies to every typed host (including the bundled
/// default if typed manually) — the rule is path-driven, not host-driven.
///
/// Validation runs inline; an optional health-probe against
/// `GET /api/auth/registration-status` (un-authenticated route — see
/// M2-A11 § 4.3) confirms the host is actually reachable before either
/// the trust-boundary sheet or the direct Keychain write fires.
///
/// **Persistence:** writes the chosen URL to Keychain under
/// `KeychainKey.serverURL`. The next request issued by APIClient picks it
/// up through `AppContainer.reloadEnvironment()` which is called from
/// `OnboardingFlow` immediately before transitioning to the auth step.
struct ServerURLStep: View {
    let onContinue: () -> Void

    /// **R1 — warum diese Frage jetzt kommt.**
    ///
    /// Normalerweise leer: der Titel trägt den Schritt (STANDARD R1/R5). Gesetzt
    /// wird sie nur dort, wo der Nutzer die Frage sonst nicht einordnen könnte —
    /// wenn eine bestehende, angemeldete Installation nach einem Update plötzlich
    /// ohne Adresse dasteht. Kategorie R2 „Leerzustand": sie sagt, warum die
    /// Fläche leer ist und was sie füllt.
    var notice: LocalizedStringKey?

    @Environment(\.appContainer) private var container

    @State private var customURLString: String = ""
    @State private var probeState: ProbeState = .idle
    @State private var validationError: AppEnvironment.URLValidationError?
    /// Set when a probe succeeds — gates the trust-boundary sheet (H-2
    /// carry-over). `nil` during normal idle / probing states.
    @State private var trustBoundaryURL: IdentifiableURL?
    /// audit 02 · C-2 — the last syntactically-valid URL the user tried, kept
    /// when the reachability probe FAILS so the "Continue anyway" affordance can
    /// proceed with it. The server requirement stays intact (the URL must still
    /// validate); only the reachability ping stops being a hard block, so a
    /// momentarily-offline server no longer traps the user (SWR/Outbox reconcile
    /// once connectivity returns). Cleared whenever the URL text changes.
    @State private var lastValidatedURL: URL?
    @FocusState private var urlFocused: Bool

    enum ProbeState: Equatable {
        case idle
        case probing
        case reachable
        case unreachable(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("onboarding.serverurl.title")
                        .font(.hlTitle1)
                        .foregroundStyle(HLText.primary)
                    Text("onboarding.serverurl.subtitle")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
                .padding(.top, HLSpace.xxl)
                .padding(.horizontal, HLSpace.xl)

                if let notice {
                    Text(notice)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HLSpace.xl)
                        .accessibilityIdentifier("onboarding.serverurl.notice")
                }

                // v0.10.0 (D12) — self-hosted-only: the URL editor is the
                // single foreground path. No default-instance chip, no
                // pre-fill, no cloud/standard framing. The user types the
                // address of their own HealthLog instance.
                VStack(spacing: HLSpace.md) {
                    customURLEditor
                }
                .padding(.horizontal, HLSpace.lg)
                .onAppear {
                    // Kein eingebauter Host wird angeboten oder vorbelegt. Was
                    // vorbelegt wird, ist ausschliesslich die BEREITS von diesem
                    // Nutzer eingetragene Adresse — R1: wer sich vertippt hat,
                    // soll den Tippfehler korrigieren koennen statt die ganze
                    // Adresse blind neu zu tippen. Nur beim ersten Mal (noch
                    // nichts hinterlegt) bleibt das Feld leer.
                    if customURLString.isEmpty, let container {
                        customURLString = AppEnvironment
                            .currentBaseURL(keychain: container.keychain)?
                            .absoluteString ?? ""
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        urlFocused = true
                    }
                }

                if let err = validationError {
                    inlineError(text: errorMessage(for: err))
                }
                if case let .unreachable(msg) = probeState {
                    inlineError(text: msg)
                }
                // audit 02 · C-2 — offline tolerance: a failed reachability
                // probe no longer hard-blocks. The user keeps a valid, typed
                // server URL and may proceed anyway; the app syncs once the
                // server is reachable again (SWR/Outbox). Still routed through
                // the trust-boundary sheet so the host is explicitly confirmed.
                if showsOfflineProceed, let staged = lastValidatedURL {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        Text("onboarding.serverurl.offline.hint")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HLButton(
                            String(localized: "onboarding.serverurl.continueAnyway"),
                            variant: .ghost
                        ) {
                            trustBoundaryURL = IdentifiableURL(url: staged)
                        }
                        .accessibilityIdentifier("onboarding.serverURLContinueAnyway")
                    }
                    .padding(.horizontal, HLSpace.xl)
                }
                if case .reachable = probeState, trustBoundaryURL == nil {
                    HStack(spacing: HLSpace.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(HLColor.statusOK)
                        Text("Server reachable.")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                    }
                    .padding(.horizontal, HLSpace.xl)
                }

                Spacer(minLength: HLSpace.lg)

                VStack(spacing: HLSpace.sm) {
                    HLButton(
                        "Continue",
                        icon: "arrow.right",
                        variant: .primary,
                        size: .large,
                        isLoading: probeState == .probing
                    ) {
                        Task { await commit(urlString: customURLString) }
                    }
                    .accessibilityIdentifier("onboarding.serverURLContinue")
                }
                .padding(.horizontal, HLSpace.xl)
                .padding(.bottom, HLSpace.xxxl)
            }
        }
        .background(HLColor.background)
        .sheet(item: $trustBoundaryURL) { target in
            TrustBoundarySheet(
                url: target.url,
                onConfirm: {
                    Task { await persistAndContinue(url: target.url) }
                },
                onCancel: {
                    // User backed out. Reset probe state so the user sees
                    // a clean editor; do NOT clear the typed URL string —
                    // they may want to correct a typo instead of starting
                    // from scratch.
                    trustBoundaryURL = nil
                    probeState = .idle
                }
            )
            .hlSheetPresentation(.standard)
        }
    }

    /// Whether the offline "Continue anyway" affordance should show, per the
    /// pure `allowsOfflineProceed` invariant.
    private var showsOfflineProceed: Bool {
        let probeFailed = if case .unreachable = probeState { true } else { false }
        return Self.allowsOfflineProceed(probeFailed: probeFailed, hasValidatedURL: lastValidatedURL != nil)
    }

    /// audit 02 · C-2 — decides whether onboarding should offer an offline
    /// "Continue anyway" path. `true` when a reachability probe FAILED but the
    /// user has a syntactically valid URL staged. The server requirement stays
    /// (a valid URL is still required); only the reachability ping stops being a
    /// hard block, so a momentarily-offline server never traps the user. Pure +
    /// static so the "no hard block on reachability" invariant is unit-pinned.
    static func allowsOfflineProceed(probeFailed: Bool, hasValidatedURL: Bool) -> Bool {
        probeFailed && hasValidatedURL
    }

    private var customURLEditor: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("Address")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                TextField(String(localized: "onboarding.serverurl.placeholder"), text: $customURLString)
                    .accessibilityIdentifier("onboarding.serverCustom")
                    .focused($urlFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .padding(HLSpace.md)
                    .background(HLColor.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    .onChange(of: customURLString) { _, _ in
                        validationError = nil
                        probeState = .idle
                        lastValidatedURL = nil
                    }
                Text(String(localized: "https:// is added automatically. Self-signed certificates are currently not supported."))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }

    private func inlineError(text: String) -> some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, HLSpace.xl)
    }

    private func errorMessage(for err: AppEnvironment.URLValidationError) -> String {
        switch err {
        case .empty: String(localized: "onboarding.serverurl.error.empty")
        case .malformed: String(localized: "onboarding.serverurl.error.malformed")
        case .missingHost: String(localized: "onboarding.serverurl.error.missingHost")
        case .insecureScheme: String(localized: "Only https:// is supported (no http://).")
        }
    }

    /// Confirms the user's choice. Validates the entered URL, runs the
    /// reachability probe, then raises the trust-boundary sheet so the user
    /// explicitly confirms the host before it is persisted. Persistence +
    /// `onContinue` happen only after the user confirms the boundary.
    ///
    /// - Parameter urlString: The host the user typed. Every host — including
    ///   the bundled default if typed manually — goes through the same
    ///   boundary sheet; the rule is path-driven, not host-driven, so the
    ///   user never gets silently-different behaviour based on what they typed.
    @MainActor
    private func commit(urlString: String) async {
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
        let reachable = await probe(url: url)
        switch reachable {
        case .reachable:
            probeState = .reachable
            // Every typed host gets the trust-boundary sheet so the user
            // explicitly confirms what they connect to before it is persisted.
            trustBoundaryURL = IdentifiableURL(url: url)
        case let .unreachable(reason):
            probeState = .unreachable(reason)
            // Stash the valid URL so "Continue anyway" can proceed offline
            // (audit 02 · C-2 — server required, reachability ping non-blocking).
            lastValidatedURL = url
        case .probing, .idle:
            // Impossible by construction; treat as failure.
            probeState = .unreachable(String(localized: "onboarding.serverurl.probe.unknown"))
        }
    }

    /// Writes the resolved URL to Keychain, reloads the app environment,
    /// and advances the flow. Called from either the default-instance path
    /// (commit → directly) or the trust-boundary sheet's confirm CTA.
    @MainActor
    private func persistAndContinue(url: URL) async {
        if let container {
            do {
                try AppEnvironment.setCustomBaseURL(url, keychain: container.keychain)
                await container.reloadEnvironment()
            } catch {
                probeState = .unreachable(
                    String(format: String(localized: "onboarding.serverurl.saveFailed"), error.localizedDescription)
                )
                trustBoundaryURL = nil
                return
            }
        }
        trustBoundaryURL = nil
        onContinue()
    }

    /// Live health-probe — un-authenticated `GET /api/auth/registration-status`
    /// (per M2-A11 § 4.3). Uses the shared pinned probe session
    /// (`URLSession.healthLogProbeSession`) so a managed-host candidate
    /// is SPKI-checked against the bundled pin set before we persist
    /// it to Keychain — see H-2. Self-hosted hosts fall back to default
    /// server-trust validation. Short-timeout, no caching.
    private func probe(url: URL) async -> ProbeState {
        // v0.7.1 H-1 — transport + cert-pinning extracted to
        // `ServerReachabilityProbe` (Services layer). The View only maps
        // the typed outcome onto its own localized copy.
        let outcome = await ServerReachabilityProbe().probe(url: url, userAgent: "HealthLog-iOS-Onboarding/1")
        switch outcome {
        case .malformedURL:
            return .unreachable(String(localized: "onboarding.serverurl.probe.expandFailed"))
        case .reachable:
            return .reachable
        case .notHealthLogServer:
            return .unreachable(String(localized: "onboarding.serverurl.probe.notHealthLog"))
        case let .unexpectedStatus(code):
            return .unreachable(String(format: String(localized: "onboarding.serverurl.probe.status"), code))
        case .nonHTTPResponse:
            return .unreachable(String(localized: "onboarding.serverurl.probe.nonHTTP"))
        case let .transportFailure(description):
            return .unreachable(String(format: String(localized: "onboarding.serverurl.probe.transport"), description))
        }
    }
}

/// Modal sheet shown after a successful probe of a typed server URL.
/// Forces an explicit trust-boundary acknowledgement before the host is
/// persisted to Keychain — v0.6.2.9 H-2 audit recommendation 2, landed in
/// v0.7.0. Since D12 (v0.10.0) there is no default-instance bypass: every
/// typed host passes through this sheet.
///
/// **Why a sheet and not an inline confirmation:** the user has just
/// typed a host name and tapped Continue — they are mid-action. An
/// inline acknowledgement would compete with the inline error / success
/// affordances already on the editor. A sheet hard-stops the flow,
/// surfaces the host string they are about to trust, and demands a
/// single explicit tap before persistence — exactly the shape Apple's
/// HIG specifies for trust-handoff moments.
private struct TrustBoundarySheet: View {
    let url: URL
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: HLSpace.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    HStack(spacing: HLSpace.md) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.hlIcon(HLIconSize.hero))
                            .foregroundStyle(HLColor.statusWarn)
                        Text("onboarding.trustboundary.title")
                            .font(.hlTitle2)
                            .foregroundStyle(HLText.primary)
                    }
                    .padding(.top, HLSpace.xl)

                    Text("onboarding.trustboundary.body")
                        .font(.hlBody)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HLCard {
                        VStack(alignment: .leading, spacing: HLSpace.xs) {
                            Text("onboarding.trustboundary.hostLabel")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                            Text(url.host ?? url.absoluteString)
                                .font(.hlHeadline.monospaced())
                                .foregroundStyle(HLText.primary)
                                .accessibilityIdentifier("onboarding.trustboundary.host")
                        }
                    }
                }
                .padding(.horizontal, HLSpace.xl)
            }

            VStack(spacing: HLSpace.sm) {
                HLButton(
                    String(localized: "onboarding.trustboundary.confirm"),
                    icon: "checkmark.shield.fill",
                    variant: .primary,
                    size: .large,
                    action: onConfirm
                )
                .accessibilityIdentifier("onboarding.trustboundary.confirm")

                HLButton(
                    String(localized: "onboarding.trustboundary.cancel"),
                    variant: .ghost,
                    action: onCancel
                )
                .accessibilityIdentifier("onboarding.trustboundary.cancel")
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.bottom, HLSpace.xl)
        }
        .background(HLColor.background)
        .interactiveDismissDisabled(true)
    }
}

/// Scoped `Identifiable` wrapper so a `URL` payload can drive
/// `.sheet(item:)` without conforming a stdlib type module-wide. A
/// file-scope `URL: @retroactive Identifiable` would be visible to the
/// whole module — risking an ambiguous-conformance compile break if the
/// SDK (or any other file) adds its own, and silently giving every
/// `.sheet(item:)`/`ForEach` over a `URL` an `absoluteString` identity
/// that is wrong for most callers. The identity stays pinned to this one
/// screen.
///
/// `id` is the absolute string (not a fresh `UUID`) so behaviour matches
/// the former retroactive conformance exactly: two probes of the same
/// host yield the same identity and never stack duplicate sheets.
struct IdentifiableURL: Identifiable {
    var id: String {
        url.absoluteString
    }

    let url: URL
}
