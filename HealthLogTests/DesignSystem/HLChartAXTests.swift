import Accessibility
@testable import HealthLog
import Testing

/// Verifies the descriptors produced by `HLChartAX` are well-formed and
/// suitable for SwiftUI's `accessibilityChartDescriptor` modifier.
///
/// The contract: every public builder must produce a descriptor with a
/// non-empty title + summary, a populated x/y axis, and at least one series.
/// VoiceOver will otherwise announce "(empty)" tick labels — a regression
/// already caught once in v0.2.1 (`docs/design-audit.md` Befund C3).
@Suite("HLChartAX builders")
struct HLChartAXTests {
    @Test("singleSeries — produces a complete descriptor")
    func singleSeriesComplete() {
        let points: [(x: Double, y: Double, xLabel: String)] = [
            (0, 3, "Mo"),
            (1, 4, "Di"),
            (2, 5, "Mi")
        ]
        let d = HLChartAX.singleSeries(
            title: "Stimmung",
            summary: "Ø 4",
            xAxisTitle: "Tag",
            yAxisTitle: "Wert",
            seriesName: "Stimmung",
            points: points,
            yValueLabel: { "\(Int($0))" }
        )

        #expect(d.title == "Stimmung")
        #expect(d.summary == "Ø 4")
        #expect(d.series.count == 1)
        #expect(d.series.first?.dataPoints.count == 3)
        // X-axis must speak the supplied label, not "(empty)" — the core
        // regression guard from v0.2.1 Befund C3.
        if let numericX = d.xAxis as? AXNumericDataAxisDescriptor {
            #expect(numericX.valueDescriptionProvider(0) == "Mo")
            #expect(numericX.valueDescriptionProvider(2) == "Mi")
        } else {
            Issue.record("x-axis should be a numeric axis descriptor")
        }
    }

    @Test("singleSeries — degenerate (all-equal y) does not panic")
    func singleSeriesDegenerateY() {
        // All-equal y would give upper == lower, which `AXNumericDataAxisDescriptor`
        // rejects. The builder must widen the range.
        let points: [(x: Double, y: Double, xLabel: String)] = [
            (0, 3, "Mo"),
            (1, 3, "Di"),
            (2, 3, "Mi")
        ]
        let d = HLChartAX.singleSeries(
            title: "x",
            summary: "x",
            xAxisTitle: "x",
            yAxisTitle: "x",
            seriesName: "x",
            points: points
        )
        // No assertion on internals — just that construction succeeded.
        #expect(d.series.first?.dataPoints.count == 3)
    }

    @Test("singleSeries — empty points")
    func singleSeriesEmpty() {
        let d = HLChartAX.singleSeries(
            title: "x",
            summary: "x",
            xAxisTitle: "x",
            yAxisTitle: "x",
            seriesName: "x",
            points: []
        )
        #expect(d.series.first?.dataPoints.isEmpty == true)
    }

    @Test("multiSeries — emits one descriptor per input series")
    func multiSeriesFanOut() {
        let series: [(name: String, points: [(x: Double, y: Double)], continuous: Bool)] = [
            ("Sys", [(0, 120), (1, 125)], true),
            ("Dia", [(0, 80), (1, 82)], true)
        ]
        let d = HLChartAX.multiSeries(
            title: "BP",
            summary: "x",
            xAxisTitle: "x",
            yAxisTitle: "mmHg",
            xRange: 0 ... 1,
            yRange: 60 ... 140,
            series: series
        )
        #expect(d.series.count == 2)
        #expect(d.series.first?.name == "Sys")
        #expect(d.series.last?.name == "Dia")
    }
}
