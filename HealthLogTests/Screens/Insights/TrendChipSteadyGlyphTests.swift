@testable import HealthLog
import Testing

/// A steady trend must not draw a glyph that reads as a sign in front of a
/// value: the vitals tile showed oxygen saturation as „−95 %“.
@Suite("Trend chip — steady trend draws no glyph")
struct TrendChipSteadyGlyphTests {
    @Test("flat and unknown draw nothing, up and down draw arrows")
    func glyphs() {
        #expect(TrendChip.symbolName(for: .flat) == nil)
        #expect(TrendChip.symbolName(for: .unknown) == nil)
        #expect(TrendChip.symbolName(for: .up) == "arrow.up")
        #expect(TrendChip.symbolName(for: .down) == "arrow.down")
    }
}
