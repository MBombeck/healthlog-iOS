// FW1-C (M6) — the Coach coin mirrors the Hero card's AI-brand moment: a
// graphite gradient base (`HLText.primary` → 70%) with a white sparkles glyph.
// The glyph's white now routes through the tokenized `HLColor.aiHeroInk`
// (DesignSystem/Tokens.swift), so this file no longer needs a file-level
// `forbidden_color` disable. See `docs/design-handbook-v1.md` §5 "Exceptions".
//
// Y3 structural changes are preserved:
//   * 44pt diameter (matches Home `HLProfileAvatar` exactly, handbook §2.5).
//   * No hairline backplate stroke, no soft dropshadow — the gradient
//     surface alone carries the affordance, mirroring the Home avatar.
//   * Lives inline in the Insights scroll body, NOT in the trailing
//     toolbar slot.
//
// Only the colour came back; layout + hit area + accessibility stay.
//
import SwiftUI

/// 44pt round coin that surfaces inline inside `InsightsScreen` once the
/// operator dismissed the `AskCoachHeroCard`. The coin sits in the same
/// scroll slot the Hero card would occupy, so dismiss-then-restore feels
/// like the row collapsed into a Gravatar-shaped mark rather than the
/// affordance jumping to a different chrome surface.
///
/// **v0.6.1.3 Y4.1 visual recipe — gradient restored, layout from Y3,
/// Y8 colour-blind affordance:**
/// - 44pt diameter `Circle` filled with the Dracula-Purple → Pink
///   diagonal gradient (parity with the Hero card).
/// - **Y8:** subtle inner hairline ring at 22% white inside the
///   gradient — shape-encodes the affordance so a colour-blind user
///   (or one running "Differentiate without colour") can distinguish
///   it from surrounding inline-header glyph buttons via silhouette,
///   not just hue.
/// - 20pt `sparkles` SF Symbol in `HLColor.aiHeroInk` `.hierarchical`,
///   motion-gated `.symbolEffect(.pulse)` (reduce-motion-aware).
/// - Light sensory feedback on tap.
///
/// **Tap-target:** the visible coin is already 44pt, so the Button's
/// hit area matches the HIG minimum without additional padding. The
/// outer `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(...)`
/// stays as defence against future layout-tightening.
struct AskCoachCollapsedCoin: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tapPulse: Int = 0

    var body: some View {
        Button {
            tapPulse &+= 1
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        // b146 — monochrome doctrine: the Coach coin was a
                        // purple→pink gradient. Swap to a neutral graphite ramp
                        // (primary → 70%) so the ✦ glyph still reads with depth
                        // but no off-doctrine hue.
                        LinearGradient(
                            colors: [HLText.primary, HLText.primary.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                // v0.6.1.12 Y9.2-F — inner white hairline ring dropped.
                // Operator real-device walkthrough on 2026-05-23 flagged
                // it as a "weißer Kreis" around the icon + sparkles that
                // didn't read as an affordance cue, just as visual noise.
                // The gradient + sparkles glyph alone carries the coin
                // identity; the colour-blind affordance from the Y8 H-1
                // pass is now covered by the symbol-renderingMode +
                // pulsing animation, both of which differentiate the coin
                // from inert glyph buttons without an extra stroke.
                Image(systemName: "sparkles")
                    .font(.hlIcon(HLIconSize.lg))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(HLColor.aiHeroInk)
                    .symbolEffect(
                        .pulse,
                        options: reduceMotion ? .nonRepeating : .repeating,
                        isActive: !reduceMotion
                    )
                    .accessibilityHidden(true)
            }
            .frame(width: 44, height: 44)
            // HIG-minimum 44pt hit area. The visible coin is already at
            // the minimum; `contentShape(Rectangle())` guarantees the full
            // square is tappable even if a future avatar refresh trims
            // the visible diameter.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: tapPulse)
        .accessibilityLabel(String(localized: "Ask the coach"))
        .accessibilityHint(String(localized: "Opens the coach card."))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("InsightsScreen.askCoachCollapsedCoin")
    }
}

#Preview("AskCoachCollapsedCoin") {
    HStack {
        Spacer()
        AskCoachCollapsedCoin {}
        Spacer()
    }
    .padding()
    .background(HLSurface.primary)
}
