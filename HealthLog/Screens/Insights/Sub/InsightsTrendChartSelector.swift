import Foundation

/// v0.11 W-C — pure selection layer for the inline Insights "Trends" mini-chart
/// row, the iOS twin of the web `selectTrendCharts`
/// (`src/lib/insights/trend-chart-select.ts`).
///
/// The row charts exactly the metrics the daily briefing flags, in the
/// briefing's own priority order, deduped on their `MetricKind` slot and capped
/// at three. When the briefing is absent, carries no findings, or every finding
/// maps to a chart-less metric (compliance / GLP-1 plateau), it falls back to
/// the legacy BP / weight / mood triple so the row never paints empty.
///
/// Kept free of SwiftUI so the selection contract is unit-testable in isolation
/// and the renderer stays a thin consumer (mirrors the web module split).
enum InsightsTrendChartSelector {
    /// Max charts the row renders — three keeps the 3-up grid honest and bounds
    /// the chart cost on the overview (web `DEFAULT_TREND_CHART_CAP`).
    static let cap = 3

    /// The legacy fallback triple. Mirrors web `DEFAULT_TREND_METRICS`.
    static let defaultMetrics: [MetricKind] = [.bloodPressure, .weight, .pulse]

    /// Briefing `sourceMetric` snapshot key → charted `MetricKind`. Keys absent
    /// from the table (`mood`, `compliance`, `glp1_plateau`, anything unknown)
    /// have no single plottable measurement series in this row, so a finding on
    /// them is skipped and the next finding fills the slot — matching the web
    /// `TREND_CHART_CONFIG` `null` entries. (The web charts mood via a bespoke
    /// `<MoodChart>`; iOS has no measurement-series mood sparkline, so mood
    /// stays on its dedicated `MoodSummaryCard` / analysis.)
    private static let sourceMetricMap: [String: MetricKind] = [
        "bp": .bloodPressure,
        "weight": .weight,
        "pulse": .pulse,
        "resting_hr": .restingHeartRate,
        "hrv": .hrv,
        "sleep": .sleep,
        "steps": .steps,
        "active_energy": .activeEnergy,
        "flights": .flightsClimbed,
        "distance": .distanceWalkingRunning,
        "vo2_max": .vo2Max,
        "body_temp": .bodyTemperature
    ]

    /// Map a briefing finding's `sourceMetric` snapshot key onto a charted
    /// `MetricKind`. Returns `nil` for keys without a plottable series.
    static func metricKind(forSourceMetric key: String) -> MetricKind? {
        sourceMetricMap[key]
    }

    /// Resolve the trend-row chart set from the briefing's key findings.
    ///
    /// - Parameters:
    ///   - keyFindings: the briefing's findings, already in priority order
    ///     (most load-bearing first). Pass `[]` when no briefing is available.
    ///   - cap: max charts (defaults to ``cap``).
    /// - Returns: deduped, capped `MetricKind` list; the default triple when the
    ///   briefing yields nothing chartable.
    static func select(
        keyFindings: [KeyFinding],
        cap: Int = InsightsTrendChartSelector.cap
    ) -> [MetricKind] {
        let bounded = max(1, cap)
        let fromBriefing = resolve(
            keyFindings.map(\.sourceMetric),
            cap: bounded
        )
        if !fromBriefing.isEmpty { return fromBriefing }
        return resolve(defaultMetrics.map(\.briefingSourceKey), cap: bounded)
    }

    private static func resolve(_ keys: [String], cap: Int) -> [MetricKind] {
        var seen: Set<MetricKind> = []
        var out: [MetricKind] = []
        for key in keys {
            if out.count >= cap { break }
            guard let kind = metricKind(forSourceMetric: key) else { continue }
            if seen.contains(kind) { continue }
            seen.insert(kind)
            out.append(kind)
        }
        return out
    }
}

private extension MetricKind {
    /// The briefing `sourceMetric` key that maps back to this kind — used only
    /// to feed the fallback triple through the same `metricKind(forSourceMetric:)`
    /// resolver so the default path and the briefing path share one mapping.
    var briefingSourceKey: String {
        switch self {
        case .bloodPressure: "bp"
        case .weight: "weight"
        case .pulse: "pulse"
        default: rawValue
        }
    }
}
