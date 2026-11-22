@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    @Test("a reference line's label stands at the trailing end, off the curve's start")
    func referenceLabelTrailing() {
        #expect(HLReferenceLineStyle.labelAlignment == .trailing)
        let band = HLChartReferenceLines.band(lower: 60, upper: 100, label: "Zielbereich", unit: "bpm")
        #expect(band.lines.filter { !$0.label.isEmpty }.map(\.kind) == [.upper], "one label, on the upper edge")
    }
}

extension E2BuildingBlockTests {
    @Test("the unit of the value axis stands level above it, never turned")
    func axisUnitLevel() {
        #expect(HLChartAxis.unitPlacement == .aboveAxis)
    }

    @Test("the scrub callout is an opaque surface, no glass over the plot")
    func scrubCalloutOpaque() {
        #expect(HLScrubCallout.surface == HLColor.surfaceElevated)
    }
}
