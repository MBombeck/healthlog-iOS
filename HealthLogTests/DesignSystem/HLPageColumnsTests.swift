@testable import HealthLog
import SwiftUI
import Testing

/// Two blocks of a page stand side by side from 736 pt of content width on,
/// one under the other below it.
@MainActor
@Suite("HLPage columns")
struct HLPageColumnsTests {
    @Test(
        "a page of tiles goes side by side from the iPad 11 inch on",
        arguments: zip(
            AdaptiveWidths.all,
            [false, false, false, false, false, false, true, true, true, true]
        )
    )
    func sideBySide(window: CGFloat, expected: Bool) {
        let width = AdaptiveWidths.content(window)
        #expect((HLPageColumns.sideBySide.arrangement(width: width) == .sideBySide) == expected)
    }

    @Test("a single column page and a readable page always stack", arguments: AdaptiveWidths.all)
    func stacks(window: CGFloat) {
        #expect(HLPageColumns.single.arrangement(width: AdaptiveWidths.content(window)) == .stacked)
        let readable = HLPageMargins.contentWidth(width: window)
        #expect(HLPageColumns.sideBySide.arrangement(width: readable) == .stacked)
    }

    @Test("the switch lies exactly at the side-by-side minimum")
    func threshold() {
        #expect(HLPageColumns.sideBySide.arrangement(width: HLLayout.sideBySideMinimum - 1) == .stacked)
        #expect(HLPageColumns.sideBySide.arrangement(width: HLLayout.sideBySideMinimum) == .sideBySide)
        #expect(HLPageColumns.columnWidth(width: HLLayout.sideBySideMinimum) == 360)
    }

    @Test("stacked on the phone, the two blocks measure what one stack of both measures")
    func phoneMatchesStack() throws {
        let columns = HLPageColumnsContent(columns: .sideBySide, primary: block(height: 120), secondary: block(height: 80))
        let stack = VStack(spacing: HLLayout.cardGap) {
            block(height: 120)
            block(height: 80)
        }
        let width = AdaptiveWidths.content(440)
        let measured = try DesignContractMeasure.size(of: columns, width: width)
        let reference = try DesignContractMeasure.size(of: stack, width: width)
        #expect(measured == reference)
        #expect(measured.height == 216)
    }

    @Test("side by side the page is as high as its taller block")
    func sideBySideHeight() throws {
        let columns = HLPageColumnsContent(columns: .sideBySide, primary: block(height: 120), secondary: block(height: 80))
        let measured = try DesignContractMeasure.size(of: columns, width: AdaptiveWidths.content(1032))
        #expect(measured.height == 120)
    }

    @Test("the primary block stands leading, the secondary one a card gap to its right")
    func placement() throws {
        let width = AdaptiveWidths.content(1032)
        let marked = HLPageColumnsContent(
            columns: .sideBySide,
            primary: block(height: 40),
            secondary: DesignContractMeasure.marker.frame(height: 40)
        )
        let found = try DesignContractMeasure.markerFrame(in: marked, width: width)
        let column = HLPageColumns.columnWidth(width: width)
        #expect(abs(found.frame.minX - (column + HLLayout.cardGap)) <= 1)
        #expect(abs(found.frame.width - column) <= 1)
    }

    private func block(height: CGFloat) -> some View {
        Color.gray.frame(height: height)
    }
}
