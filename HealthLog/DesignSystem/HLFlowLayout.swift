import SwiftUI

/// Lays its children out like words in a paragraph: side by side, and on to
/// the next line when the width runs out.
///
/// A child wider than the whole line gets the line's width and no more, and
/// the height it needs at that width. So a long chip shortens its text, or
/// wraps it where it may, instead of running out of the card.
public struct HLFlowLayout: Layout {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat

    /// - Parameters:
    ///   - spacing: gap between two children on a line.
    ///   - lineSpacing: gap between two lines. The same as `spacing` unless
    ///     the children are words of one text, which stand closer.
    public init(spacing: CGFloat = HLSpace.sm, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    /// Where each child stands, measured from the layout's top leading corner.
    /// Children of unequal height are centred on their line.
    public static func frames(
        for sizes: [CGSize],
        in width: CGFloat,
        spacing: CGFloat = HLSpace.sm,
        lineSpacing: CGFloat? = nil
    ) -> [CGRect] {
        let lineGap = lineSpacing ?? spacing
        var frames: [CGRect] = []
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        func closeLine() {
            for index in lineStart ..< frames.count {
                frames[index].origin.y = y + (lineHeight - frames[index].height) / 2
            }
            lineStart = frames.count
        }

        for size in sizes {
            let itemWidth = min(size.width, width)
            // Half a point of tolerance: widths arrive rounded to the pixel.
            if x > 0, x + itemWidth > width + 0.5 {
                closeLine()
                x = 0
                y += lineHeight + lineGap
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing
            lineHeight = max(lineHeight, size.height)
        }
        closeLine()
        return frames
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let frames = frames(for: subviews, in: proposal.width ?? .infinity)
        return CGSize(
            width: frames.map(\.maxX).max() ?? 0,
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    public func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let frames = frames(for: subviews, in: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func frames(for subviews: Subviews, in width: CGFloat) -> [CGRect] {
        Self.frames(
            for: subviews.map { subview in
                let ideal = subview.sizeThatFits(.unspecified)
                guard ideal.width > width else { return ideal }
                return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            },
            in: width,
            spacing: spacing,
            lineSpacing: lineSpacing
        )
    }
}

#Preview("HLFlowLayout, light") {
    HLFlowLayoutPreview()
        .preferredColorScheme(.light)
}

#Preview("HLFlowLayout, dark") {
    HLFlowLayoutPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLFlowLayout, largest type") {
    HLFlowLayoutPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLFlowLayoutPreview: View {
    @State private var selected: Set<String> = ["Pulse"]
    private let titles = ["Blood pressure", "Weight", "Pulse", "Sleep", "Mood", "Notes", "Medications"]

    var body: some View {
        HLPage {
            HLCard("Overview") {
                HLFlowLayout {
                    ForEach(titles, id: \.self) { title in
                        HLChip(LocalizedStringKey(title), isSelected: selected.contains(title)) {
                            selected.formSymmetricDifference([title])
                        }
                    }
                }
            }
        }
    }
}
