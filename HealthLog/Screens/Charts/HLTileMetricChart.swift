import Charts
import SwiftUI

/// Task #36 — the **compact tile chart** that shares the SAME chart mechanic +
/// visual language as the Insights metric chart (`ChartCard` /
/// `MetricChartContent`), shrunk to fit a Dashboard / Insights tile.
///
/// **Why this exists.** Before this primitive the tile mini-chart was a generic
/// `HLSparkline` — a single index-based `LineMark` tinted `HLText.tertiary`
/// (faded grey), with NO per-metric vocabulary. The Insights page meanwhile
/// renders through `MetricChartContent.marks(for:points:emphasisTint:)`: a
/// per-metric mark builder (BP dual-line + thresholds, glucose points +
/// hypo/hyper rules, weight + personal baseline, …) stroked in `inkGraphite`
/// (`HLChartTints.series`). So the same metric read as two different charts on
/// the two surfaces — the operator's "Home-Charts = Insights-Charts" gap.
///
/// **What this unifies.** This view routes the tile mini-chart through the SAME
/// `MetricChartContent.marks(...)` engine, with the SAME `HLColor.inkGraphite`
/// emphasis tint the Insights `ChartCard` passes (`InsightsMetricScreen`'s
/// `emphasisTint: HLColor.inkGraphite`). The per-metric line style, point /
/// threshold treatment, catmull-rom interpolation and series colour are
/// therefore byte-identical to Insights — one chart engine, two sizes.
///
/// **What is deliberately stripped at tile scale** (and carried by the
/// deep-link to the full Insights page instead):
/// - axes / gridlines (`.chartXAxis(.hidden)` / `.chartYAxis(.hidden)`) — axis
///   chrome dominates a 36 pt strip,
/// - the scrub `chartXSelection` + floating callout,
/// - horizontal pan + `HLFloatingPeriodControl`.
///
/// Tapping the tile deep-links to `InsightsMetricScreen`, which hosts the full
/// period control + scrub + axes — so the tile preview's STYLE + data-window
/// semantics match Insights, and the full mechanic is one tap away.
///
/// **Cost.** Dashboard renders many tiles at once, so this stays cheap: a
/// one-shot `Chart` with no always-running animation (it inherits only the
/// values-change `.hlAnimation` from the caller's row), no scroll
/// infrastructure, no selection state. Same render budget class as the
/// `HLSparkline` it replaces.
///
/// **Data.** Tiles carry a projected `[Double]` series (index-based; see
/// `MetricSeriesProjection`), not the dated `[SeriesPoint]` the detail loads.
/// This view synthesises evenly-spaced `SeriesPoint`s from the values so the
/// shared mark builder can consume them; the x-domain is decorative at tile
/// scale (axis hidden), so synthetic even spacing reads identically to the
/// real timeline once the axis chrome is gone. The threshold `RuleMark`s the
/// per-metric builders emit (BP 140/60, glucose 70/180, …) sit at fixed
/// y-values, so they remain meaningful against the real data domain.
struct HLTileMetricChart: View {
    /// The metric whose `MetricChartContent` vocabulary drives the marks.
    let kind: MetricKind
    /// The projected series (index-based). Fewer than 2 points collapses to the
    /// shared `HLSparkline` hairline so an empty tile reads the same as before.
    let values: [Double]

    var body: some View {
        if values.count < 2 {
            // Single-point / empty: reuse the canonical hairline so the
            // empty-vs-chart threshold stays identical to the legacy path.
            HLSparkline(values: values, tint: HLChartTints.series)
        } else {
            Chart {
                MetricChartContent.marks(
                    for: kind,
                    points: syntheticPoints,
                    // v0.14.7 A1 (recurring 4×): pin the tile line to the SAME
                    // quiet grey as the medication-compliance sparkline
                    // (`HLSparkline(tint: HLText.tertiary)` in
                    // ComplianceRingCard) so every Home tile reads identically.
                    // `HLColor.inkGraphite` was the bug: its colorset inverts to
                    // a near-WHITE (#EBEBF5) in dark mode, so the operator (dark
                    // mode) saw white, thick metric lines next to the grey
                    // compliance line. `HLText.tertiary` is mid-grey in BOTH
                    // appearances → the tiles finally match.
                    emphasisTint: HLText.tertiary,
                    // v0.14.1 §1: the Dashboard tile shows ONLY the trend line.
                    // Suppress the per-metric clinical threshold rules (BP 140/60,
                    // glucose 70/180, …) + the weight personal-baseline rule —
                    // those red/grey target/ideal lines read as noise at 36 pt.
                    // The Insights detail chart keeps them (default `true`).
                    includeThresholds: false,
                    // v0.14.3 §A1 (FW-HOME): drop the per-measurement dot symbols
                    // (BP sys/dia circles, glucose PointMarks) — they read "too
                    // intense" at tile scale. Line-only on every Home tile.
                    showsPoints: false,
                    // v0.14.7 A1: every Home-tile line shares the unified
                    // `HLChartGrid.tileSeriesWidth` token, which is now pinned to
                    // the EXACT stroke the medication-compliance `HLSparkline`
                    // uses (`HLChartStyle.lineWidth` = 2.0) — see Tokens.swift. The
                    // old 2.1 read "thicker" than the compliance line; matched
                    // width + the `HLText.tertiary` tint above ⇒ identical tiles.
                    seriesLineWidth: HLChartGrid.tileSeriesWidth
                )
            }
            // Tile scale: axis chrome would dominate the 36 pt strip — hidden
            // here, carried by the Insights deep-link. The y-domain is snugged
            // so the line never grazes the tile edge (mirrors HLSparkline).
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            // Task #36 a11y parity: the tile routes through the SAME
            // `MetricChartContent` engine as the Insights detail chart, so it
            // wires the SAME `AXChartDescriptor` (`ChartsAccessibility`) the
            // detail uses — VoiceOver users get a real audio-graph + rotor over
            // the series, not just a flat label. The descriptor's own
            // title/summary carry the trend, so the chart is fully accessible
            // at tile scale (mirrors `ChartDetailComponents` / `TrendsOverlayCard`).
            .accessibilityChartDescriptor(
                ChartDescriptor(descriptor: ChartsAccessibility.makeDescriptor(
                    for: MeasurementSeries(
                        kind: kind,
                        points: syntheticPoints,
                        stats: Self.statsFor(syntheticPoints)
                    ),
                    kind: kind
                ))
            )
        }
    }

    /// Evenly-spaced `SeriesPoint`s from the projected values. The x dates are
    /// decorative (axis hidden) — only their ascending order matters so the
    /// LineMark draws left→right. BP's secondary (diastolic) is unavailable in
    /// the `[Double]` projection (it carries systolic-only per
    /// `MetricSeriesProjection.systolicOnly`), so `secondary` stays `nil` and
    /// the BP builder renders its single systolic line — same ink, same
    /// thresholds as the detail's systolic series.
    private var syntheticPoints: [SeriesPoint] {
        let now = Date()
        let count = values.count
        return values.enumerated().map { index, value in
            // Space points one day apart ending "now" so the order is stable
            // and ascending; the exact instants are never shown.
            let offset = TimeInterval(-(count - 1 - index) * 86400)
            return SeriesPoint(
                id: "tile-\(kind.rawValue)-\(index)",
                at: now.addingTimeInterval(offset),
                value: value,
                secondary: nil
            )
        }
    }

    /// Snug y-domain with 5 % padding — identical contract to `HLSparkline`
    /// so the compact chart frames the same way the legacy sparkline did.
    private var yDomain: ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0 ... 1 }
        guard hi > lo else { return lo - 0.5 ... lo + 0.5 }
        let pad = (hi - lo) * 0.05
        return (lo - pad) ... (hi + pad)
    }

    /// Pure stats for the synthetic points so `ChartsAccessibility.makeDescriptor`
    /// can build the y-axis range + summary. Mirrors `ChartDetailScreen.statsFor`
    /// (same mean / min / max / stdDev contract); duplicated here so the tile
    /// chart stays self-contained and doesn't pull in the detail screen type.
    private static func statsFor(_ points: [SeriesPoint]) -> SeriesStats {
        let xs = points.map(\.value)
        guard !xs.isEmpty else {
            return SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
        }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return SeriesStats(
            mean: mean,
            min: xs.min() ?? 0,
            max: xs.max() ?? 0,
            stdDev: variance.squareRoot(),
            count: xs.count
        )
    }
}

#Preview("HLTileMetricChart — per-metric vocabulary") {
    VStack(spacing: HLSpace.lg) {
        // Weight — single line + personal-baseline rule (when ≥5 points).
        HLTileMetricChart(kind: .weight, values: [73.6, 73.4, 73.0, 72.9, 72.7, 72.5, 72.4])
            .frame(height: 36)
        // Glucose — line + points over hypo/hyper threshold rules.
        HLTileMetricChart(kind: .glucose, values: [95, 110, 130, 105, 90, 120, 100])
            .frame(height: 36)
        // BP — systolic line over the 140/60 threshold rules.
        HLTileMetricChart(kind: .bloodPressure, values: [120, 122, 124, 125, 122, 123, 124])
            .frame(height: 36)
        // Single value → hairline (same as HLSparkline).
        HLTileMetricChart(kind: .spo2, values: [97])
            .frame(height: 36)
    }
    .padding()
    .background(HLSurface.primary)
}
