import SwiftUI

/// Task #53 — the onboarding AI-source step. ONE clean screen presenting the
/// same mode- + capability-aware choice the user gets in Settings → Assistant
/// (None / On-device / External AI / Own key, gated by operating mode +
/// on-device capability), built on the shared `AISourceChoicePicker` so the two
/// surfaces share a single design language. Skippable.
///
/// **Default selection (operator review):** an undecided user defaults to
/// External AI (`.online`) **when the server has an AI provider configured AND
/// the `.online` card is actually selectable** — see `applyDefaultSelection` /
/// `shouldDefaultToOnline`. Otherwise the privacy-first **None** default holds
/// (no provider, standalone, or a disabled `.online` card). A returning user's
/// explicit prior choice always wins.
///
/// Onboarding semantics differ slightly from Settings: the `.online` and
/// `.byoKey` arms need a configured provider / saved key + the informed-consent
/// sheet, and neither exists yet at this point in the flow (the authenticated
/// shell isn't mounted). So `.none` / `.onDevice` apply immediately; picking
/// `.online` or `.byoKey` records the intent (and surfaces a calm "finish in
/// Settings" note) rather than firing a doomed consent prompt — the user
/// completes that setup in Settings → Assistant, the canonical path. Never a
/// dead button, never an empty box.
///
/// Design (PROJECT_GUIDE.md Marathon + monochrome doctrine): calm header, the shared
/// picker, a reduce-motion-gated staggered entrance matching `ModeSelectionStep`,
/// a "Continue" CTA + a "Skip" ghost. Zero glass on the content cards.
struct AISourceStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// v0.13 W3 — operating mode (2nd matrix axis). In standalone the External
    /// AI card is dropped — a standalone install has no server provider.
    @Environment(BackendAvailability.self) private var backend
    @Environment(\.scenePhase) private var scenePhase

    /// Local working selection so the cards reflect the tap instantly; the
    /// choice is committed to `AIConsentStore` on the same tap (idempotent) and
    /// again on Continue, so a Skip without a tap leaves the privacy-first
    /// `.none` default untouched.
    @State private var selection: AIMode = .none
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)

                AISourceChoicePicker(
                    selection: selection,
                    options: offeredOptions,
                    onSelect: { mode in
                        selection = mode
                        commit(mode)
                    }
                )
                // Onboarding keeps the reason copy passive — no Settings
                // deep-link affordance mid-flow (BRIEF: don't overload). The
                // disabled card still teaches the user the feature exists.
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : entranceOffset)
                .animation(cardAnimation(index: 0), value: appeared)

                if selection == .online {
                    onlineFollowUpNote
                        .opacity(appeared ? 1 : 0)
                        .animation(cardAnimation(index: 1), value: appeared)
                }

                if selection == .byoKey {
                    byoKeyFollowUpNote
                        .opacity(appeared ? 1 : 0)
                        .animation(cardAnimation(index: 1), value: appeared)
                }

                Spacer(minLength: HLSpace.xxl)
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.top, HLSpace.xxl)
        }
        .background(HLColor.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HLSpace.sm) {
                HLButton(String(localized: "Continue"), variant: .primary, size: .large) {
                    commit(selection)
                    onNext()
                }
                .accessibilityIdentifier("onboarding.aiSource.continue")
                HLButton(String(localized: "Later"), variant: .ghost) {
                    onSkip()
                }
                .accessibilityIdentifier("onboarding.aiSource.skip")
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.bottom, HLSpace.xxxl)
            .background(HLColor.background)
        }
        .onChange(of: scenePhase) { _, phase in
            // v0.13 W3 — re-probe on-device availability when the user comes
            // back from System Settings (e.g. just enabled Apple Intelligence)
            // so a disabled On-device card unlocks live, no relaunch.
            if phase == .active { container?.localLLMService.refresh() }
        }
        .onAppear {
            applyDefaultSelection()
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    appeared = true
                }
            }
        }
    }

    /// v0.13 W3 — the mode- + capability-aware option list. Standalone drops
    /// the External AI card; on-device is capability-gated (hidden when
    /// permanently incapable, shown disabled-with-reason when recoverable).
    /// `.byoKey` is offered in both modes (mode-invariant — client-side).
    private var offeredOptions: [AISourceOption] {
        AISourceOptions.offered(
            operatingMode: backend.mode,
            onDeviceAvailability: container?.onDeviceAIAvailability ?? .unsupported
        )
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "sparkles")
                // Canonical onboarding hero glyph (`HLIconSize.display`, mono)
                // shared across the HealthKit / Notifications / AI-source steps
                // so the header rhythm reads identical step-to-step.
                .font(.hlIcon(HLIconSize.display))
                .foregroundStyle(HLText.primary)
            Text(String(localized: "Choose your assistant"))
                .font(.hlTitle1)
                .foregroundStyle(HLText.primary)
            Text(
                String(
                    localized: "HealthLog can add findings and a coach. Pick how — privately on your device, online from your provider, or not at all. You can change this anytime in Settings."
                )
            )
            .font(.hlBody)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shown only when `.online` is selected — onboarding cannot grant the
    /// per-provider consent yet, so we set expectations honestly instead of
    /// firing a doomed prompt.
    private var onlineFollowUpNote: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "info.circle")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            Text(
                String(
                    localized: "You'll finish connecting your online provider in Settings → Assistant after setup."
                )
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    /// v0.13 W4 — shown only when "Own key" is selected. Onboarding stays LEAN:
    /// it records the intent (`setAIMode(.byoKey)` via `commit`) and points the
    /// user at the canonical key-entry path in Settings. Honest (real intent +
    /// clear next step), not a dead-end — mirrors the online follow-up note.
    private var byoKeyFollowUpNote: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "info.circle")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            Text(
                String(
                    localized: "You'll add your API key in Settings → Assistant after setup."
                )
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Default selection

    /// Resolve and apply the initial selection on first paint.
    ///
    /// Order of precedence:
    /// 1. **A pre-existing explicit choice** (e.g. re-onboarding after pairing)
    ///    always wins — `container.aiMode` is reflected verbatim so a returning
    ///    user is never silently re-defaulted.
    /// 2. **Otherwise**, if a server AI provider is configured AND the External
    ///    AI (`.online`) card is an *available* (selectable) option, pre-select
    ///    `.online` — the operator's review ask: when the server already has an
    ///    AI provider, External AI should be the default. We commit through the
    ///    same `commit(.online)` path a tap uses (records intent only; the
    ///    consent grant still finishes in Settings — that contract is unchanged).
    /// 3. **Else** the privacy-first `.none` default holds (no provider, or
    ///    `.online` not offered/disabled — standalone, dead card, etc.).
    private func applyDefaultSelection() {
        // (1) Honour an explicit prior choice untouched.
        if let existing = container?.aiMode, existing != .none {
            selection = existing
            return
        }

        // (2) Default to External AI when the server has a provider AND the
        //     `.online` card is actually selectable (never pre-select a dead /
        //     disabled card).
        if Self.shouldDefaultToOnline(
            providerConfigured: container?.aiProviderStore.config?.isServerAIAvailable == true,
            options: offeredOptions
        ) {
            selection = .online
            commit(.online)
            return
        }

        // (3) Privacy-first default.
        selection = .none
    }

    /// Pure decision: should the step pre-select External AI by default?
    ///
    /// `true` iff a server provider is configured AND `.online` is present in the
    /// offered options as an `.available` (selectable) card. Kept pure + static
    /// so the precedence rule is unit-pinned out of the View body.
    static func shouldDefaultToOnline(
        providerConfigured: Bool,
        options: [AISourceOption]
    ) -> Bool {
        guard providerConfigured else { return false }
        return options.contains { $0.mode == .online && $0.isAvailable }
    }

    // MARK: - Commit

    /// Persist the pick. `.none` / `.onDevice` apply immediately. For `.online`
    /// we do NOT request the consent prompt here (`requestOnlineConsent: false`)
    /// — the authenticated shell that hosts `AIConsentSheet` isn't up yet, so
    /// the actual grant happens in Settings. We still clear the on-device flag
    /// so the resolved `aiMode` is coherent (stays `.none` until a grant lands).
    private func commit(_ mode: AIMode) {
        guard let container else { return }
        container.aiConsentStore.setMode(
            mode,
            activeProvider: container.resolvedAIProvider,
            requestOnlineConsent: false
        )
    }

    // MARK: - Entrance

    private var entranceOffset: CGFloat {
        reduceMotion ? 0 : 14
    }

    private func cardAnimation(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.85)
            .delay(0.05 * Double(index + 1))
    }
}
