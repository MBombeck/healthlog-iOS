import SwiftUI

/// Neutral, monochrome placeholder rendered in place of a **server-derived**
/// surface when the backend is unavailable (standalone install, or a paired
/// install whose server can't be reached for this surface).
///
/// **R4 §3.2 (offline-architecture research) — groundwork primitive.** The
/// server-derived surfaces (Health Score, Daily Briefing, Coach, Insights,
/// Personal Records, Doctor-Report PDF …) have no on-device source of truth.
/// When there is no backend they must degrade *gracefully* — not a spinner that
/// never resolves, not a blank gap, not an alarming error. This card is the calm
/// "connect a server to enable …" state.
///
/// **Distinct from `FeatureDisabledCard`:** that card is for an operator who
/// *turned a feature off* on an otherwise-paired server (`assistant.disabled.*`).
/// This card is for *no server at all* — a different cause, a different CTA
/// (connect, not "the operator switched it off").
///
/// **Visual.** Reuses the `FeatureDisabledCard` rhythm — `HLCard(style: .ghost)`,
/// muted cloud glyph, `textSecondary` headline + `textTertiary` subtitle — so it
/// sits at the bottom of the visual-weight ladder and the rest of the screen
/// still reads as alive (Withings empty-state rhythm). Monochrome by design: no
/// status tints, no accent.
///
/// **Paired-path invariant:** callers gate this behind
/// `BackendAvailability.hasServer` (always `true` in paired mode), so this card
/// never renders for a paired user — the normal live content shows unchanged.
public struct HLCloudDerivedPlaceholder: View {
    public enum Variant {
        /// Hero variant — full padding, larger glyph. Top-of-screen surfaces
        /// (Daily-Briefing hero, Insights mother-page).
        case hero
        /// Inline variant — tighter padding, smaller glyph. A single tile /
        /// sub-section replacement (Health-Score tile, a Coach card).
        case inline
    }

    public let variant: Variant
    /// Optional surface name woven into the subtitle ("Connect a server to
    /// enable **the Health Score**."). When `nil`, a generic subtitle is used so
    /// the card is safe to drop anywhere without bespoke copy.
    private let surfaceName: String?

    /// Optional "Server verbinden" CTA. When non-`nil`, the card renders a
    /// pairing button below the subtitle. The **single shared CTA path** every
    /// adopting surface passes is `{ authStore.beginServerPairing() }`
    /// (`AuthStore.swift`), dropping the standalone user back into the
    /// OnboardingFlow server branch with their local data intact (mirrors
    /// `SettingsScreen.pairServerSection`). `nil` keeps the card a pure
    /// disclosure (the default for snapshot/preview hosts without an
    /// `AuthStore`).
    private let onConnect: (() -> Void)?

    public init(
        variant: Variant = .inline,
        surfaceName: String? = nil,
        onConnect: (() -> Void)? = nil
    ) {
        self.variant = variant
        self.surfaceName = surfaceName
        self.onConnect = onConnect
    }

    public var body: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "cloud")
                        .font(iconFont)
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(String(localized: "cloud_derived.title"))
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.secondary)
                        Text(subtitle)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if let onConnect {
                    Button(action: onConnect) {
                        Text(String(localized: "cloud_derived.cta.connect"))
                            .font(.hlSubhead.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("cloudDerived.connectCTA")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let surfaceName {
            return String(localized: "cloud_derived.subtitle.named \(surfaceName)")
        }
        return String(localized: "cloud_derived.subtitle.generic")
    }

    private var iconFont: Font {
        switch variant {
        case .hero: Font.hlTitle1.weight(.regular)
        case .inline: Font.hlTitle2.weight(.regular)
        }
    }
}

#Preview("HLCloudDerivedPlaceholder") {
    VStack(spacing: HLSpace.lg) {
        HLCloudDerivedPlaceholder(variant: .hero, surfaceName: String(localized: "Health Score"))
        HLCloudDerivedPlaceholder(variant: .inline)
    }
    .padding()
    .background(HLSurface.primary)
}
