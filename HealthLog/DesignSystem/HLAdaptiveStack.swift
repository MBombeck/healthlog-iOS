import SwiftUI

/// Side by side at the standard text sizes, one above the other from the
/// first accessibility size on.
///
/// For a label and its control, two fields that belong together or a title
/// and its figure that a screen lays out itself. Beside each other at the
/// largest sizes each gets a narrow column and German words break into
/// syllables („Du / n- / kel", „Systo- / lisch"); stacked, each has the full
/// width. Below the accessibility sizes the stack is a plain `HStack`, so the
/// standard sizes look exactly as before.
///
/// The content is told which arrangement it stands in, so a spacer or a
/// separator that only makes sense side by side can stay out of the column:
///
///     HLAdaptiveStack { stacked in
///         HLRowTitle("Appearance")
///         if !stacked { Spacer(minLength: HLSpace.md) }
///         picker
///     }
struct HLAdaptiveStack<Content: View>: View {
    /// Room between the parts once they stand one above the other.
    static var stackedSpacing: CGFloat {
        HLSpace.xs
    }

    private let alignment: VerticalAlignment
    private let spacing: CGFloat?
    private let content: (Bool) -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - alignment: the vertical alignment side by side.
    ///   - spacing: the room between the parts side by side; `nil` is the
    ///     system's spacing, as in an `HStack`.
    init(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: @escaping (_ stacked: Bool) -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    /// Whether the parts stand one above the other at this text size.
    static func isStacked(at typeSize: DynamicTypeSize) -> Bool {
        typeSize.isAccessibilitySize
    }

    var body: some View {
        if Self.isStacked(at: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: Self.stackedSpacing) {
                content(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                content(false)
            }
        }
    }
}
