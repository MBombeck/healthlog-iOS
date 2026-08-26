import SwiftUI

/// **v0.7.1 W-COACH-FALLBACK** — surfaces that replace the AskCoach
/// kill-card on iPhones without an on-device Foundation Model.
///
/// Split out of `AskCoachSheet.swift` so the main view file stays under
/// the SwiftLint 600-line ceiling. Three states live here:
///   1. ``serverFallbackNotice`` — the inline disclosure shown above the
///      transcript while the server fallback is serving the turn (the
///      data leaves the device on this path; we say so).
///   2. ``serverConsentSurface(container:)`` — the consent CTA shown
///      when a server provider could answer but the per-provider
///      AI-consent gate is still pending (Apple Guideline 5.1.2(i)).
///   3. ``onDeviceUnavailableSurface(availability:)`` — the legacy
///      on-device-unavailable copy, reached only when no server fallback
///      is applicable.
extension AskCoachSheet {
    // MARK: - Standalone placeholder (v0.11 W3)

    /// Standalone + on-device Coach unavailable → the calm cloud placeholder.
    /// There is no server to fall back to, so the consent / server-fallback arms
    /// are skipped upstream and this surface stands in. The welcome lockup stays
    /// above it so the sheet still reads as the Coach surface; the placeholder
    /// carries the shared "Server verbinden" CTA (`beginServerPairing()`).
    var standalonePlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                welcomeLockup
                HLCloudDerivedPlaceholder(
                    variant: .hero,
                    surfaceName: String(localized: "cloud_derived.surface.server_coach"),
                    onConnect: { authStore.beginServerPairing() }
                )
                Spacer(minLength: HLSpace.xxxl)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
        }
    }

    // CO1 (v0154 walkthrough) — the per-turn active-arm pills
    // (`serverFallbackNotice` / `onDeviceNotice` / `byoNotice`) and the shared
    // `activeModePill(...)` renderer were removed here. W1-C1 (b199) had promoted
    // the active-arm indicator to a `HLColor.statusWarn`-tinted, bordered egress
    // capsule painted over EVERY turn; the operator deliberately picked External
    // AI and flagged that permanent "comes from your server" banner as noise. The
    // honest replacement is on-demand: the collapsed provenance disclosure under
    // each server-arm reply (CO4) plus the quiet token footer (CO5). The
    // empty-state `privateProvenanceNote` (in `AskCoachSheet.swift`) still names
    // the private on-device path before the first turn. The `usingServerFallback`
    // / `usingBYO` store flags stay (they gate other behaviour), they just no
    // longer paint a pill.

    // The Coach error-copy family (`errorCopy`, `serverErrorCopy`,
    // `byoErrorCopy` + their private helpers) lives in
    // `AskCoachSheet+ErrorCopy.swift` (split out C3/b199 to keep this file under
    // the 600-line SwiftLint ceiling after the server-error-copy work landed).

    // MARK: - On-device unavailable routing

    /// Routes the legacy on-device-unavailable copy. Reached only when
    /// the server fallback is NOT applicable (no service wired, or the
    /// build can't reach the server path) — otherwise the server
    /// conversation / consent CTA takes over so the user is never stuck
    /// on a dead kill-card.
    @ViewBuilder
    func onDeviceUnavailableSurface(
        availability: LocalLLMService.Availability
    ) -> some View {
        switch availability {
        case .available:
            EmptyView() // handled upstream
        case .appleIntelligenceNotEnabled:
            unavailableSurface(
                title: String(localized: "Apple Intelligence is off"),
                message: String(
                    localized: "Turn on Apple Intelligence in Settings so the Coach can answer on-device."
                )
            )
        case .modelNotReady:
            unavailableSurface(
                title: String(localized: "Model is preparing"),
                message: String(
                    localized: "Apple is downloading the on-device model. As soon as it is ready, the Coach can answer."
                )
            )
        case .deviceNotEligible, .unsupported:
            unavailableSurface(
                title: String(localized: "Coach requires Apple Intelligence"),
                message: String(
                    localized: "The Coach answers exclusively on-device and requires an iPhone with Apple Intelligence (iPhone 15 Pro or newer)."
                )
            )
        }
    }

    // MARK: - Nested AI-consent sheet (A6b)

    /// v0.14.7 A6b — the AI-consent sheet presented OVER the Coach sheet from the
    /// Coach view's own hierarchy (the shell can't present over an already-
    /// presented sheet, which swallowed the old token-routed prompt). On accept we
    /// grant the resolved provider; the `@Observable` `aiConsentStore` flips
    /// `serverFallbackNeedsConsent → false`, so the surface re-renders straight
    /// into the live server conversation — no app restart needed.
    @ViewBuilder
    var coachConsentSheet: some View {
        if let container = appContainer {
            let provider = container.aiProviderStore.config?.resolvedProvider ?? .unconfigured
            // W-B186 COACH-1 (#24) — when external AI is server/admin-managed
            // there is no per-user provider; consent targets the server-managed
            // scope so accepting actually grants (not a `.unconfigured` no-op).
            let usesProviderOpaqueConsent =
                container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true
            AIConsentSheet(
                provider: provider,
                onAccept: {
                    if usesProviderOpaqueConsent {
                        // #24 — grant the server-managed scope: `aiMode` flips to
                        // `.online`, the coach surface re-renders into the live
                        // server conversation. The `ai_full` receipt is minted
                        // below (consent is not bypassed — this is its device half).
                        container.aiConsentStore.grantServerManaged()
                        showCoachConsentSheet = false
                        Task { await container.syncServerAIConsentReceipt() }
                        return
                    }
                    // v0.14.1 — fix the silent-bounce dead-end: `grant(for:)` is a
                    // guard-noop for `.unconfigured` (no provider → nothing to
                    // grant), so accepting consent for an unconfigured provider
                    // left `aiMode == .none` and `serverFallbackNeedsConsent`
                    // still true → the surface re-rendered the SAME chooser. Only
                    // grant + dismiss into the coach when a REAL provider exists
                    // and consent now resolves true; otherwise surface the
                    // "provider needed" step so the user is never stranded on a
                    // silently-identical chooser.
                    guard provider != .unconfigured else {
                        showCoachConsentSheet = false
                        showCoachProviderNeeded = true
                        return
                    }
                    container.aiConsentStore.grant(for: provider)
                    showCoachConsentSheet = false
                    // v0.14.10 W-INSIGHTSDATA — mint the server-side consent
                    // receipt for the fresh grant (server v1.12.1 fails AI
                    // generation closed without one). Best-effort.
                    Task { await container.syncServerAIConsentReceipt() }
                },
                onDecline: {
                    if usesProviderOpaqueConsent {
                        container.aiConsentStore.declineServerManaged()
                    } else {
                        container.aiConsentStore.decline(for: provider)
                    }
                    showCoachConsentSheet = false
                }
            )
        }
    }

    // MARK: - Server-fallback consent surface

    /// Shown when the on-device model is unavailable OR the user explicitly
    /// picked External AI — pending the per-provider AI-consent gate. Replaces
    /// the kill-card with a working CTA so the user can opt into the server-backed
    /// Coach (Apple Guideline 5.1.2(i): we only transmit health data after
    /// informed, per-provider consent).
    ///
    /// **v0.14.7 COACH-redesign** — ONE calm page, modeled on `AIConsentSheet`:
    /// centered hero glyph + large title + one explainer, the on-device-vs-server
    /// CHOICE expressed as the app's canonical monochrome `AISourceChoicePicker`
    /// (On-device pre-selected), committed by a SINGLE bottom-pinned primary CTA.
    /// Picking "External AI" then tapping the CTA routes through the nested
    /// `AIConsentSheet` (the proper 5.1.2(i) informed-consent page). This replaces
    /// the prior two equal `.large` buttons the operator flagged as "mega komisch".
    ///
    /// Non-capable device collapses to the pure consent recipe: no picker, hero +
    /// "Coach via your server" + one "Consent and continue" CTA.
    func serverConsentSurface(
        container _: AppContainer,
        onDeviceCapable: Bool,
        hasServerProvider: Bool,
        onRequestServerConsent: @escaping () -> Void,
        onChooseOnDevice: @escaping () -> Void,
        onNeedsProvider: @escaping () -> Void
    ) -> some View {
        CoachSourceChoiceView(
            onDeviceCapable: onDeviceCapable,
            hasServerProvider: hasServerProvider,
            onRequestServerConsent: onRequestServerConsent,
            onChooseOnDevice: onChooseOnDevice,
            onNeedsProvider: onNeedsProvider
        )
    }

    // MARK: - Provider-needed step (v0.14.1)

    /// v0.14.1 — the "External AI needs a server provider" step, presented when
    /// the user picks External AI but no server provider is configured. Replaces
    /// the silent bounce-to-chooser dead-end (RCA: `grant(for: .unconfigured)` is
    /// a noop) with a calm, honest page that explains a server AI provider (or
    /// BYO key) is required, plus a single CTA that dismisses the Coach sheet and
    /// routes to Settings → Assistant where it is set up.
    var coachProviderNeededSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    VStack(spacing: HLSpace.sm) {
                        Image(systemName: "cloud")
                            .font(.hlLargeTitle.weight(.light))
                            .foregroundStyle(HLText.primary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(String(localized: "A server provider is required"))
                            .font(.hlLargeTitle)
                            .foregroundStyle(HLText.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    Text(
                        String(
                            // swiftlint:disable:next line_length
                            localized: "The External AI coach answers through your server's AI provider — but none is configured yet. Set up a server provider (or your own key) to use it."
                        )
                    )
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: HLSpace.xl)
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
            }
            .hlScrollEdgeSoft()
            .hlScreenBackground()
            .navigationTitle(String(localized: "External AI"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HLButton(
                    String(localized: "Set up a provider"),
                    variant: .primary,
                    size: .large
                ) {
                    // Dismiss the provider-needed step + the Coach sheet, then
                    // route the operator to Settings → Assistant where the
                    // provider / BYO key is configured.
                    showCoachProviderNeeded = false
                    dismissCoachSheet()
                    appRouter.requestSettingsAssistant()
                }
                .tint(HLAccent.primary)
                .padding(HLSpace.lg)
                // 08-12 — 08-14 audited the Coach family by file list and this
                // one was not on it; the shelf paints a raw material like the
                // five that were. Preference first, same material otherwise.
                .background(HLMaterialBackground(.regularMaterial))
            }
        }
        .hlSheetPresentation(.form)
        .presentationBackground(HLColor.surface)
    }
}

// MARK: - Coach source-choice page (v0.14.7 COACH-redesign)

/// The one-page on-device-vs-server choice surface. Owns the local
/// `selectedMode` so the picker is a live selection committed by the single
/// primary CTA — no two equal giant buttons. Privacy-first default: On-device is
/// pre-selected, so a user who just wants to proceed taps one calm button.
private struct CoachSourceChoiceView: View {
    let onDeviceCapable: Bool
    /// v0.14.1 — true when a server AI provider is configured, so the External AI
    /// path can actually work. When false the External AI card is rendered
    /// disabled-with-reason and committing it routes to the provider-needed step
    /// instead of a consent sheet that would noop + silently bounce.
    let hasServerProvider: Bool
    let onRequestServerConsent: () -> Void
    let onChooseOnDevice: () -> Void
    /// v0.14.1 — invoked when the user tries to use External AI but no server
    /// provider is configured. The host routes to Settings → Assistant.
    let onNeedsProvider: () -> Void

    /// On-device pre-selected (privacy-first default) on a capable device; on a
    /// non-capable device only the server path exists so the selection is moot.
    @State private var selectedMode: AIMode

    init(
        onDeviceCapable: Bool,
        hasServerProvider: Bool,
        onRequestServerConsent: @escaping () -> Void,
        onChooseOnDevice: @escaping () -> Void,
        onNeedsProvider: @escaping () -> Void
    ) {
        self.onDeviceCapable = onDeviceCapable
        self.hasServerProvider = hasServerProvider
        self.onRequestServerConsent = onRequestServerConsent
        self.onChooseOnDevice = onChooseOnDevice
        self.onNeedsProvider = onNeedsProvider
        _selectedMode = State(initialValue: onDeviceCapable ? .onDevice : .online)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                heroLockup
                Text(explanation)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if onDeviceCapable {
                    AISourceChoicePicker(
                        selection: selectedMode,
                        options: choiceOptions,
                        onSelect: { selectedMode = $0 },
                        onRecover: { _ in onNeedsProvider() }
                    )
                }
                Spacer(minLength: HLSpace.xl)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
        }
        .hlScrollEdgeSoft()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HLSpace.sm) {
                HLButton(
                    primaryTitle,
                    variant: .primary,
                    size: .large,
                    action: commitSelection
                )
                .tint(HLAccent.primary)
                Text(String(localized: "You can change this anytime in Settings."))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(HLSpace.lg)
            // The source-choice shelf, same rule as the provider-needed one.
            .background(HLMaterialBackground(.regularMaterial))
        }
    }

    /// Centered hero glyph + large title — mirrors the `AIConsentSheet` lockup.
    private var heroLockup: some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: "sparkles")
                .font(.hlLargeTitle.weight(.light))
                .foregroundStyle(HLText.primary)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(heroTitle)
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// v0.14.1 — the hero title adapts to the reachable choice: a capable device
    /// genuinely chooses; a non-capable device with a provider consents to the
    /// server; a non-capable device with NO provider is told a provider is
    /// required (the CTA then routes to setup, never a silent-bounce consent).
    private var heroTitle: String {
        if onDeviceCapable {
            return String(localized: "Choose your coach")
        }
        if hasServerProvider {
            return String(localized: "Coach via your server")
        }
        return String(localized: "A server provider is required")
    }

    /// The single primary CTA label. Capable device commits the picked source; a
    /// non-capable device with a provider consents to the server; a non-capable
    /// device with no provider routes to setup (v0.14.1 — never a consent noop).
    private var primaryTitle: String {
        if onDeviceCapable {
            return String(localized: "Start the coach")
        }
        if hasServerProvider {
            return String(localized: "Consent and continue")
        }
        return String(localized: "Set up a provider")
    }

    /// v0.14.1 — the two chooser cards (On-device + External AI). External AI is
    /// `.available` only with a configured provider, else disabled-with-reason +
    /// a "set up a provider" recovery chip so the dead-end is unreachable in the
    /// picker. Computed by the pure ``AISourceOptions/coachChoice(hasServerProvider:)``
    /// so the matrix is unit-pinned. On-device stays pre-selected + the default.
    private var choiceOptions: [AISourceOption] {
        AISourceOptions.coachChoice(hasServerProvider: hasServerProvider)
    }

    /// Commits the current selection. On-device flips the mode (so the Coach body
    /// re-routes live into the private path); External AI routes through the
    /// nested `AIConsentSheet` when a provider exists, otherwise to the
    /// provider-needed step (v0.14.1 — never the silent-bounce consent noop).
    private func commitSelection() {
        if onDeviceCapable, selectedMode == .onDevice {
            onChooseOnDevice()
        } else if hasServerProvider {
            onRequestServerConsent()
        } else {
            // No provider → consent would be a noop that bounces back to this
            // chooser. Route to setup instead.
            onNeedsProvider()
        }
    }

    /// v0.14.1 — the explainer adapts to the reachable choice. Capable device →
    /// the on-device-vs-server choice copy; non-capable + provider → the consent
    /// copy; non-capable + NO provider → the honest "set up a provider" copy so
    /// the page never promises a consent that would noop.
    private var explanation: String {
        if onDeviceCapable {
            return serverChoiceExplanation
        }
        if hasServerProvider {
            return serverConsentExplanation
        }
        return providerNeededExplanation
    }

    /// The long consent explanation (non-capable device WITH a provider). The
    /// localized key is a single string literal that cannot be wrapped without
    /// changing its catalogue identity, so the one over-long line carries a local
    /// disable.
    private var serverConsentExplanation: String {
        String(
            // swiftlint:disable:next line_length
            localized: "Your iPhone has no on-device Coach. Your configured server provider can answer instead — your values leave the device for this. Consent once to use the Coach."
        )
    }

    /// v0.14.1 — copy for the non-capable device with NO server provider: the
    /// Coach cannot answer on-device and there is no provider to route through,
    /// so the user is told plainly that a provider must be set up first.
    private var providerNeededExplanation: String {
        String(
            // swiftlint:disable:next line_length
            localized: "Your iPhone has no on-device Coach, and no server AI provider is configured yet. Set up a provider (or your own key) to use the Coach."
        )
    }

    /// Honest copy for the capable-device case: the user CAN stay private
    /// on-device, or opt into the richer server answer.
    private var serverChoiceExplanation: String {
        String(
            // swiftlint:disable:next line_length
            localized: "Your iPhone can answer privately on-device, or your server's AI can give richer answers — your values leave the device for the server path. Your choice."
        )
    }
}
