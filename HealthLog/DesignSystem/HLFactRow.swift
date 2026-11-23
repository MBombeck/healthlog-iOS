import SwiftUI

/// A label and its value on one line: "Letzte Einnahme … heute, 08:05".
///
/// Both are body text of the same size, the label secondary on the left, the
/// value primary on the right with digits of equal width. At the
/// accessibility sizes the value moves under its label, so neither is
/// squeezed into a column of syllables. Several rows stand in an
/// ``HLFactGroup``.
public struct HLFactRow: View {
    /// Font of the label.
    public static let labelFont: Font = .hlSubhead
    /// Font of the value.
    public static let valueFont: Font = .hlSubhead

    private let label: Text
    private let value: Text
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A label from the catalogue and a value that exists only at run time.
    public init(_ label: LocalizedStringKey, value: String) {
        self.label = Text(label)
        self.value = Text(verbatim: value)
    }

    /// Label and value that are already texts.
    public init(label: Text, value: Text) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    labelText
                    valueText(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    labelText
                    Spacer(minLength: HLSpace.sm)
                    valueText(alignment: .trailing)
                        .layoutPriority(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        label
            .font(Self.labelFont)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueText(alignment: TextAlignment) -> some View {
        value
            .font(Self.valueFont)
            .monospacedDigit()
            .foregroundStyle(HLText.primary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fact rows that belong together, with the gap of one group between them.
public struct HLFactGroup<Content: View>: View {
    /// Gap between two rows of one group.
    public static var spacing: CGFloat {
        HLSpace.xs
    }

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("HLFactRow") {
    HLPage {
        HLCard {
            HLFactGroup {
                HLFactRow(label: Text(verbatim: "Letzte Einnahme"), value: Text(verbatim: "heute, 08:05"))
                HLFactRow(label: Text(verbatim: "Nächste Einnahme"), value: Text(verbatim: "morgen, 08:00"))
                HLFactRow(label: Text(verbatim: "Vorrat"), value: Text(verbatim: "24 Stück"))
            }
        }
    }
}
