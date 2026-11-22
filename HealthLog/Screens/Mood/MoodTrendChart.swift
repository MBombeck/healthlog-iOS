import Charts
import SwiftUI

/// Mood trend line chart. Owned by W-Mood — upgraded from the bare
/// daily-score line to the three-layer DESIGN-B §2 anatomy:
///   1. mean baseline, a labelled reference line (where you usually sit),
///   2. raw daily-average line (the wobble — demoted, 40% ink, 1 pt),
///   3. 7-day moving average (the signal — promoted, 100% ink, 2 pt).
/// Y-axis labels are mood words (`MoodCopy.scoreLabel`) on the leading axis
/// every chart uses, not bare digits.
/// Monochrome (`HLText.primary` ramp); color is reserved for signal elsewhere.
///
/// **Back-compat:** the public `init(entries:)` + `Entry` API is unchanged so
/// the Insights consumers (`InsightsAuxChartDetailScreen`) keep working. The
/// chart now collapses same-day entries to a daily average internally and
/// derives MA + mean from that series. The period picker is owned by the host
/// screen (it passes a windowed entry slice); sparse-data honesty states are
/// handled here so a 2-point window never draws a fabricated smoothed curve.
struct MoodTrendChart: View {
    /// `Sendable` since 09-04: the trend series is built off the main actor
    /// inside `MoodAnalysisCache` and handed across as part of an immutable
    /// `MoodAnalysisSnapshot`, so no body evaluation sorts a 10,000-entry
    /// history to draw a chart.
    struct Entry: Identifiable, Hashable, Sendable {
        let id = UUID()
        let date: Date
        let score: Int
    }

    /// The daily series, its moving average and its mean, derived once
    /// (``MoodTrendSeries``): never in `body`, never per scrub frame.
    let series: MoodTrendSeries

    /// Canonical scrub-to-read (AUDIT-FINAL §H1). Touch the line to read
    /// the daily-average mood at that day, identical to every other chart.
    @State private var selectedDate: Date?

    /// The series the analysis cache already derived off the main actor.
    init(series: MoodTrendSeries) {
        self.series = series
    }

    /// Back-compat: derives the series once, here, not in every body pass.
    init(entries: [Entry]) {
        series = MoodTrendSeries(entries: entries, calendar: .current)
    }

    private var daily: [DailyPoint] {
        series.daily
    }

    /// Pure 7-day MA over an ascending daily series, exposed for unit-testing.
    /// Returns `[]` for < 7 points and skips any anchor with < 4 windowed days.
    nonisolated static func movingAverage(
        _ series: [(date: Date, score: Double)],
        calendar: Calendar
    ) -> [(date: Date, score: Double)] {
        MoodTrendSeries.movingAverage(series, calendar: calendar)
    }

    var body: some View {
        if daily.count < 2 {
            sparseState
        } else {
            chart
                .frame(height: HLChartStyle.heightRegular)
                .accessibilityChartDescriptor(self)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let series = daily
        let ma = self.series.movingAverage
        return Chart {
            // 1. Raw daily line — the wobble (demoted).
            ForEach(series) { point in
                LineMark(
                    x: .value(String(localized: "Date"), point.date),
                    y: .value(String(localized: "Mood"), point.score),
                    series: .value("s", "raw")
                )
                .foregroundStyle(HLChartTints.seriesLow)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .interpolationMethod(.monotone)
            }
            // 2. 7-day moving average — the signal (promoted).
            ForEach(ma) { point in
                LineMark(
                    x: .value(String(localized: "Date"), point.date),
                    y: .value(String(localized: "7-day average"), point.score),
                    series: .value("s", "ma")
                )
                .foregroundStyle(HLChartTints.series)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            // 3. Mean baseline: the app's one reference line, labelled on the
            // line itself. Drawn after the lines, so its label stands on its
            // own surface above the curves instead of under them.
            Self.meanLine(self.series.mean)
            // 4. Canonical scrub overlay — dashed rule + callout at the nearest
            // daily point.
            HLChartScrubber.marks(
                selectedDate: selectedDate,
                in: series,
                date: \.date,
                value: \.score
            ) { point in
                HLScrubCallout(
                    title: "\(HLDateFormat.weekday(point.date, abbreviated: true)), \(HLDateFormat.dayMonth(point.date))",
                    value: MoodCopy.scoreLabel(Int(point.score.rounded())),
                    unit: HLValueFormat.number(point.score, fractionDigits: 1 ... 1)
                )
            }
        }
        .hlChartScrub($selectedDate) { date in
            guard let nearest = HLChartScrubber.nearest(to: date, in: series, date: \.date) else { return nil }
            return String(
                localized: "\(HLDateFormat.dayMonth(nearest.date)): \(MoodCopy.scoreLabel(Int(nearest.score.rounded())))"
            )
        }
        .chartYScale(domain: 0.5 ... 5.5)
        // A tick and a word at every other level only: five words do not
        // fit beside a 220 pt plot, and a tick without a word says nothing.
        .hlChartAxes(dates: series.map(\.date), unit: "", ticks: Self.axisTicks, label: Self.axisLabel)
        // No footnote about when the smoothed line starts: below
        // seven days the chart simply draws the daily line.
    }

    /// The levels that carry a word on the value axis.
    nonisolated static let axisTicks: [Double] = [1, 3, 5]

    /// The mood word for an odd level (1, 3, 5), nothing for the levels
    /// between them.
    nonisolated static func axisLabel(_ value: Double) -> String {
        let level = Int(value.rounded())
        guard (1 ... 5).contains(level), !level.isMultiple(of: 2) else { return "" }
        return MoodCopy.scoreLabel(level)
    }

    /// The label on the mean line: "Ø 3,4".
    nonisolated static func meanLabel(_ mean: Double) -> String {
        String(localized: "Ø \(HLValueFormat.number(mean, fractionDigits: 1 ... 1))")
    }

    /// The mean as a labelled reference line; none without a mean.
    static func meanLine(_ mean: Double?) -> HLChartReferenceLines {
        guard let mean else { return .none }
        return HLChartReferenceLines(
            lines: [SeriesReferenceLine(value: mean, kind: .unknown, source: .clinical, label: meanLabel(mean))],
            unit: ""
        )
    }

    // MARK: - Sparse state (< 2 daily points)

    private var sparseState: some View {
        // Audit-01 C1/H4 — the canonical `HLEmptyState` lockup (the bespoke
        // stack used a raw `.system(.title)` glyph + its own type recipe).
        // The title says it; no sentence asks for more entries.
        HLEmptyState(icon: "chart.line.uptrend.xyaxis", title: "Not enough entries for a trend")
            .frame(height: HLChartStyle.heightRegular)
    }

    private typealias DailyPoint = MoodTrendSeries.Point
}

extension MoodTrendChart: AXChartDescriptorRepresentable {
    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        let series = series.daily

        let pts = series.enumerated().map { idx, p in
            AXDataPoint(x: Double(idx), y: p.score, label: MoodCopy.scoreLabel(Int(p.score.rounded())))
        }
        let dateAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Date"),
            range: 0 ... Double(max(series.count - 1, 0)),
            gridlinePositions: []
        ) { _ in "" }
        let scoreAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Mood"),
            range: 1 ... 5,
            gridlinePositions: [1, 3, 5]
        ) { value in MoodCopy.scoreLabel(Int(value.rounded())) }
        let dataSeries = AXDataSeriesDescriptor(
            name: String(localized: "Daily average"),
            isContinuous: true,
            dataPoints: pts
        )
        return AXChartDescriptor(
            title: String(localized: "Mood trend"),
            summary: nil,
            xAxis: dateAxis,
            yAxis: scoreAxis,
            additionalAxes: [],
            series: [dataSeries]
        )
    }
}
