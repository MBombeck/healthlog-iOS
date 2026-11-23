import SwiftUI

/// App-wide press-feedback for tap-target surfaces — **W1-7 per R5 #6
/// Tier-1 + R2 #3.**
///
/// Apple Health gives every primary tile / row / card a 3-5 pt
/// compression on touch-down + a selection-haptic; HealthLog pre-W1-7
/// shipped `.buttonStyle(.plain)` on most tap-targets, removing the
/// default press-shrink and leaving the surface visually inert. R5
/// flagged this as the dominant "no feedback when I tap" felt-issue.
///
/// Apply via `.buttonStyle(HLPressableButtonStyle())` on a `Button` /
/// `NavigationLink` whose label is a tile/card/row. The style:
///
/// - Renders the label as-is when idle.
/// - Animates `scaleEffect(0.97)` on touch-down (16ms snap).
/// - Fires `.sensoryFeedback(.selection)` on press (iOS 17+ API).
/// - Releases back to scale 1.0 on touch-up (50ms snap).
///
/// **Apple HIG alignment:** the 0.97 compression matches Apple-Health
/// tile press behaviour; the selection-haptic mirrors what iOS 18's
/// default `NavigationLink` already fires on a `.plain`-styled List
/// row. Custom tile surfaces (HLDashboardTile, HLSettingsRow rows
/// wrapped in NavigationLink) get the same feel.
///
/// Honors the system **Reduce Motion** accessibility setting — when
/// enabled, the scale animation is suppressed but the haptic still
/// fires (since haptics are governed by a separate Reduce Vibrations
/// setting and many users want one without the other).
public struct HLPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the pointer does over the surface.
    public enum Hover: Equatable, Sendable {
        /// The surface is highlighted in place, in the label's own shape: a
        /// capsule or round control declares it with
        /// `contentShape(.hoverEffect, …)`, a row keeps its rectangle. The
        /// default, since most pressable things are controls and rows.
        case highlight
        /// The surface rises in the card's rounded shape, as a surface with a
        /// background of its own does under the iPad pointer. Only for cards
        /// and tiles; a lifted row would tear out of its card.
        case lift
    }

    let hover: Hover

    public init(hover: Hover = .highlight) {
        self.hover = hover
    }

    /// The system effect for ``Hover``.
    static func effect(_ hover: Hover) -> HoverEffect {
        switch hover {
        case .lift: .lift
        case .highlight: .highlight
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        hoverShaped(configuration.label)
            .hoverEffect(Self.effect(hover))
            .scaleEffect(scale(for: configuration.isPressed))
            // Apple's two-stage settle. The down-edge stays a
            // crisp 16 ms snap (instant compression feels responsive), but the
            // release-edge now rides a soft `.spring(response:0.3,
            // damping:0.7)` so the surface settles back to rest with a gentle
            // overshoot instead of a mechanical 50 ms cut. Reduce-Motion falls
            // to `nil` (no scale animation at all — `scale(for:)` already pins
            // to 1.0), so the spring only ships when motion is allowed.
            .animation(
                pressAnimation(isPressed: configuration.isPressed),
                value: configuration.isPressed
            )
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, isPressed in
                // Fire only on the touch-down edge (false → true). The
                // release-edge transition shouldn't trigger another
                // haptic; users feel one tap, not two.
                isPressed
            }
    }

    private func scale(for isPressed: Bool) -> CGFloat {
        guard !reduceMotion else { return 1.0 }
        guard isPressed else { return 1.0 }
        return hover == .lift ? Self.cardPressedScale : 0.97
    }

    /// How far a card or tile gives under the finger. A touch deeper than a
    /// control, so a large surface reads as something with weight.
    static let cardPressedScale: CGFloat = 0.965

    /// Two-stage settle: crisp 16 ms compression on touch-down, soft
    /// spring overshoot on release. `nil` under Reduce Motion (no scale
    /// animation; `scale(for:)` stays pinned to 1.0).
    /// A lifted card takes the card's rounded shape for the pointer; a
    /// highlight keeps the shape the label brings.
    @ViewBuilder
    private func hoverShaped(_ label: Configuration.Label) -> some View {
        switch hover {
        case .lift:
            label.contentShape(.hoverEffect, RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
        case .highlight:
            label
        }
    }

    private func pressAnimation(isPressed: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch hover {
        case .lift:
            // A card sinks in over a moment and comes back up slowly, settled,
            // instead of snapping: the press feels like weight, not a switch.
            return isPressed
                ? .easeOut(duration: 0.14)
                : .spring(response: 0.45, dampingFraction: 0.78)
        case .highlight:
            return isPressed
                ? .snappy(duration: 0.016)
                : .spring(response: 0.3, dampingFraction: 0.7)
        }
    }
}

public extension View {
    /// Convenience for `buttonStyle(HLPressableButtonStyle())` —
    /// matches the read-flow of the Apple-style chained modifier and
    /// makes call-sites greppable.
    ///
    /// `hover` is `.highlight` for controls and rows; a tappable card or tile
    /// passes `.lift`.
    func hlPressable(hover: HLPressableButtonStyle.Hover = .highlight) -> some View {
        buttonStyle(HLPressableButtonStyle(hover: hover))
    }
}
