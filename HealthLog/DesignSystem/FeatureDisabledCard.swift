import SwiftUI

/// Neutral Tonal-Mono placeholder rendered in place of a disabled
/// server-AI or on-device assistant surface.
///
/// **F-1 contract (server brief v1.4.31 §c.1 + R5):** when the
/// operator turns off an `assistant.<surface>` flag via
/// `/api/feature-flags`, every surface that would have rendered the
/// gated content mounts this card instead. The copy is intentionally
/// neutral — it never blames the user, never names the underlying
/// surface key, and never offers a "turn it on" affordance (the
/// operator is the only legitimate writer).
///
/// **Visual.** `HLCard(style: .ghost)` over the canvas; the muted
/// icon + textSecondary headline + textTertiary subtitle place the
/// card at the bottom of the visual-weight ladder so the rest of the
/// screen still reads as "alive" (Withings empty-state rhythm,
/// T2-4).
public struct FeatureDisabledCard: View {
    public enum Variant {
        /// Hero variant — full padding, larger icon. Use at the top
        /// of a screen when the entire surface would have been an AI
        /// card (Daily Briefing hero, Insights mother-page hero).
        case hero
        /// Inline variant — tighter padding, smaller icon. Use when
        /// the disabled card replaces a single sub-section card
        /// (Correlations panel, BMI card, BP-status card).
        case inline
    }

    public let variant: Variant
    /// **Audit A-7 — the server's own sentence, when it sent one.**
    ///
    /// The generic subtitle explains nothing: it is the same text whether the
    /// operator turned the module off instance-wide or the sharing grant the
    /// viewer is inside does not cover it. When ``ModuleGate/offReason(_:)``
    /// can name the reason, it replaces the guess. `nil` → unchanged copy,
    /// which is also what every operator-flag surface (F-1) passes.
    public let reason: String?

    public init(variant: Variant = .inline, reason: String? = nil) {
        self.variant = variant
        self.reason = reason
    }

    public var body: some View {
        HLCard(style: .ghost) {
            HStack(spacing: HLSpace.md) {
                Image(systemName: "moon.zzz")
                    .font(iconFont)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(String(localized: "feature_disabled.title"))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.secondary)
                    Text(reason ?? String(localized: "feature_disabled.subtitle"))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var iconFont: Font {
        switch variant {
        case .hero: Font.hlTitle1.weight(.regular)
        case .inline: Font.hlTitle2.weight(.regular)
        }
    }
}

#Preview("FeatureDisabledCard") {
    VStack(spacing: HLSpace.lg) {
        FeatureDisabledCard(variant: .hero)
        FeatureDisabledCard(variant: .inline)
        FeatureDisabledCard(variant: .inline, reason: ModuleAccessState.notGranted.offReason)
    }
    .padding()
    .background(HLSurface.primary)
}
