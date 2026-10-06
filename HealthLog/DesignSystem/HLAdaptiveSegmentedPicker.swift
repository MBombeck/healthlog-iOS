import SwiftUI

/// **K1 — a segmented picker that becomes a menu before it truncates.**
///
/// H2 photographed the cycle capture sheet with „Keine Änderu…", „Periode
/// gesta…" and „Schmi…" on the iPhone SE, and „Schmier…" even on the large
/// device. A segmented control gives every segment the same width and cuts any
/// label that does not fit its share, and for a choice that is the one thing it
/// must not do: the user can no longer read what they are picking.
///
/// The decision is made on the labels themselves, not on the control's own
/// ideal width: SwiftUI reports a segmented picker's ideal width generously, so
/// a `ViewThatFits` over the bare picker gave up on segments that visibly fit
/// (the period row on the 17 Pro Max). ``SegmentFitProbe`` states the width the
/// control really needs — every segment as wide as the longest label plus the
/// control's inset — and the segmented candidate is used exactly when that
/// fits. Otherwise the same options appear as a menu picker, which shows the
/// full selected label and the full list.
struct HLAdaptiveSegmentedPicker<Selection: Hashable, Content: View>: View {
    private let title: LocalizedStringKey
    @Binding private var selection: Selection
    private let labels: [LocalizedStringKey]
    private let content: Content

    /// - Parameter labels: the segment labels, in order, for measuring only.
    init(
        _ title: LocalizedStringKey,
        selection: Binding<Selection>,
        labels: [LocalizedStringKey],
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.labels = labels
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            SegmentFitProbe {
                ForEach(labels.indices, id: \.self) { index in
                    Text(labels[index])
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .hidden()
                }
                Picker(title, selection: $selection) { content }
                    .pickerStyle(.segmented)
            }
            Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
        }
    }
}

/// The ideal width of a segmented control with equal segments: the widest
/// label plus the segment's inner padding, times the segment count. Its last
/// subview (the real picker) fills whatever width it is given; the label
/// subviews are measured and never shown.
struct SegmentFitProbe: Layout {
    /// Minimum inner padding per side of one segment. Measured on iOS 26.5:
    /// „Periode gestartet" (104 pt at the segment font) sits untruncated in a
    /// 119.7 pt segment; a first value of 6 pt sent the German period row on
    /// the 17 Pro Max to the menu although its segments fit (K1 screenshot).
    static let segmentPadding: CGFloat = 4
    /// The control's own outer inset.
    static let controlInset: CGFloat = 2

    static func requiredWidth(labelWidths: [CGFloat]) -> CGFloat {
        let widest = labelWidths.max() ?? 0
        return CGFloat(labelWidths.count) * (widest + 2 * segmentPadding) + controlInset
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let picker = subviews.last else { return .zero }
        let labelWidths = subviews.dropLast().map { $0.sizeThatFits(.unspecified).width }
        let required = Self.requiredWidth(labelWidths: labelWidths)
        let width = proposal.width.map { max($0, 0) } ?? required
        let height = picker.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        // Asked for its ideal size (ViewThatFits' question), the probe answers
        // with what the segments need, never with less.
        return CGSize(width: proposal.width == nil ? required : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let picker = subviews.last else { return }
        for label in subviews.dropLast() {
            label.place(at: bounds.origin, proposal: .zero)
        }
        picker.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
