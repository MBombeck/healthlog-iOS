@testable import HealthLog
import SwiftUI
import Testing

/// **POLISH-B B3 (1.5, SHOTS F-AX-AXIS).** The date labels under every chart
/// (`ChartDateAxis`, the main metric chart and the lab line too) ran into each
/// other from XXL on; the axis keeps its ticks and grid lines but labels only
/// every other tick there.
@Suite("POLISH-B B3 — the date axis at large text")
struct LargeTextLayoutDecisionTests {
    static let regular: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge]
    static let large: [DynamicTypeSize] = [.xxLarge, .xxxLarge] + accessibility
    static let accessibility: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    @Test("B3: up to XL every tick is labelled")
    func everyLabelAtRegularSizes() {
        for size in Self.regular {
            for index in 0 ..< 5 {
                #expect(ChartDateAxis.showsLabel(index: index, dynamicTypeSize: size), "\(size) tick \(index)")
            }
        }
    }

    @Test("B3: from XXL on no two neighbouring ticks are both labelled, and the first one is")
    func sparseLabelsAtLargeSizes() {
        for size in Self.large {
            #expect(ChartDateAxis.showsLabel(index: 0, dynamicTypeSize: size), "\(size)")
            for index in 0 ..< 4 {
                let both = ChartDateAxis.showsLabel(index: index, dynamicTypeSize: size)
                    && ChartDateAxis.showsLabel(index: index + 1, dynamicTypeSize: size)
                #expect(!both, "\(size) ticks \(index) and \(index + 1)")
            }
        }
    }

    @Test("SHOTS F-REC-1: record cards two a row up to XXXL, one a row at the accessibility sizes")
    func recordColumns() {
        for size in Self.regular + [.xxLarge, .xxxLarge] {
            #expect(PersonalRecordsScreen.gridColumns(size).count == 2, "\(size)")
        }
        for size in Self.accessibility {
            #expect(PersonalRecordsScreen.gridColumns(size).count == 1, "\(size)")
        }
    }
}
