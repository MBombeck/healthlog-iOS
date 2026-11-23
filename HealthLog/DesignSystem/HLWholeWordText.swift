import SwiftUI

/// Prose that never breaks inside a word.
///
/// SwiftUI's `Text` hyphenates German at large sizes ("Genom-/men",
/// "Niedrig-/dosis-CT") and has no switch for it. This view lays the words
/// out one by one: a word that does not fit the rest of a line moves to the
/// next one whole, and a word wider than the whole line shrinks to fit
/// (down to ``minimumScale``) instead of being cut. VoiceOver reads the text
/// as one sentence.
///
/// For identifiers (addresses, tokens) use ``HLIdentifierText``, which breaks
/// after punctuation instead.
struct HLWholeWordText: View {
    /// How far a single word may shrink before it would be cut.
    nonisolated static let minimumScale: CGFloat = 0.5

    private let text: String
    private let font: Font
    private let alignment: HorizontalAlignment

    init(_ text: String, font: Font = .hlBody, alignment: HorizontalAlignment = .leading) {
        self.text = text
        self.font = font
        self.alignment = alignment
    }

    /// The words of `text`, split at whitespace; a run of spaces is one gap.
    nonisolated static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var body: some View {
        HLWordFlowLayout(alignment: alignment) {
            // Two probes give the width of one space in this font.
            Text(verbatim: "a a").font(font).hidden()
            Text(verbatim: "aa").font(font).hidden()
            ForEach(Array(Self.words(text).enumerated()), id: \.offset) { _, word in
                Text(verbatim: word)
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(Self.minimumScale)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Lays words out in lines, breaking only between them. The first two
/// subviews are the space probes of ``HLWholeWordText``.
struct HLWordFlowLayout: Layout {
    let alignment: HorizontalAlignment

    /// Pure: the frames of words of `sizes` in lines of `width`, one `space`
    /// between two words of a line. A word wider than the line keeps a line
    /// of its own at the line's width.
    static func frames(
        for sizes: [CGSize],
        width: CGFloat,
        space: CGFloat,
        alignment: HorizontalAlignment = .leading
    ) -> [CGRect] {
        var lines: [[Int]] = [[]]
        var lineWidth: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let wordWidth = min(size.width, width)
            let needed = lines[lines.count - 1].isEmpty ? wordWidth : lineWidth + space + wordWidth
            if needed > width + 0.5, !lines[lines.count - 1].isEmpty {
                lines.append([index])
                lineWidth = wordWidth
            } else {
                lines[lines.count - 1].append(index)
                lineWidth = needed
            }
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            let used = line.map { min(sizes[$0].width, width) }.reduce(0, +) + space * CGFloat(line.count - 1)
            var x: CGFloat = switch alignment {
            case .center: max((width - used) / 2, 0)
            case .trailing: max(width - used, 0)
            default: 0
            }
            for index in line {
                let wordWidth = min(sizes[index].width, width)
                frames[index] = CGRect(x: x, y: y + (height - sizes[index].height) / 2, width: wordWidth, height: sizes[index].height)
                x += wordWidth + space
            }
            y += height
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let (space, sizes) = measure(subviews)
        let ideal = sizes.map(\.width).reduce(0, +) + space * CGFloat(max(sizes.count - 1, 0))
        let width = proposal.width.map { min($0, ideal) } ?? ideal
        let frames = Self.frames(for: sizes, width: width, space: space, alignment: alignment)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let (space, sizes) = measure(subviews)
        let frames = Self.frames(for: sizes, width: bounds.width, space: space, alignment: alignment)
        for probe in subviews.prefix(2) {
            probe.place(at: bounds.origin, proposal: .zero)
        }
        for (subview, frame) in zip(subviews.dropFirst(2), frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func measure(_ subviews: Subviews) -> (space: CGFloat, sizes: [CGSize]) {
        guard subviews.count >= 2 else { return (0, []) }
        let space = max(subviews[0].sizeThatFits(.unspecified).width - subviews[1].sizeThatFits(.unspecified).width, 0)
        let sizes = subviews.dropFirst(2).map { $0.sizeThatFits(.unspecified) }
        return (space, sizes)
    }
}

#Preview("HLWholeWordText") {
    HLPage {
        HLCard {
            HLWholeWordText("Niedrigdosis-CT der Lunge im Rahmen der Früherkennung", font: .hlHeadline)
        }
        HLCard {
            HLWholeWordText("Jetzt synchronisieren", font: .hlHeadline, alignment: .center)
                .frame(maxWidth: .infinity)
        }
    }
    .dynamicTypeSize(.accessibility5)
}
