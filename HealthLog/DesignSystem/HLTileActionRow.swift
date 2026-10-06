import SwiftUI

/// **K1 — a row of equal tile actions that stacks when a label would break.**
///
/// The medication card and its Vorsorge twin put two `HLTileActionButton`s side
/// by side at equal widths. H2 photographed what that does when the equal share
/// is narrower than a label: „Übersprun-gen" hyphenated on the iPhone SE and
/// „Ge-nom-men" over three lines at AX-XXL.
///
/// `ViewThatFits` cannot decide this on its own, because the natural width of
/// an `HStack` is the *sum* of its buttons' widths while the buttons are laid
/// out at *equal* shares: „Genommen" + „Übersprungen" fits the SE's card by
/// sum and still breaks the longer label in its half. This layout asks the
/// right question — does the widest label fit its equal share? — and stacks the
/// buttons full-width when it does not. Where it fits (every large device at
/// the default text size), the row is placed exactly as the old `HStack` placed
/// it: equal widths, one spacing between.
struct HLTileActionRow: Layout {
    var spacing: CGFloat = HLSpace.sm

    enum Arrangement: Equatable {
        case row
        case column
    }

    /// Pure: the decision, testable without a view. `idealWidths` are the
    /// subviews' single-line widths; `available` is the proposed width
    /// (`nil` = the caller asks for the ideal size, which is always the row).
    static func arrangement(idealWidths: [CGFloat], spacing: CGFloat, available: CGFloat?) -> Arrangement {
        guard let available, idealWidths.count > 1 else { return .row }
        let count = CGFloat(idealWidths.count)
        let share = (available - spacing * (count - 1)) / count
        let widest = idealWidths.max() ?? 0
        // Half a point of slack: text measurement is fractional, and a label
        // that fits by a rounding error must not flip the arrangement.
        return widest <= share + 0.5 ? .row : .column
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let count = CGFloat(subviews.count)
        guard !subviews.isEmpty else { return .zero }
        switch Self.arrangement(idealWidths: ideals.map(\.width), spacing: spacing, available: proposal.width) {
        case .row:
            let width = proposal.width ?? ((ideals.map(\.width).max() ?? 0) * count + spacing * (count - 1))
            let share = (width - spacing * (count - 1)) / count
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: share, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        case .column:
            let width = proposal.width ?? (ideals.map(\.width).max() ?? 0)
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + spacing * (count - 1))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard !subviews.isEmpty else { return }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let count = CGFloat(subviews.count)
        switch Self.arrangement(idealWidths: ideals, spacing: spacing, available: bounds.width) {
        case .row:
            let share = (bounds.width - spacing * (count - 1)) / count
            let height = bounds.height
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (share + spacing)
                subview.place(
                    at: CGPoint(x: x, y: bounds.midY),
                    anchor: .leading,
                    proposal: ProposedViewSize(width: share, height: height)
                )
            }
        case .column:
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: size.height)
                )
                y += size.height + spacing
            }
        }
    }
}
