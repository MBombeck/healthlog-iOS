import Foundation
@testable import HealthLog
import Testing

/// v0.11 W-C — pins the inline-Trends-row selection contract (the iOS twin of
/// the web `selectTrendCharts`): briefing-driven priority order, dedupe, cap 3,
/// chart-less metrics skipped, legacy fallback when nothing chartable.
@Suite("Insights trend-chart selector")
struct InsightsTrendChartSelectorTests {
    private func finding(_ metric: String) -> KeyFinding {
        KeyFinding(
            tone: .watch,
            headline: "h",
            detail: "d",
            sourceWindow: "7d",
            sourceMetric: metric
        )
    }

    @Test("Empty briefing falls back to the legacy bp/weight/pulse triple")
    func emptyFallsBackToTriple() {
        let selected = InsightsTrendChartSelector.select(keyFindings: [])
        #expect(selected == [.bloodPressure, .weight, .pulse])
    }

    @Test("Briefing findings drive the set in priority order")
    func briefingDrivesOrder() {
        let selected = InsightsTrendChartSelector.select(
            keyFindings: [finding("sleep"), finding("hrv"), finding("steps")]
        )
        #expect(selected == [.sleep, .hrv, .steps])
    }

    @Test("Chart-less metrics (mood / compliance / glp1_plateau) are skipped")
    func chartlessMetricsSkipped() {
        let selected = InsightsTrendChartSelector.select(
            keyFindings: [finding("mood"), finding("compliance"), finding("weight")]
        )
        // mood + compliance map to nil → only weight survives, then the row is
        // shorter than the cap (no back-fill from the fallback triple because at
        // least one briefing metric resolved).
        #expect(selected == [.weight])
    }

    @Test("All-chartless briefing falls back to the triple")
    func allChartlessFallsBack() {
        let selected = InsightsTrendChartSelector.select(
            keyFindings: [finding("mood"), finding("compliance"), finding("glp1_plateau")]
        )
        #expect(selected == [.bloodPressure, .weight, .pulse])
    }

    @Test("Duplicate metrics are deduped on their kind slot")
    func dedupe() {
        let selected = InsightsTrendChartSelector.select(
            keyFindings: [finding("bp"), finding("bp"), finding("weight")]
        )
        #expect(selected == [.bloodPressure, .weight])
    }

    @Test("Selection caps at three even with many findings")
    func capAtThree() {
        let selected = InsightsTrendChartSelector.select(
            keyFindings: [
                finding("bp"), finding("weight"), finding("pulse"),
                finding("sleep"), finding("steps")
            ]
        )
        #expect(selected.count == 3)
        #expect(selected == [.bloodPressure, .weight, .pulse])
    }

    @Test("Unknown source keys resolve to nil")
    func unknownKeyNil() {
        #expect(InsightsTrendChartSelector.metricKind(forSourceMetric: "nonsense") == nil)
        #expect(InsightsTrendChartSelector.metricKind(forSourceMetric: "resting_hr") == .restingHeartRate)
    }
}

/// Pins the on-device mini-chart resolution: too-few-points dropping, the
/// annotation direction logic, and BP compound value formatting.
@Suite("Insights trends-row chart resolution")
struct InsightsTrendsRowChartTests {
    private func scalar(_ kind: MetricKind, _ value: Double, daysAgo: Int) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "\(kind.rawValue)-\(daysAgo)-\(value)",
            kind: kind,
            recordedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            value: .scalar(value)
        )
    }

    @Test("A kind with fewer than 2 points in window yields no chart")
    func tooFewPointsDropped() {
        let only = [scalar(.weight, 72, daysAgo: 1)]
        #expect(InsightsTrendsRow.chart(for: .weight, in: only) == nil)
    }

    @Test("A kind with a series resolves to a chart slot with the series oldest→newest")
    func resolvesSeries() throws {
        let rows = [
            scalar(.weight, 74, daysAgo: 10),
            scalar(.weight, 73, daysAgo: 5),
            scalar(.weight, 72, daysAgo: 1)
        ]
        let chart = try #require(InsightsTrendsRow.chart(for: .weight, in: rows))
        #expect(chart.series == [74, 73, 72])
        #expect(chart.kind == .weight)
    }

    @Test("Points older than the 30-day window are excluded")
    func windowExcludesOld() {
        let rows = [
            scalar(.weight, 80, daysAgo: 90),
            scalar(.weight, 72, daysAgo: 1)
        ]
        // Only one in-window point → not enough to chart.
        #expect(InsightsTrendsRow.chart(for: .weight, in: rows) == nil)
    }

    @Test("Annotation distinguishes rising, falling, and steady (locale-agnostic)")
    func annotationDirections() {
        let rising = InsightsTrendsRow.annotation(for: .weight, series: [70, 80], title: "Weight")
        let falling = InsightsTrendsRow.annotation(for: .weight, series: [80, 70], title: "Weight")
        let steady = InsightsTrendsRow.annotation(for: .weight, series: [72.0, 72.1], title: "Weight")
        // The three directions produce three distinct sentences regardless of
        // the resolved locale, and all reference the metric title.
        #expect(rising != falling)
        #expect(steady != rising)
        #expect(steady != falling)
        #expect(rising.contains("Weight"))
        #expect(steady.contains("Weight"))
    }

    @Test("Annotation reports the no-data sentence for a single point")
    func annotationInsufficient() {
        let text = InsightsTrendsRow.annotation(for: .weight, series: [72], title: "Weight")
        let real = InsightsTrendsRow.annotation(for: .weight, series: [70, 80], title: "Weight")
        #expect(text != real)
    }
}
