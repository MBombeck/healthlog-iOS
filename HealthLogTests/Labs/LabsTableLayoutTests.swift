import CoreGraphics
@testable import HealthLog
import SwiftUI
import Testing

/// Which columns the labs list shows at a window width and text size, and
/// where the marker's history stands beside it. Pure rules, checked at every
/// window width of the program.
@Suite("Labs table layout")
struct LabsTableLayoutTests {
    typealias Column = LabsTableLayout.Column

    private static let plain: [Column] = []
    private static let table: [Column] = [.marker, .value, .range]

    @Test(
        "columns at the default text size: rows up to the Duo folded and beside the history at 744, a table elsewhere from 520 on",
        arguments: zip(
            AdaptiveWidths.all,
            [plain, plain, plain, table, table, plain, table, table, table, table]
        )
    )
    func columnsAtDefaultSize(window: CGFloat, expected: [Column]) {
        #expect(LabsTableLayout.resolve(width: window, typeSize: .large).columns == expected)
    }

    @Test(
        "the history stands beside the list from 736 on",
        arguments: zip(
            AdaptiveWidths.all,
            [false, false, false, false, false, true, true, true, true, true]
        )
    )
    func detailBesideList(window: CGFloat, expected: Bool) {
        #expect(LabsTableLayout.resolve(width: window, typeSize: .large).layout.isSideBySide == expected)
    }

    @Test("on 320, 440 and 466 the list is the list of rows it was, at every text size below accessibility")
    func compactIsUnchanged() {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        for width: CGFloat in [320, 440, 466] {
            for size in sizes {
                let resolved = LabsTableLayout.resolve(width: width, typeSize: size)
                #expect(resolved.columns.isEmpty, "\(width) at \(size)")
                #expect(resolved.layout.isSideBySide == false)
                #expect(resolved.layout.listWidth == width, "the list keeps the whole width")
            }
        }
    }

    @Test(
        "wherever the table stands the marker name keeps at least 140 pt, at every width and standard size",
        arguments: AdaptiveWidths.all
    )
    func nameKeepsItsRoom(window: CGFloat) {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
            let resolved = LabsTableLayout.resolve(width: window, typeSize: size)
            guard !resolved.columns.isEmpty else { continue }
            let name = LabsTableLayout.nameWidth(listWidth: resolved.layout.listWidth, typeSize: size)
            #expect(name >= LabsTableLayout.nameMinimum, "\(window) at \(size): \(name) pt")
        }
    }

    @Test("beside the history at 744 and 834 the large sizes keep plain rows, because the name would not fit")
    func besideHistoryAtLargeSizes() {
        for window: CGFloat in [744, 834] {
            for size in [DynamicTypeSize.xxLarge, .xxxLarge] {
                let resolved = LabsTableLayout.resolve(width: window, typeSize: size)
                #expect(resolved.layout.isSideBySide, "\(window): the history still stands beside")
                let name = LabsTableLayout.nameWidth(listWidth: resolved.layout.listWidth, typeSize: size)
                #expect(name < LabsTableLayout.nameMinimum, "\(window) at \(size): \(name) pt would be too narrow")
                #expect(resolved.columns.isEmpty, "\(window) at \(size)")
            }
        }
        // 834 at the default size has the room; 744 has not.
        #expect(LabsTableLayout.resolve(width: 834, typeSize: .large).columns == Self.table)
        #expect(LabsTableLayout.resolve(width: 744, typeSize: .large).columns.isEmpty)
    }

    @Test("the columns grow with the text and never shrink below their base")
    func columnWidthsFollowTheText() {
        #expect(LabsTableLayout.valueWidth(.large) == LabsTableLayout.valueBase)
        #expect(LabsTableLayout.rangeWidth(.large) == LabsTableLayout.rangeBase)
        #expect(LabsTableLayout.valueWidth(.xxxLarge) > LabsTableLayout.valueWidth(.xLarge))
        #expect(LabsTableLayout.rangeWidth(.xxxLarge) > LabsTableLayout.rangeWidth(.large))
        #expect(LabsTableLayout.rangeWidth(.xSmall) == LabsTableLayout.rangeBase)
    }

    @Test("from accessibility 1 the rows are two columns (the plain row), the history still stands beside")
    func accessibilityOneAndTwo() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2] {
            let resolved = LabsTableLayout.resolve(width: 1032, typeSize: size)
            #expect(resolved.columns.isEmpty)
            #expect(resolved.layout.isSideBySide)
        }
    }

    @Test("from accessibility 3 one column at every width: no table, no history beside")
    func accessibilityThreeIsOneColumn() {
        for size in [DynamicTypeSize.accessibility3, .accessibility4, .accessibility5] {
            for width in AdaptiveWidths.all {
                let resolved = LabsTableLayout.resolve(width: width, typeSize: size)
                #expect(resolved.columns.isEmpty, "\(width) at \(size)")
                #expect(resolved.layout.isSideBySide == false, "\(width) at \(size)")
            }
        }
    }

    @Test("an unmeasured or empty width gives the plain list")
    func unmeasured() {
        #expect(LabsTableLayout.resolve(width: nil, typeSize: .large).columns.isEmpty)
        #expect(LabsTableLayout.resolve(width: 0, typeSize: .large).columns.isEmpty)
        #expect(LabsTableLayout.resolve(width: nil, typeSize: .large).layout.isSideBySide == false)
    }

    @Test("with nothing to show beside the list (loading, empty) the list keeps the whole width")
    func noDetailAvailable() {
        let layout = HLListDetailLayout.resolve(width: 1032, typeSize: .large, detailAvailable: false)
        #expect(layout.isSideBySide == false)
        #expect(layout.listWidth == 1032)
    }

    @Test("beside the history the list is 400 to 600 wide and the history keeps at least 320", arguments: AdaptiveWidths.all)
    func listWidthBounds(window: CGFloat) {
        guard window >= HLLayout.sideBySideMinimum else { return }
        let primary = HLListDetailLayout.listWidth(in: window)
        #expect(primary >= HLListDetailLayout.listMinimum)
        #expect(primary <= HLListDetailLayout.listMaximum)
        #expect(window - primary - 1 >= 320, "the divider takes a point; the pane keeps a phone's measure")
    }

    @Test("the earlier values leave out the newest reading and the qualitative ones")
    func earlierValues() {
        #expect(LabsTableLayout.earlierValues([1, nil, 3, 4]) == [1, 3])
        #expect(LabsTableLayout.earlierValues([2.1]) == [])
        #expect(LabsTableLayout.earlierValues([]) == [])
    }

    @Test("the reference text reads the bounds with the unit, nothing without a bound")
    func referenceCell() {
        func row(low: Double?, high: Double?) -> LabResultDTO {
            LabResultDTO(
                id: "r", biomarkerId: nil, panel: nil, analyte: "INR", value: 1.3, unit: "mg/L",
                referenceLow: low, referenceHigh: high, takenAt: "2026-10-21T08:00:00Z", source: "MANUAL",
                hasNote: false, rangeStatus: .inRange, createdAt: "", updatedAt: ""
            )
        }
        #expect(LabsTableLayout.referenceText(for: row(low: 0, high: 3))?.contains("mg/L") == true)
        #expect(LabsTableLayout.referenceText(for: row(low: nil, high: 3))?.hasPrefix("≤") == true)
        #expect(LabsTableLayout.referenceText(for: row(low: nil, high: nil)) == nil)
    }
}
