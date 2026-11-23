import CoreGraphics
@testable import HealthLog
import Testing

/// The score tiles of the Insights overview: two on every phone as before,
/// never three (the folded Duo stays at two, no tile over the fold of the
/// open Duo), four where the readable width holds them, five in one row
/// where five scores fit, one at an accessibility size.
@MainActor
@Suite("Insights score grid")
struct InsightsScoreGridTests {
    nonisolated static let widths: [CGFloat] = [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376]

    private static func grid(accessibility: Bool) -> HLTileGrid {
        HLTileGrid(
            minimumTileWidth: HLTileGrid.ringTileMinimumWidth,
            maximumColumns: InsightsTileGrid.columnCount(
                standard: InsightsScoreCardsBlock.maximumTileColumns,
                isAccessibilitySize: accessibility
            ),
            evenColumns: true,
            avoidsLoneTile: true
        )
    }

    /// The overview is a readable page: its content is the window less the
    /// margins, at most the readable width.
    private static func content(_ window: CGFloat) -> CGFloat {
        min(window - 2 * HLLayout.pageMargin, HLLayout.readableWidth)
    }

    @Test(
        "columns per window width",
        arguments: zip(widths, [2, 2, 2, 2, 4, 4, 4, 4, 4, 4])
    )
    func columns(window: CGFloat, expected: Int) {
        let grid = Self.grid(accessibility: false)
        let count = grid.columns(width: Self.content(window))
        #expect(count == expected)
        #expect(count.isMultiple(of: 2))
        #expect(grid.tileWidth(width: Self.content(window)) <= HLLayout.tileMaxWidth)
    }

    @Test("on the phone (440) two tiles of 196 pt, split by the 16 pt tile gap")
    func phoneUnchanged() {
        let grid = Self.grid(accessibility: false)
        #expect(grid.columns(width: 408) == 2)
        #expect(grid.tileWidth(width: 408) == (408 - HLLayout.tileGap) / 2)
        #expect(grid.tileWidth(width: 408) == 196)
        #expect(grid.rowWidth(width: 408) == 408)
    }

    @Test("one full-width column at an accessibility size", arguments: widths)
    func accessibilityOneColumn(window: CGFloat) {
        let grid = Self.grid(accessibility: true)
        #expect(grid.columns(width: Self.content(window)) == 1)
        #expect(grid.tileWidth(width: Self.content(window)) == Self.content(window))
    }

    @Test(
        "five scores: one row where the page holds five, else the even count as before",
        arguments: zip(widths, [2, 2, 2, 2, 4, 5, 5, 5, 5, 5])
    )
    func fiveScores(window: CGFloat, expected: Int) {
        let grid = Self.grid(accessibility: false)
        let content = Self.content(window)
        let count = grid.columns(width: content, itemCount: 5)
        #expect(count == expected)
        #expect(grid.tileWidth(width: content, count: count) >= HLTileGrid.ringTileMinimumWidth)
    }

    @Test("no lone tile where a count avoids it; even counts stay as they were")
    func noLoneTile() {
        let grid = Self.grid(accessibility: false)
        // Four and six tiles on the 13-inch page keep four columns.
        #expect(grid.columns(width: 720, itemCount: 4) == 4)
        #expect(grid.columns(width: 720, itemCount: 6) == 4)
        // The open Duo (637 pt) cannot hold five in a row; it keeps its even
        // four rather than a tile over the fold.
        #expect(grid.columns(width: 637, itemCount: 5) == 4)
        #expect(HLTileGrid.leavesLoneTile(itemCount: 5, columns: 4))
        #expect(!HLTileGrid.leavesLoneTile(itemCount: 5, columns: 5))
        #expect(!HLTileGrid.leavesLoneTile(itemCount: 1, columns: 2))
        // A grid that does not ask keeps the plain count.
        let plain = HLTileGrid(minimumTileWidth: 132, maximumColumns: 5, evenColumns: true)
        #expect(plain.columns(width: 720, itemCount: 5) == 4)
    }

    @Test(
        "three scores keep the columns they had: even, never a row of three on a phone or the open Duo",
        arguments: zip(widths, [2, 2, 2, 2, 4, 4, 4, 4, 4, 4])
    )
    func threeScores(window: CGFloat, expected: Int) {
        let grid = Self.grid(accessibility: false)
        let content = Self.content(window)
        #expect(grid.columns(width: content, itemCount: 3) == expected)
        #expect(grid.columns(width: content, itemCount: 3) == grid.columns(width: content))
    }
}
