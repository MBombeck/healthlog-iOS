import Foundation

/// Pure, view-free chart math + metric→target mapping shared across the chart
/// surfaces (`InsightsMetricScreen`, `ChartDetailComponents`,
/// `FullscreenChartCover`, the parked legacy `ChartDetailScreen`).
///
/// **Why this exists (FW3-A, v0.14.2 dedup):** these helpers used to live as
/// `nonisolated static` members on the `ChartDetailScreen` *view* type. The
/// v0.11 chart-detail cutover demoted that view to a parked legacy surface
/// (reachable only from Settings → Advanced), yet the live chart screens still
/// called `ChartDetailScreen.logDomain` / `.statsFor` / `.targetType` — a
/// zombie dependency on a view type that is otherwise dead for the main flows.
/// Hoisting the math into this neutral namespace removes that coupling: the
/// live surfaces no longer reference a "Screen" type for pure math, and the
/// parked view simply delegates here too.
enum MetricChartMath {
    /// `MetricKind` → server target-type string. Mirrors the inverse mapping
    /// `InsightsTargetTileGrid.kindForChartDetail` so the tile + the detail
    /// panel agree on which metric owns which target.
    static func targetType(for kind: MetricKind) -> String? {
        switch kind {
        case .weight: "WEIGHT"
        case .pulse: "PULSE"
        case .restingHeartRate: "RESTING_HR"
        case .steps: "ACTIVITY_STEPS"
        case .bodyFat: "BODY_FAT"
        case .sleep: "SLEEP_DURATION"
        case .bloodPressure: "BLOOD_PRESSURE"
        default: nil
        }
    }

    /// Synthesize `SeriesStats` from raw chart points for the fallback
    /// accessibility descriptor on kinds whose server `series` endpoint isn't
    /// wired (walking speed / step length), where `store.displaySeries` is nil
    /// but `store.chartPoints` carries the list-derived points. Series-backed
    /// kinds keep their server-computed stats (this branch isn't taken for them).
    static func statsFor(_ points: [SeriesPoint]) -> SeriesStats {
        let values = points.map(\.value)
        guard !values.isEmpty else {
            return SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return SeriesStats(
            mean: mean,
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            stdDev: variance.squareRoot(),
            count: values.count
        )
    }

    /// Y-domain helper for log-scale rendering. Apple Charts crashes on
    /// non-positive log scales, so we clamp the lower bound to a small positive
    /// epsilon. Padded ±5% to keep the line off the axis edge.
    static func logDomain(for points: [SeriesPoint]) -> ClosedRange<Double> {
        let values = points.flatMap { p -> [Double] in
            if let secondary = p.secondary { return [p.value, secondary] }
            return [p.value]
        }
        let positives = values.filter { $0 > 0 }
        guard let lo = positives.min(), let hi = positives.max(), lo > 0 else {
            return 0.1 ... 1.0 // safe stub so the modifier never sees lo<=0
        }
        let padded = lo * 0.95
        let top = hi * 1.05
        return padded ... (top > padded ? top : padded + 1)
    }
}
