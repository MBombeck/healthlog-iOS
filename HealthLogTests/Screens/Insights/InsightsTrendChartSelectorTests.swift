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

    @Test("#115 1.3 — the sentence follows the server's 30-day slope, not the first and last point")
    func annotationFollowsServerSlope() {
        // Server says the 30-day regression is DOWN; the two visible points
        // happen to rise (a spike on the last day). Before #115 the card read
        // "trended up" off those two points.
        let rising = InsightsTrendsRow.annotation(serverSlope: TrendSlope(slope: 0.2, direction: .up), title: "Weight")
        let falling = InsightsTrendsRow.annotation(serverSlope: TrendSlope(slope: -0.2, direction: .down), title: "Weight")
        let steady = InsightsTrendsRow.annotation(serverSlope: TrendSlope(slope: 0.001, direction: .stable), title: "Weight")
        #expect(rising != falling)
        #expect(steady != rising)
        #expect(steady != falling)
        #expect(rising?.contains("Weight") == true)

        let rows = [scalar(.weight, 70, daysAgo: 10), scalar(.weight, 80, daysAgo: 1)]
        let digest = ComprehensiveDigest(summaries: [
            "WEIGHT": MetricSummary(slope30: TrendSlope(slope: -0.1, direction: .down, confidence: 0.6))
        ])
        let chart = InsightsTrendsRow.chart(for: .weight, in: rows, digest: digest)
        let expected = InsightsTrendsRow.annotation(
            serverSlope: TrendSlope(slope: -0.1, direction: .down),
            title: chart?.title ?? ""
        )
        #expect(chart?.annotation == expected)
        #expect(chart?.annotation != InsightsTrendsRow.annotation(
            serverSlope: TrendSlope(slope: 0.1, direction: .up),
            title: chart?.title ?? ""
        ))
    }

    @Test("#115 1.3 — no server slope (standalone, offline, unknown word) → no sentence at all")
    func annotationWithoutServerSlope() {
        #expect(InsightsTrendsRow.annotation(serverSlope: nil, title: "Weight") == nil)
        #expect(InsightsTrendsRow.annotation(serverSlope: TrendSlope(direction: .unknown), title: "Weight") == nil)
        let rows = [scalar(.weight, 70, daysAgo: 10), scalar(.weight, 80, daysAgo: 1)]
        #expect(InsightsTrendsRow.chart(for: .weight, in: rows)?.annotation == nil)
    }
}
