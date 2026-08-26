import SwiftUI

/// Task #53 — the single, elegant AI-source choice component, shared 1:1
/// between the onboarding step and Settings → Assistant. The user picks
/// *whether* and *which* assistant to use. There is exactly ONE choice surface
/// — selectable cards, each with a one-line description — no submenu sprawl.
///
/// **v0.13 W3 — mode- + capability-aware.** The component no longer takes a flat
/// `[AIMode]`; it takes `[AISourceOption]` (computed by the host via
/// ``AISourceOptions/offered(operatingMode:onDeviceAvailability:)``). Each card
/// is either `.available` (selectable) or `.disabledWithReason` (greyed,
/// non-tappable, with a one-line reason + an optional recovery affordance such
/// as a Settings deep-link). Cards that can never work on this device/mode are
/// not in the list at all (hidden, not disabled — D4). `.byoKey` is offered in
/// BOTH operating modes (mode-invariant) — it is client-side, needing no server.
///
/// Design discipline (PROJECT_GUIDE.md Marathon + monochrome doctrine):
/// - Monochrome content card, zero glass (glass is chrome only). The selected
///   card carries the only signal accent: a `.tint` check + ring.
/// - Reduce-motion-gated press feedback (reuses the `ModeSelectionStep`
///   `PathCard` press idiom so onboarding + Settings feel identical).
/// - Dynamic-Type-safe: icon chips are fixed 44pt, all copy scales.
/// - No hardcoded strings — every label/subtitle is an `AIMode` localized
///   accessor (xcstrings, EN source + DE); reasons come from `AISourceOption`.
struct AISourceChoicePicker: View {
    /// The currently resolved mode (source of truth lives in `AIConsentStore`).
    let selection: AIMode
    /// The offered options, in display order, computed by the host from the
    /// operating mode × on-device capability. v0.13 W3.
    let options: [AISourceOption]
    /// Invoked when the user taps an *available* card. The host decides what a
    /// pick means (Settings routes `.online` through the consent sheet;
    /// onboarding records the intent) — this view only reports the tap. Disabled
    /// cards never call this.
    let onSelect: (AIMode) -> Void
    /// Invoked when the user taps a disabled card's recovery affordance (e.g.
    /// "Open Settings" for Apple-Intelligence-off). The host owns the actual
    /// `openURL`. Optional — onboarding may pass `nil` to render the reason
    /// passively without a recovery chip.
    var onRecover: ((AISourceRecovery) -> Void)?

    var body: some View {
        VStack(spacing: HLSpace.md) {
            ForEach(options) { option in
                AISourceCard(
                    option: option,
                    isSelected: option.mode == selection,
                    onSelect: { onSelect(option.mode) },
                    onRecover: onRecover
                )
            }
        }
        // v0.14.7 C3 — pin the selection accent to the monochrome
        // `HLAccent.primary` token (same fix AIConsentSheet.swift:87 applies to
        // its CTA). The cards draw their selection ring + check + recovery chip
        // with `.tint`; without this pin that `.tint` inherited the ambient
        // AccentColor asset, which resolves to system blue → operator saw
        // "standalone blue tiles that look buggy". Pinning here fixes every
        // host of the picker (Settings → Assistant, onboarding, AskCoach) at
        // once, keeping the chrome monochrome per the design doctrine.
        .tint(HLAccent.primary)
    }
}

/// One AI-source card. Mirrors the onboarding `PathCard` shape so the surfaces
/// share a visual language, plus a leading selection ring + trailing check so
/// the current pick reads at a glance. A `.disabledWithReason` card greys out,
/// drops the press idiom, and renders its reason (+ optional recovery chip)
/// under the subtitle.
private struct AISourceCard: View {
    let option: AISourceOption
    let isSelected: Bool
    let onSelect: () -> Void
    let onRecover: ((AISourceRecovery) -> Void)?

    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: AIMode {
        option.mode
    }

    private var isDisabled: Bool {
        !option.isAvailable
    }

    private var reasonInfo: (reason: String, recovery: AISourceRecovery?)? {
        if case let .disabledWithReason(reason, recovery) = option.state {
            return (reason, recovery)
        }
        return nil
    }

    var body: some View {
        Button(action: onSelect) {
            cardContent
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("aiSourceChoice.\(mode.rawValue)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(accessibilityTraits)
        .accessibilityHint(accessibilityHint)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDisabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .top, spacing: HLSpace.md) {
                iconChip
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text(mode.choiceTitle)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(mode.choiceSubtitle)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: HLSpace.sm)
                selectionSignal
            }
            if let reasonInfo {
                reasonRow(reason: reasonInfo.reason, recovery: reasonInfo.recovery)
            }
        }
        .padding(HLSpace.md)
        .background(HLColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .stroke(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLColor.separator.opacity(0.4)),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        // Disabled cards read as "exists but not reachable right now": greyed
        // content, no press idiom, full-card non-tap (the recovery chip is the
        // only live affordance).
        .opacity(isDisabled ? 0.55 : 1.0)
        .scaleEffect(pressed && !reduceMotion ? 0.985 : 1.0)
        .hlAnimation(.spring(response: 0.18, dampingFraction: 0.85), value: pressed)
    }

    /// Selection signal — the only accent on the card. A check when chosen, a
    /// hollow circle when not. Suppressed on disabled cards (they can't be the
    /// current pick).
    @ViewBuilder
    private var selectionSignal: some View {
        if !isDisabled {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.tertiary))
                .padding(.top, HLSpace.xxs)
                .accessibilityHidden(true)
        }
    }

    /// Reason + optional recovery affordance for a disabled card.
    private func reasonRow(reason: String, recovery: AISourceRecovery?) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .top, spacing: HLSpace.xs) {
                Image(systemName: "info.circle")
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                Text(reason)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recovery, let onRecover {
                Button {
                    onRecover(recovery)
                } label: {
                    Text(recovery.actionTitle)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("aiSourceChoice.\(mode.rawValue).recover")
            }
        }
        .padding(.leading, 44 + HLSpace.md) // align under the title, past the icon chip
    }

    private var iconChip: some View {
        Image(systemName: mode.choiceSymbol)
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(HLText.primary)
            .frame(width: 44, height: 44)
            .background(HLText.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }

    private var accessibilityTraits: AccessibilityTraits {
        if isDisabled { return [.isButton] }
        return isSelected ? [.isButton, .isSelected] : .isButton
    }

    private var accessibilityHint: Text {
        if let reasonInfo {
            return Text(reasonInfo.reason)
        }
        return Text(String(localized: "Tap to choose this option"))
    }
}

// MARK: - Recovery presentation

extension AISourceRecovery {
    /// The button title for the recovery chip on a disabled card.
    var actionTitle: String {
        switch self {
        case .openAppleIntelligenceSettings:
            String(
                localized: "Open Settings",
                comment: "AI source picker — recovery action to open system Settings (Apple Intelligence)"
            )
        case .openAssistantSettings:
            String(
                localized: "Set up a provider",
                comment: "AI source picker — recovery action to open in-app Settings → Assistant to add a server AI provider"
            )
        }
    }
}

// MARK: - AIMode presentation

extension AIMode {
    /// SF Symbol for the choice card. Monochrome — rendered in `HLText.primary`.
    var choiceSymbol: String {
        switch self {
        case .none: "moon.zzz"
        case .onDevice: "iphone.gen3"
        case .byoKey: "key"
        case .online: "cloud"
        }
    }

    /// One-line title for the choice card.
    var choiceTitle: String {
        switch self {
        case .none: String(localized: "No assistant", comment: "AI source choice — title for the none option")
        case .onDevice: String(localized: "On-device", comment: "AI source choice — title for the on-device option")
        case .byoKey: String(localized: "Own key", comment: "AI source choice — title for the bring-your-own-key option")
        case .online: String(localized: "External AI", comment: "AI source choice — title for the external/server-AI option")
        }
    }

    /// One-line description shown under each choice card.
    var choiceSubtitle: String {
        switch self {
        case .none:
            String(
                localized: "No AI surfaces. Your data stays as numbers and charts.",
                comment: "AI source choice — subtitle for the none option"
            )
        case .onDevice:
            String(
                localized: "Generated privately on your iPhone. Works offline, nothing is transmitted.",
                comment: "AI source choice — subtitle for the on-device option"
            )
        case .byoKey:
            String(
                localized: "Use your own AI provider key. Requests go straight from this device to your provider.",
                comment: "AI source choice — subtitle for the bring-your-own-key option"
            )
        case .online:
            String(
                localized: "Richer findings and Coach from your server's AI provider. Needs a server connection.",
                comment: "AI source choice — subtitle for the external/server-AI option"
            )
        }
    }
}
