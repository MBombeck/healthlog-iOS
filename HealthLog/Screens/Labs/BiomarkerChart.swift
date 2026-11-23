import Accessibility
import Charts
import SwiftUI

/// The biomarker value-over-time chart on the detail page.
///
/// A biomarker-specific Swift Charts variant because the Insights `ChartCard` /
/// `MetricChartContent` are bound to `MetricKind` + `SeriesPoint` +
/// `MeasurementsRepository`. This plots the per-biomarker `(takenAt, value)`
/// series directly and draws the server-resolved `referenceLow`/`referenceHigh`
/// as two dashed edges, like every metric page; never a red/green alarm (the
/// verdict stays the server `rangeStatus`, surfaced elsewhere on the page).
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
                guard let date = LabsDateFormat.readingDate(row.takenAt), let value = row.value else { return nil }
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
        referenceHigh: Double?,
        caption: String? = nil
    ) {
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.caption = caption
        self.points = points.sorted { $0.date < $1.date }
    }

    /// The card's one line under the chart (the custom metric's
    /// "N of M in your target range"). `nil` for none.
    private var caption: String?

    /// The point under the finger while the chart is scrubbed.
    @State private var selectedDate: Date?

    var body: some View {
        if points.count >= 2 {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    chart
                        .frame(height: HLChartStyle.heightRegular)
                    if let caption {
                        Text(verbatim: caption)
                            .hlText(.factLabel)
                    }
                }
            }
        } else {
            HLCard {
                HLEmptyNote("biomarker.detail.chart.needMore")
            }
        }
    }

    /// The reference range as its two edges, never a filled area, as on every
    /// metric page; the verdict stays the server's range status.
    private var chart: some View {
        Chart {
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

            // After the series, so the range's label lies over the curve.
            HLChartReferenceLines.band(lower: referenceLow, upper: referenceHigh, unit: unit)

            HLChartScrubber.marks(selectedDate: selectedDate, in: points, date: \.date, value: \.value) { point in
                HLScrubCallout(
                    title: HLDateFormat.date(point.date),
                    value: HLValueFormat.number(point.value, fractionDigits: 0 ... 2),
                    unit: LabUnit.suffix(unit)
                )
            }
        }
        .hlChartAxes(dates: points.map(\.date), unit: LabUnit.suffix(unit) ?? "")
        .hlChartScrub($selectedDate) { date in
            HLChartScrubber.nearest(to: date, in: points, date: \.date).map {
                "\(HLDateFormat.date($0.date)), \(Self.spokenValue($0.value, unit: unit))"
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
            (x: Double(idx), y: point.value, xLabel: HLDateFormat.date(point.date))
        }
        let chartUnit = unit
        return HLChartAX.singleSeries(
            title: String(localized: "biomarker.detail.chart.a11y"),
            summary: "",
            xAxisTitle: String(localized: "biomarker.detail.chart.ax.dateAxis"),
            yAxisTitle: Self.valueAxisTitle(unit: chartUnit),
            seriesName: String(localized: "biomarker.detail.chart.ax.series"),
            points: triples,
            yValueLabel: { Self.spokenValue($0, unit: chartUnit) }
        )
    }

    /// The VoiceOver name of the value axis: the unit, or a generic "Value"
    /// when there is none to say (empty or the unity "1", #160).
    nonisolated static func valueAxisTitle(unit: String) -> String {
        LabUnit.suffix(unit) ?? String(localized: "biomarker.detail.chart.ax.valueAxis")
    }

    /// One plotted value as VoiceOver speaks it, with its unit when it has one.
    nonisolated static func spokenValue(_ value: Double, unit: String) -> String {
        LabUnit.appending(unit, to: HLValueFormat.number(value, fractionDigits: 0 ... 2))
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
