import Accessibility
import Charts
import SwiftUI

/// The day-curve chart itself: one local day's mean pulse over a 0…1440
/// minute-of-day axis (web `intraday-pulse-chart.tsx:248-347`).
///
/// **The honesty rule lives here.** The series is split into contiguous runs
/// (``IntradayPulseMath/runs(_:bucketMinutes:)``) and each run is its own
/// `LineMark` series, so a stretch with no trustworthy reading stays BLANK
/// instead of getting a straight line drawn across it. A run of one bucket is
/// a `PointMark` — a lone reading is a dot, never a segment.
///
/// **The baseline is a reference, not data.** It renders as a dashed `RuleMark`
/// with a label and only when the payload carries a real provenance
/// (`drawableBaseline`). The tension window is a soft tinted `RectangleMark`
/// behind the curve — a descriptive marker, never a verdict.
///
/// Static by construction: no draw-on animation, so Reduce Motion has nothing
/// to suppress.
struct IntradayPulseChartView: View {
    let day: IntradayPulseDTO

    /// Y padding around the data, mirroring the web `dataMin - 10 … dataMax + 10`.
    private static let yPadding: Double = 10
    private static let chartHeight: CGFloat = 180

    private var runs: [[IntradayPulseDTO.Bucket]] {
        IntradayPulseMath.runs(day.series, bucketMinutes: day.bucketMinutes)
    }

    /// The Y domain: the data's own span padded, widened to include the
    /// baseline so the reference line can never fall outside the plot.
    private var yDomain: ClosedRange<Double> {
        let means = day.series.map(\.mean)
        let lows = day.series.compactMap(\.min) + means
        let highs = day.series.compactMap(\.max) + means
        var low = lows.min() ?? 40
        var high = highs.max() ?? 120
        if let baseline = day.drawableBaseline {
            low = Swift.min(low, baseline)
            high = Swift.max(high, baseline)
        }
        let lower = low - Self.yPadding
        let upper = high + Self.yPadding
        return lower ... Swift.max(upper, lower + 1)
    }

    var body: some View {
        Chart {
            tensionMark
            baselineMark
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                envelope(for: run, series: index)
                if run.count == 1, let only = run.first {
                    PointMark(
                        x: .value("Minute", only.startMinute),
                        y: .value("bpm", only.mean)
                    )
                    .symbolSize(24)
                    .foregroundStyle(HLChartTints.series)
                } else {
                    ForEach(run) { bucket in
                        LineMark(
                            x: .value("Minute", bucket.startMinute),
                            y: .value("bpm", bucket.mean),
                            series: .value("Run", index)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round))
                        .foregroundStyle(HLChartTints.series)
                    }
                }
            }
        }
        .chartXScale(domain: 0 ... 1440)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: IntradayPulseMath.axisTicks) { value in
                AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel {
                    if let minute = value.as(Int.self) {
                        Text(verbatim: IntradayPulseMath.minuteLabel(minute))
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel {
                    if let bpm = value.as(Double.self) {
                        Text(verbatim: "\(Int(bpm.rounded()))")
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
        .frame(height: Self.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("insights.intraday.title"))
        .accessibilityValue(Text(accessibilitySummary))
        .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor))
    }

    // MARK: - Marks

    /// The min/max envelope for one run, when EVERY bucket in it carries a
    /// spread. A partially-known band would imply a narrowing the data does not
    /// support, so it is all-or-nothing per run.
    @ChartContentBuilder
    private func envelope(for run: [IntradayPulseDTO.Bucket], series: Int) -> some ChartContent {
        if run.count > 1, run.allSatisfy({ $0.min != nil && $0.max != nil }) {
            ForEach(run) { bucket in
                AreaMark(
                    x: .value("Minute", bucket.startMinute),
                    yStart: .value("Low", bucket.min ?? bucket.mean),
                    yEnd: .value("High", bucket.max ?? bucket.mean),
                    series: .value("Envelope", series)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(HLChartTints.seriesLow.opacity(0.25))
            }
        }
    }

    /// The personal resting reference — dashed, labelled, and only ever drawn
    /// for a baseline the server vouched for.
    @ChartContentBuilder
    private var baselineMark: some ChartContent {
        if let baseline = day.drawableBaseline {
            RuleMark(y: .value("Baseline", baseline))
                .lineStyle(StrokeStyle(
                    lineWidth: HLChartGrid.thresholdWidth,
                    dash: HLChartGrid.thresholdDash
                ))
                .foregroundStyle(HLText.secondary.opacity(0.7))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("insights.intraday.baseline")
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                }
        }
    }

    /// The elevated-at-rest window as a soft tinted band BEHIND the curve.
    /// Descriptive only — see ``IntradayPulseDTO/tension``.
    @ChartContentBuilder
    private var tensionMark: some ChartContent {
        if let tension = day.tension {
            RectangleMark(
                xStart: .value("Start", tension.startMinute),
                xEnd: .value("End", tension.endMinute)
            )
            .foregroundStyle(HLColor.statusWarn.opacity(0.14))
        }
    }

    // MARK: - Accessibility

    /// `AXChartDescriptor` for VoiceOver's audio graph — x = the bucket's wall
    /// clock (spoken as `HH:mm`, never re-derived from the device clock), y =
    /// the bucket mean in bpm. Built off `day.series` so the spoken curve is the
    /// drawn curve; the buckets stay in ascending minute order, so a gap simply
    /// jumps in the spoken time labels rather than implying a reading. Mirrors
    /// the `HLChartAX.singleSeries` path every other line chart uses.
    private var chartDescriptor: AXChartDescriptor {
        let ordered = day.series.sorted { $0.startMinute < $1.startMinute }
        let triples = ordered.enumerated().map { idx, bucket in
            (
                x: Double(idx),
                y: bucket.mean,
                xLabel: IntradayPulseMath.minuteLabel(bucket.startMinute)
            )
        }
        return HLChartAX.singleSeries(
            title: String(localized: "insights.intraday.title"),
            summary: accessibilitySummary,
            xAxisTitle: String(localized: "Time"),
            yAxisTitle: String(localized: "Pulse"),
            seriesName: String(localized: "Pulse"),
            points: triples,
            yValueLabel: { value in "\(Int(value.rounded())) bpm" }
        )
    }

    /// A spoken summary of the shape: how many readings, over which wall-clock
    /// span, and the resting reference when one exists. Deliberately factual —
    /// VoiceOver gets the same non-diagnostic framing the caption carries.
    private var accessibilitySummary: String {
        guard let first = day.series.min(by: { $0.startMinute < $1.startMinute }),
              let last = day.series.max(by: { $0.startMinute < $1.startMinute }) else
        {
            return String(localized: "insights.intraday.empty")
        }
        let readings = day.series.reduce(0) { $0 + $1.count }
        let span = "\(IntradayPulseMath.minuteLabel(first.startMinute))–"
            + IntradayPulseMath.minuteLabel(last.startMinute + day.bucketMinutes)
        if let baseline = day.drawableBaseline {
            return String(
                localized: "insights.intraday.a11y.withBaseline \(readings) \(span) \(Int(baseline.rounded()))"
            )
        }
        return String(localized: "insights.intraday.a11y \(readings) \(span)")
    }
}
