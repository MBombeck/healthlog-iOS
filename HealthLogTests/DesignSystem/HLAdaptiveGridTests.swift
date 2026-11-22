@testable import HealthLog
import SwiftUI
import Testing

/// Columns of a tile grid from the width it is given, tiles never over
/// 320 pt, an even count where the fold of the open Duo asks for it.
@MainActor
@Suite("HLAdaptiveGrid")
struct HLAdaptiveGridTests {
    /// The two-column tile grid of the phone: two flexible columns at every
    /// phone width, 136 pt on 320 and 196 pt on 440 with the 16 pt card gap.
    static let phoneMinimum: CGFloat = 132

    @Test(
        "large tiles: one column on the phone, two on the Duo and in a form sheet, three on the iPad",
        arguments: zip(AdaptiveWidths.all, [1, 1, 1, 2, 2, 2, 3, 3, 3, 3])
    )
    func largeTiles(window: CGFloat, expected: Int) {
        let width = AdaptiveWidths.content(window)
        #expect(HLAdaptiveGrid.columns(width: width, minimum: 240, maximum: 3, spacing: HLLayout.tileGap) == expected)
    }

    @Test(
        "the phone's two columns stay two at every width",
        arguments: AdaptiveWidths.all
    )
    func phoneTiles(window: CGFloat) {
        let width = AdaptiveWidths.content(window)
        #expect(HLAdaptiveGrid.columns(width: width, minimum: Self.phoneMinimum, maximum: 2, spacing: HLLayout.tileGap) == 2)
    }

    @Test("on 440 the phone's tiles fill the row with the card gap between them")
    func phoneTileWidth() {
        let width = AdaptiveWidths.content(440)
        #expect(HLAdaptiveGrid.tileWidth(width: width, columns: 2) == (width - HLLayout.tileGap) / 2)
        #expect(HLAdaptiveGrid.tileWidth(width: width, columns: 2) == 196)
        #expect(HLAdaptiveGrid.rowWidth(width: width, columns: 2) == width)
    }

    @Test("without the gaps the rule is floor(width / minimum), capped and at least one")
    func plainRule() {
        #expect(HLAdaptiveGrid.columns(width: 720, minimum: 240, maximum: 3) == 3)
        #expect(HLAdaptiveGrid.columns(width: 719, minimum: 240, maximum: 3) == 2)
        #expect(HLAdaptiveGrid.columns(width: 2000, minimum: 240, maximum: 3) == 3)
        #expect(HLAdaptiveGrid.columns(width: 100, minimum: 240, maximum: 3) == 1)
        #expect(HLAdaptiveGrid.columns(width: 0, minimum: 240, maximum: 3) == 1)
        #expect(HLAdaptiveGrid.columns(width: 720, minimum: 240, maximum: 1) == 1)
    }

    @Test("with the gaps no tile falls under the minimum", arguments: AdaptiveWidths.all)
    func minimumHolds(window: CGFloat) {
        let width = AdaptiveWidths.content(window)
        for minimum: CGFloat in [Self.phoneMinimum, 160, 240] {
            let columns = HLAdaptiveGrid.columns(width: width, minimum: minimum, maximum: 4, spacing: HLLayout.tileGap)
            guard columns > 1 else { continue }
            let even = (width - HLLayout.tileGap * CGFloat(columns - 1)) / CGFloat(columns)
            #expect(even >= minimum)
        }
    }

    @Test("even columns: an odd count drops by one, one column stays one")
    func evenColumns() {
        let open = AdaptiveWidths.content(1032)
        #expect(HLAdaptiveGrid.columns(width: open, minimum: 240, maximum: 3, spacing: HLLayout.tileGap, even: true) == 2)
        #expect(HLAdaptiveGrid.columns(width: open, minimum: 160, maximum: 4, spacing: HLLayout.tileGap, even: true) == 4)
        #expect(HLAdaptiveGrid.columns(width: 300, minimum: 240, maximum: 3, even: true) == 1)
    }

    @Test("a tile never grows over the tile maximum; the row then stands narrower", arguments: AdaptiveWidths.all)
    func tileCap(window: CGFloat) {
        let width = AdaptiveWidths.content(window)
        let columns = HLAdaptiveGrid.columns(width: width, minimum: 240, maximum: 3, spacing: HLLayout.tileGap)
        let tile = HLAdaptiveGrid.tileWidth(width: width, columns: columns)
        #expect(tile <= HLLayout.tileMaxWidth)
        #expect(HLAdaptiveGrid.rowWidth(width: width, columns: columns) <= width + 0.001)
    }

    @Test("the grid lays its tiles in rows of equal height, a short last row included")
    func rendersRows() throws {
        let grid = HLAdaptiveGrid(minimumTileWidth: Self.phoneMinimum, maximumColumns: 2) {
            Color.gray.frame(height: 50)
            Color.gray.frame(height: 70)
            Color.gray.frame(height: 30)
        }
        let size = try DesignContractMeasure.size(of: grid, width: AdaptiveWidths.content(440))
        #expect(size.height == 70 + HLLayout.tileGap + 30)
    }

    @Test("a capped row stands centred")
    func cappedRowCentred() throws {
        let width = AdaptiveWidths.content(1376)
        let grid = HLAdaptiveGrid(minimumTileWidth: 240, maximumColumns: 3) {
            DesignContractMeasure.marker.frame(height: 20)
            Color.gray.frame(height: 20)
            Color.gray.frame(height: 20)
        }
        let found = try DesignContractMeasure.markerFrame(in: grid, width: width)
        let row = HLAdaptiveGrid.rowWidth(width: width, columns: 3)
        #expect(abs(found.frame.minX - (width - row) / 2) <= 1)
        #expect(abs(found.frame.width - HLLayout.tileMaxWidth) <= 1)
    }

    @Test("the statistic row keeps all cells side by side on the phone and breaks only where they would squeeze")
    func statGrid() {
        #expect(HLStatGrid.columns(for: 4, at: .large, width: nil) == 4)
        #expect(HLStatGrid.columns(for: 4, at: .large, width: 256) == 4, "a card on a 320 pt window")
        #expect(HLStatGrid.columns(for: 4, at: .large, width: 376) == 4, "a card on the phone")
        #expect(HLStatGrid.columns(for: 4, at: .large, width: 150) == 2)
        #expect(HLStatGrid.columns(for: 4, at: .accessibility2, width: 1000) == 2)
        #expect(HLStatGrid.columns(for: 1, at: .large, width: 40) == 1)
    }
}

extension HLAdaptiveGridTests {
    @Test("the statistic row's gap and cell minimum are layout tokens")
    func statTokens() {
        #expect(HLLayout.statCellGap == HLSpace.sm)
        #expect(HLLayout.statCellMinWidth == 52)
    }
}
