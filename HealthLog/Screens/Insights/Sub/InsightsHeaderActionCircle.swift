import SwiftUI

/// #33 — the shared, equal-sized circular header-action affordance used by the
/// Insights headers (Übersicht + per-metric). The operator's build-111 walk
/// found the per-metric header's two trailing buttons (`✦` Coach + gear) at
/// DIFFERENT sizes and on the same row as the title; this primitive gives every
/// non-brand header circle ONE canonical diameter + glass treatment so the
/// buttons can't drift apart.
///
/// The brand Coach coin (`AskCoachCollapsedCoin`, the purple→pink gradient `✦`)
/// keeps its own gradient identity but is rendered at the SAME `Self.diameter`
/// so the two circles read as an equal-sized pair. This circle is the mono
/// glass sibling for the gear / options actions.
struct InsightsHeaderActionCircle: View {
    /// The canonical header-circle diameter. Matches `AskCoachCollapsedCoin`'s
    /// 44pt coin so the Coach + gear read as an equal-sized pair, and meets the
    /// HIG 44pt minimum hit-target without extra padding.
    static let diameter: CGFloat = 44

    let systemImage: String
    let accessibilityLabelText: String
    let accessibilityHintText: String?
    let accessibilityIdentifier: String
    let action: () -> Void

    init(
        systemImage: String,
        accessibilityLabelText: String,
        accessibilityHintText: String? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabelText = accessibilityLabelText
        self.accessibilityHintText = accessibilityHintText
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hlTitle3)
                .foregroundStyle(HLText.secondary)
                .frame(width: Self.diameter, height: Self.diameter)
                .hlGlassEffect(in: Circle(), interactive: true, fallback: HLColor.backgroundEleva)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabelText))
        .modifier(OptionalAccessibilityHint(hint: accessibilityHintText))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Applies an `.accessibilityHint` only when a hint string is provided, so a
/// hint-less action doesn't announce an empty hint.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(Text(hint))
        } else {
            content
        }
    }
}
