import SwiftUI

// MARK: - Swipe to dismiss

public extension View {
    /// A card that is put away like a mail in Mail: it follows the finger to
    /// either side, past ``HLSwipeToDismiss/threshold`` of its width or on a
    /// quick flick it leaves and `onDismiss` runs; short of that it springs
    /// back. Under it a quiet symbol shows while it is pulled.
    ///
    /// The gesture locks to the side only once the movement is clearly
    /// sideways, so the page keeps scrolling. The same action is offered as a
    /// named accessibility action and in the long-press menu; without them it
    /// could not be found. Under Reduce Motion the card does not move, it
    /// fades.
    ///
    /// - Parameters:
    ///   - title: the action's name ("Ausblenden") for VoiceOver, keyboard
    ///     and the menu.
    ///   - systemImage: the symbol under the card and in the menu.
    func hlSwipeToDismiss(
        isEnabled: Bool = true,
        title: LocalizedStringKey = "Hide",
        systemImage: String = HLSwipeToDismiss.symbol,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(HLSwipeToDismissModifier(
            isEnabled: isEnabled,
            title: title,
            systemImage: systemImage,
            onDismiss: onDismiss
        ))
    }
}

public extension EnvironmentValues {
    /// `true` inside a swipeable card while a sideways pull is under way or
    /// the card is leaving. A button that is the card itself reads it and
    /// ignores the touch that ends a swipe, which would otherwise also count
    /// as a tap.
    @Entry var hlSwipeIsActive: Bool = false
}

/// The rules of ``SwiftUI/View/hlSwipeToDismiss(isEnabled:title:systemImage:onDismiss:)``,
/// as plain values so a test can hold them.
public enum HLSwipeToDismiss {
    /// Share of the card's width past which letting go puts it away. Half
    /// the width, so putting a card away is a decision, not a graze.
    public static let threshold: CGFloat = 0.5
    /// A flick whose predicted end lies this far out puts it away too.
    public static let flickShare: CGFloat = 1.6
    /// A flick only counts once the card has really been moved: a nudge of a
    /// few points with a quick finger springs back.
    public static let flickMinimumShare: CGFloat = 0.25
    /// The card follows the finger with this much weight: it travels a little
    /// less than the finger, which reads as mass, not as lag.
    public static let resistance: CGFloat = 0.85
    /// Movement before the gesture decides on an axis.
    public static let decisionDistance: CGFloat = 16
    /// Sideways counts only when it is this many times the vertical part.
    public static let sidewaysRatio: CGFloat = 2
    /// The symbol under a pulled card.
    public static let symbol = "checkmark"

    public enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    /// The axis a drag locks to, `nil` while it is still too short to tell.
    /// Anything not clearly sideways belongs to the page's scrolling.
    public static func axis(for translation: CGSize) -> Axis? {
        let dx = abs(translation.width)
        let dy = abs(translation.height)
        guard max(dx, dy) >= decisionDistance else { return nil }
        return dx >= dy * sidewaysRatio ? .horizontal : .vertical
    }

    /// Where the card sits for a finger travel: it follows with weight.
    public static func resistedOffset(_ translation: CGFloat) -> CGFloat {
        translation * resistance
    }

    /// Whether the pull has gone past the threshold (the moment of the light
    /// haptic and of the full symbol).
    public static func isPastThreshold(_ offset: CGFloat, width: CGFloat) -> Bool {
        width > 0 && abs(offset) >= width * threshold
    }

    /// Whether letting go puts the card away: past the threshold, or a flick
    /// toward the same side whose predicted end leaves the card.
    public static func dismisses(offset: CGFloat, predictedEnd: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, offset != 0 else { return false }
        if isPastThreshold(offset, width: width) { return true }
        guard abs(offset) >= width * flickMinimumShare else { return false }
        let sameSide = (predictedEnd > 0) == (offset > 0)
        return sameSide && abs(predictedEnd) >= width * flickShare
    }

    /// How visible the symbol under the card is: it comes in with the pull
    /// and is fully there at the threshold.
    public static func symbolOpacity(_ offset: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, abs(offset) / (width * threshold)))
    }
}

private struct HLSwipeToDismissModifier: ViewModifier {
    let isEnabled: Bool
    let title: LocalizedStringKey
    let systemImage: String
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The finger's sideways travel; under Reduce Motion only its measure.
    @State private var offset: CGFloat = 0
    @State private var axis: HLSwipeToDismiss.Axis?
    @State private var width: CGFloat = 0
    @State private var isPastThreshold = false
    @State private var isLeaving = false

    func body(content: Content) -> some View {
        if isEnabled {
            swipeable(content)
        } else {
            content
        }
    }

    private func swipeable(_ content: Content) -> some View {
        content
            .environment(\.hlSwipeIsActive, axis == .horizontal || isLeaving || offset != 0)
            .offset(x: reduceMotion ? 0 : offset)
            .opacity(cardOpacity)
            .background(alignment: offset >= 0 ? .leading : .trailing) {
                Image(systemName: systemImage)
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.xl)
                    .opacity(HLSwipeToDismiss.symbolOpacity(offset, width: width))
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(drag)
            .sensoryFeedback(.impact(weight: .light), trigger: isPastThreshold) { _, new in new }
            .accessibilityAction(named: Text(title)) { onDismiss() }
            .contextMenu {
                Button { onDismiss() } label: { Label(title, systemImage: systemImage) }
            }
    }

    private var cardOpacity: Double {
        if isLeaving { return 0 }
        guard reduceMotion, width > 0 else { return 1 }
        // Under Reduce Motion the pull shows as fading, not as travel.
        return 1 - 0.5 * HLSwipeToDismiss.symbolOpacity(offset, width: width)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: HLSwipeToDismiss.decisionDistance)
            .onChanged { value in
                guard !isLeaving else { return }
                if axis == nil { axis = HLSwipeToDismiss.axis(for: value.translation) }
                guard axis == .horizontal else { return }
                offset = HLSwipeToDismiss.resistedOffset(value.translation.width)
                isPastThreshold = HLSwipeToDismiss.isPastThreshold(offset, width: width)
            }
            .onEnded { value in
                defer { axis = nil }
                guard axis == .horizontal, !isLeaving else { return }
                if HLSwipeToDismiss.dismisses(
                    offset: offset,
                    predictedEnd: HLSwipeToDismiss.resistedOffset(value.predictedEndTranslation.width),
                    width: width
                ) {
                    leave()
                } else {
                    // Back with a settled spring: heavy, no bounce-back flick.
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) { offset = 0 }
                    isPastThreshold = false
                }
            }
    }

    /// Out to the side it was pulled to (or faded), then the action.
    private func leave() {
        isLeaving = true
        let side: CGFloat = offset >= 0 ? 1 : -1
        // Out with weight: a critically damped spring that carries the card off
        // instead of a quick cut, so it feels put away rather than flung.
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 1)) {
            if !reduceMotion { offset = side * (width + HLSpace.xxxl) }
        } completion: {
            onDismiss()
        }
    }
}
