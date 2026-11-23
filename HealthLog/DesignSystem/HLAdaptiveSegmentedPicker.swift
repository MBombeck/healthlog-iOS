import SwiftUI

/// **A segmented picker that becomes a menu before it truncates.**
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
    private let values: [Selection]?
    private let content: Content

    /// - Parameters:
    ///   - labels: the segment labels, in order, for measuring.
    ///   - values: the tags of the segments in the same order. With them the
    ///     menu form draws its own label, which wraps in full at the largest
    ///     sizes; without them the system's one-line menu label stands.
    init(
        _ title: LocalizedStringKey,
        selection: Binding<Selection>,
        labels: [LocalizedStringKey],
        values: [Selection]? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.labels = labels
        self.values = values
        self.content = content()
    }

    /// The label of the chosen value, when the values are known.
    static func selectedLabel(_ selection: Selection, labels: [LocalizedStringKey], values: [Selection]?) -> LocalizedStringKey? {
        guard let values, values.count == labels.count, let index = values.firstIndex(of: selection) else { return nil }
        return labels[index]
    }

    /// How far the menu's label may shrink to stay on its line.
    static var menuMinimumScale: CGFloat {
        0.6
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
            menu
        }
    }

    /// The system draws a menu picker's label in a one-line button: at the
    /// largest sizes a wrapped "Diese / Woche" was cut at top and bottom.
    /// With the values known the label is drawn here and wraps in full.
    @ViewBuilder
    private var menu: some View {
        if let chosen = Self.selectedLabel(selection, labels: labels, values: values) {
            Menu {
                Picker(title, selection: $selection) { content }
                    .pickerStyle(.inline)
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Text(chosen)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.hlFootnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(HLText.primary)
                .frame(minHeight: HLHitTarget.minimum)
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(chosen))
        } else {
            Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
                .lineLimit(1)
                .minimumScaleFactor(Self.menuMinimumScale)
                .layoutPriority(1)
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
