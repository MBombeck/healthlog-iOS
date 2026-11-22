import SwiftUI

/// A grid of tiles whose column count comes from the width it is given.
///
/// As many columns as tiles of `minimumTileWidth` fit, at most
/// `maximumColumns`. A tile never grows over ``HLLayout/tileMaxWidth``; where
/// the columns would be wider, the row stands centred at the narrower width,
/// so a ring and its value never float in empty space. Every tile of a row
/// takes the height of the tallest.
///
/// `evenColumns` keeps the count even where the grid spans the whole window
/// of an open Duo without a sidebar, so no tile lies across the fold.
///
/// It decides in the layout pass from the width it is offered: nothing is
/// stored, nothing jumps after the first frame, and it measures its own
/// container, never the window.
public struct HLAdaptiveGrid: Layout {
    public let minimumTileWidth: CGFloat
    public let maximumColumns: Int
    public let evenColumns: Bool
    public let spacing: CGFloat

    public init(
        minimumTileWidth: CGFloat,
        maximumColumns: Int,
        evenColumns: Bool = false,
        spacing: CGFloat = HLLayout.tileGap
    ) {
        self.minimumTileWidth = minimumTileWidth
        self.maximumColumns = maximumColumns
        self.evenColumns = evenColumns
        self.spacing = spacing
    }

    // MARK: - Pure layout functions

    /// The number of columns at `width`: `min(maximum, floor(width / minimum))`,
    /// never under one. With a `spacing` the gaps count too, so no tile falls
    /// under `minimum`. With `even` an odd count above one drops by one.
    public static func columns(
        width: CGFloat,
        minimum: CGFloat,
        maximum: Int,
        spacing: CGFloat = 0,
        even: Bool = false
    ) -> Int {
        guard maximum > 1, minimum > 0, width.isFinite, width > 0 else { return 1 }
        let fitting = Int(((width + spacing) / (minimum + spacing)).rounded(.down))
        let count = max(1, min(maximum, fitting))
        if even, count > 1, !count.isMultiple(of: 2) { return count - 1 }
        return count
    }

    /// The most columns a grid may use at a text size: `maximum` at the
    /// standard sizes, two from the first accessibility size on, one from
    /// AX3 on, so a value and its unit never shrink into an ellipsis.
    public static func maximumColumns(_ maximum: Int, at size: DynamicTypeSize) -> Int {
        if size >= .accessibility3 { return min(maximum, 1) }
        if size.isAccessibilitySize { return min(maximum, 2) }
        return maximum
    }

    /// The width of one tile in `columns` columns at `width`, capped at
    /// ``HLLayout/tileMaxWidth``.
    public static func tileWidth(width: CGFloat, columns: Int, spacing: CGFloat = HLLayout.tileGap) -> CGFloat {
        let count = CGFloat(max(1, columns))
        let even = (width - spacing * (count - 1)) / count
        return max(0, min(HLLayout.tileMaxWidth, even))
    }

    /// How wide the row of `columns` tiles stands at `width`.
    public static func rowWidth(width: CGFloat, columns: Int, spacing: CGFloat = HLLayout.tileGap) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return tileWidth(width: width, columns: columns, spacing: spacing) * count + spacing * (count - 1)
    }

    // MARK: - Layout

    public struct Cache {
        var width: CGFloat = -1
        var columns = 1
        var tileWidth: CGFloat = 0
        var rowHeights: [CGFloat] = []
    }

    public func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    public func updateCache(_ cache: inout Cache, subviews _: Subviews) {
        cache = Cache()
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews: subviews)
        measure(width: width, subviews: subviews, cache: &cache)
        let rows = CGFloat(cache.rowHeights.count)
        let height = cache.rowHeights.reduce(0, +) + spacing * max(0, rows - 1)
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: bounds.width, subviews: subviews, cache: &cache)
        let row = Self.rowWidth(width: bounds.width, columns: cache.columns, spacing: spacing)
        let leading = bounds.minX + max(0, (bounds.width - row) / 2)
        var y = bounds.minY
        for (rowIndex, height) in cache.rowHeights.enumerated() {
            let first = rowIndex * cache.columns
            for column in 0 ..< cache.columns where first + column < subviews.count {
                let x = leading + CGFloat(column) * (cache.tileWidth + spacing)
                subviews[first + column].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cache.tileWidth, height: height)
                )
            }
            y += height + spacing
        }
    }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        let columns = Self.columns(
            width: width,
            minimum: minimumTileWidth,
            maximum: maximumColumns,
            spacing: spacing,
            even: evenColumns
        )
        let tile = Self.tileWidth(width: width, columns: columns, spacing: spacing)
        let proposal = ProposedViewSize(width: tile, height: nil)
        cache.width = width
        cache.columns = columns
        cache.tileWidth = tile
        cache.rowHeights = stride(from: 0, to: subviews.count, by: columns).map { first in
            subviews[first ..< min(first + columns, subviews.count)]
                .map { $0.sizeThatFits(proposal).height }
                .max() ?? 0
        }
    }

    /// Without a proposed width the grid asks for the maximum columns of
    /// minimum tiles.
    private func idealWidth(subviews _: Subviews) -> CGFloat {
        let count = CGFloat(max(1, maximumColumns))
        return minimumTileWidth * count + spacing * (count - 1)
    }
}

#Preview("HLAdaptiveGrid") {
    ScrollView {
        HLAdaptiveGrid(minimumTileWidth: 160, maximumColumns: 3) {
            ForEach(0 ..< 7, id: \.self) { index in
                HLCard {
                    Text(verbatim: "Tile \(index + 1)")
                        .font(.hlBody)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(HLLayout.pageInsets)
    }
    .background(HLSurface.primary)
}
