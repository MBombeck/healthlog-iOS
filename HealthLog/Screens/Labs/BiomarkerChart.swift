import Accessibility
import Charts
import SwiftUI

/// v0154 LR-REDO — the biomarker value-over-time chart on the detail page.
///
/// A biomarker-specific Swift Charts variant because the Insights `ChartCard` /
/// `MetricChartContent` are bound to `MetricKind` + `SeriesPoint` +
/// `MeasurementsRepository`. This plots the per-biomarker `(takenAt, value)`
/// series directly and overlays a NEUTRAL reference band from the server-resolved
/// `referenceLow`/`referenceHigh` — mirroring the web's shaded `ReferenceArea` +
/// dashed bound lines. The band is a calm graphite rail, NEVER a red/green alarm
/// (the verdict stays the server `rangeStatus`, surfaced elsewhere on the page).
///
/// Reuses the chart tokens (`HLChartTints`, `HLChartGrid`, `HLChartStyle`) so the
/// render matches every other chart in the app. Under two points it self-
/// suppresses to a calm "need more data" card, exactly like the Insights chart.
struct BiomarkerChart: View {
    let unit: String
    let referenceLow: Double?
    let referenceHigh: Double?

    /// `(date, value)` points, chronological. Resolved at init so the chart body
    /// is source-agnostic — see the two initialisers below.
    private let points: [DatedValue]

    /// Lab-result entry point (the original). Rows without a numeric `value` —
    /// absent readings AND qualitative ones (item 1.5) — are dropped; plotting
    /// them would draw a phantom dip-to-zero that corrupts the trend.
    init(rows: [LabResultDTO], unit: String, referenceLow: Double?, referenceHigh: Double?) {
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        points = BiomarkerSeries.valueBearing(rows)
            .compactMap { row -> DatedValue? in
                guard let date = LabsDateFormat.parse(row.takenAt), let value = row.value else { return nil }
                return DatedValue(id: row.id, date: date, value: value)
            }
            .sorted { $0.date < $1.date }
    }

    /// Generic entry point — plot any identified `(date, value)` series with an
    /// optional neutral band. Added so the CUSTOM-METRIC detail page reuses this
    /// exact chart (same tokens, same band styling, same VoiceOver descriptor)
    /// instead of forking a near-identical second chart. `referenceLow` /
    /// `referenceHigh` carry the custom metric's TARGET band there; the render
    /// contract is unchanged — a calm graphite rail, never a red/green verdict.
    init(
        points: [DatedValue],
        unit: String,
        referenceLow: Double?,
        referenceHigh: Double?
    ) {
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.points = points.sorted { $0.date < $1.date }
    }

    var body: some View {
        if points.count >= 2 {
            HLCard {
                chart
                    .frame(height: HLChartStyle.heightDetail)
            }
        } else {
            HLCard {
                VStack(spacing: HLSpace.xs) {
                    Image(systemName: "chart.xyaxis.line")
                        // Audit-01 H4 — empty-glyph on the canonical hero scale
                        // (was a raw `.title2`), matching `HLEmptyState`.
                        .font(.hlIcon(HLIconSize.hero, weight: .medium))
                        .foregroundStyle(HLText.tertiary)
                    Text("biomarker.detail.chart.needMore")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLSpace.md)
            }
        }
    }

    private var chart: some View {
        Chart {
            // Neutral reference band — a calm graphite rectangle spanning
            // [low, high]. Only drawn when BOTH bounds exist; a single bound
            // draws just its dashed rule below.
            if let low = referenceLow, let high = referenceHigh {
                RectangleMark(
                    yStart: .value("biomarker.detail.chart.referenceLow", low),
                    yEnd: .value("biomarker.detail.chart.referenceHigh", high)
                )
                .foregroundStyle(HLChartTints.seriesLow.opacity(0.18))
            }
            if let low = referenceLow {
                RuleMark(y: .value("biomarker.detail.chart.referenceLow", low))
                    .foregroundStyle(HLChartTints.seriesLow)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.lineWidth,
                        dash: HLChartGrid.thresholdDash
                    ))
            }
            if let high = referenceHigh {
                RuleMark(y: .value("biomarker.detail.chart.referenceHigh", high))
                    .foregroundStyle(HLChartTints.seriesLow)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.lineWidth,
                        dash: HLChartGrid.thresholdDash
                    ))
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("biomarker.detail.chart.date", point.date),
                    y: .value("biomarker.detail.chart.value", point.value)
                )
                .foregroundStyle(HLChartTints.series)
                .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineJoin: .round))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("biomarker.detail.chart.date", point.date),
                    y: .value("biomarker.detail.chart.value", point.value)
                )
                .foregroundStyle(HLChartTints.series)
                .symbolSize(40)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                    .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisTick()
                    .foregroundStyle(HLText.tertiary)
                AxisValueLabel()
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {
            if !unit.isEmpty {
                Text(verbatim: unit)
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.day().month(.abbreviated))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                    AxisGridLine()
                        .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                }
            }
        }
        .accessibilityLabel(Text("biomarker.detail.chart.a11y"))
        .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor))
    }

    /// `AXChartDescriptor` for VoiceOver — x = the reading date (spoken as a
    /// medium date), y = the value (spoken with its unit). Built off the same
    /// `points` series the chart plots (absent rows already filtered) so the
    /// spoken trend matches the drawn one. Mirrors the `HLChartAX.singleSeries`
    /// path every other line chart uses.
    private var chartDescriptor: AXChartDescriptor {
        let pts = points
        let triples = pts.enumerated().map { idx, point in
            (x: Double(idx), y: point.value, xLabel: point.date.formatted(.dateTime.day().month(.abbreviated).year()))
        }
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        return HLChartAX.singleSeries(
            title: String(localized: "biomarker.detail.chart.a11y"),
            summary: "",
            xAxisTitle: String(localized: "biomarker.detail.chart.ax.dateAxis"),
            yAxisTitle: unit.isEmpty ? String(localized: "biomarker.detail.chart.ax.valueAxis") : unit,
            seriesName: String(localized: "biomarker.detail.chart.ax.series"),
            points: triples,
            yValueLabel: { value in
                let formatted = value.formatted(.number.precision(.fractionLength(0 ... 2)))
                return "\(formatted)\(unitSuffix)"
            }
        )
    }

    /// A parsed `(date, value)` chart point keyed by the source row id.
    /// `internal` (was `private`) so a non-lab caller — the custom-metric detail
    /// page — can build the series for the generic `points:` initialiser without
    /// an untyped 3-tuple.
    struct DatedValue: Identifiable, Equatable {
        let id: String
        let date: Date
        let value: Double
    }
}
