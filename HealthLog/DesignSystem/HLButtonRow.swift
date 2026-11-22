import SwiftUI

/// How high the buttons of an ``HLButtonRow`` stand.
public enum HLButtonRowSize: Sendable {
    /// The height of every other button.
    case regular
    /// The hit-target floor and the smaller type, for a row inside a card.
    case small
}

extension EnvironmentValues {
    /// The size the enclosing ``HLButtonRow`` gives its buttons.
    @Entry var hlButtonRowSize: HLButtonRowSize = .regular
}

/// Several actions of equal rank in one row, all equally wide.
///
/// The row holds what a pair cannot: three amounts to add, three answers to
/// a question. None of them is the main action; a main action and the one
/// beside it are an ``HLButtonPair``.
///
/// Side by side every button has the same share of the width, in the order
/// they are written. They stand one above the other from the first
/// accessibility text size on, and below that as soon as one of them no
/// longer has room for its whole label on one line. A title is never shrunk
/// or wrapped to keep the row on one line.
///
///     HLButtonRow(size: .small) {
///         HLButton(Text(verbatim: "+250 ml"), variant: .secondary) { add(250) }
///         HLButton(Text(verbatim: "+500 ml"), variant: .secondary) { add(500) }
///         HLButton(Text(verbatim: "+750 ml"), variant: .secondary) { add(750) }
///     }
public struct HLButtonRow<Content: View>: View {
    private let size: HLButtonRowSize
    private let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(size: HLButtonRowSize = .regular, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    public var body: some View {
        arranged
            .environment(\.hlButtonRowSize, size)
    }

    @ViewBuilder
    private var arranged: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HLEqualWidthRow(spacing: HLLayout.buttonGap) { content }
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(spacing: HLLayout.buttonGap) { content }
    }
}

#Preview("HLButtonRow, light") {
    HLButtonRowPreview()
        .preferredColorScheme(.light)
}

#Preview("HLButtonRow, dark") {
    HLButtonRowPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLButtonRow, largest type") {
    HLButtonRowPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLButtonRowPreview: View {
    var body: some View {
        HLPage {
            HLCard("Water") {
                HLButtonRow(size: .small) {
                    ForEach([250, 500, 750], id: \.self) { amount in
                        HLButton(Text(verbatim: "+\(amount) ml"), variant: .secondary) {}
                    }
                }
            }
            HLButtonRow {
                HLButton(HLControlWord.edit.key, variant: .secondary) {}
                HLButton(HLControlWord.retry.key, variant: .secondary) {}
            }
            // Too long for a third of the width: the row stands stacked.
            HLButtonRow(size: .small) {
                HLButton(Text(verbatim: "Blood pressure"), variant: .secondary) {}
                HLButton(Text(verbatim: "Heart rate variability"), variant: .secondary) {}
                HLButton(Text(verbatim: "Weight"), variant: .secondary) {}
            }
        }
    }
}
