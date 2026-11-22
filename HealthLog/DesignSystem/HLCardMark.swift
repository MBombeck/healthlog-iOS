import SwiftUI

public extension View {
    /// Marks a card for a moment: a ring in the tint around the card's own
    /// shape, for the card a link pointed at ("this one"). Not a selection
    /// and not a state, so VoiceOver hears nothing of it; the ring fades in
    /// and out, at once with Reduce Motion.
    func hlCardMark(_ isMarked: Bool) -> some View {
        modifier(HLCardMarkModifier(isMarked: isMarked))
    }
}

/// The width of the ring: twice a card outline, so it reads as a mark and
/// not as the outline style of a card.
enum HLCardMarkMetrics {
    static let ringWidth: CGFloat = HLCardSurface.outlineWidth * 2
}

private struct HLCardMarkModifier: ViewModifier {
    let isMarked: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                    .strokeBorder(.tint, lineWidth: HLCardMarkMetrics.ringWidth)
                    .opacity(isMarked ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .hlAnimation(.smooth, value: isMarked)
    }
}
