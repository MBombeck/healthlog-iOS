import Charts
import SwiftUI

/// Mood trend line chart. Owned by W-Mood (v0.10.0) — upgraded from the bare
/// daily-score line to the three-layer DESIGN-B §2 anatomy:
///   1. mean baseline `RuleMark` (where you usually sit),
///   2. raw daily-average line (the wobble — demoted, 40% ink, 1 pt),
///   3. 7-day moving average (the signal — promoted, 100% ink, 2 pt).
/// Y-axis labels are mood glyphs (`MoodCopy.scoreLabel`), not bare digits.
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

    let entries: [Entry]

    /// v0.11 — canonical scrub-to-read (AUDIT-FINAL §H1). Touch the line to read
    /// the daily-average mood at that day, identical to every other chart.
    @State private var selectedDate: Date?

    /// Daily-average series (one point per local day, ascending). The spine.
    private var daily: [DailyPoint] {
        var buckets: [Date: [Int]] = [:]
        let calendar = Calendar.current
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            buckets[day, default: []].append(entry.score)
        }
        return buckets
            .map { day, scores in
                DailyPoint(date: day, score: Double(scores.reduce(0, +)) / Double(scores.count))
            }
            .sorted { $0.date < $1.date }
    }

    /// 7-day trailing moving average — only emitted where ≥ 4 of the prior 7
    /// days carry data (else a gap, never fabricated; DESIGN-B §2.1).
    private var movingAverage: [DailyPoint] {
        let tuples = daily.map { (date: $0.date, score: $0.score) }
        return Self.movingAverage(tuples, calendar: Calendar.current).map {
            DailyPoint(date: $0.date, score: $0.score)
        }
    }

    /// Pure 7-day MA over an ascending daily series, exposed for unit-testing.
    /// Returns `[]` for < 7 points and skips any anchor with < 4 windowed days.
    nonisolated static func movingAverage(
        _ series: [(date: Date, score: Double)],
        calendar: Calendar
    ) -> [(date: Date, score: Double)] {
        guard series.count >= 7 else { return [] }
        return series.compactMap { point in
            guard let windowStart = calendar.date(byAdding: .day, value: -6, to: point.date) else { return nil }
            let window = series.filter { $0.date >= windowStart && $0.date <= point.date }
            guard window.count >= 4 else { return nil }
            let avg = window.map(\.score).reduce(0, +) / Double(window.count)
            return (point.date, avg)
        }
    }

    private var overallMean: Double? {
        let series = daily
        guard !series.isEmpty else { return nil }
        return series.map(\.score).reduce(0, +) / Double(series.count)
    }

    var body: some View {
        if daily.count < 2 {
            sparseState
        } else {
            chart
                .frame(height: 160)
                .accessibilityChartDescriptor(self)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let series = daily
        let ma = movingAverage
        return Chart {
            // 1. Mean baseline.
            if let mean = overallMean {
                RuleMark(y: .value(String(localized: "Average"), mean))
                    .foregroundStyle(HLText.tertiary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: HLChartGrid.thresholdDash))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Ø \(mean.formatted(.number.precision(.fractionLength(1))))")
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.tertiary)
                    }
            }
            // Faint scale anchors at 1/3/5.
            ForEach([1, 3, 5], id: \.self) { level in
                RuleMark(y: .value(String(localized: "Scale"), level))
                    .foregroundStyle(HLText.tertiary.opacity(0.2))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: HLChartGrid.thresholdDash))
            }
            // 2. Raw daily line — the wobble (demoted).
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
            // 3. 7-day moving average — the signal (promoted).
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
            // 4. Canonical scrub overlay — dashed rule + callout at the nearest
            // daily point.
            HLChartScrubber.marks(
                selectedDate: selectedDate,
                in: series,
                date: \.date,
                value: \.score
            ) { point in
                HLScrubCallout(
                    title: point.date.formatted(.dateTime.weekday(.abbreviated).day().month()),
                    value: MoodCopy.scoreLabel(Int(point.score.rounded())),
                    unit: point.score.formatted(.number.precision(.fractionLength(1)))
                )
            }
        }
        .hlChartScrub($selectedDate) { date in
            guard let nearest = HLChartScrubber.nearest(to: date, in: series, date: \.date) else { return nil }
            return String(
                localized: "\(nearest.date.formatted(.dateTime.day().month())): \(MoodCopy.scoreLabel(Int(nearest.score.rounded())))"
            )
        }
        .chartYScale(domain: 0.5 ... 5.5)
        .chartYAxis {
            AxisMarks(values: [1, 3, 5]) { value in
                AxisValueLabel {
                    if let level = value.as(Int.self) {
                        Text(MoodCopy.scoreLabel(level))
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel()
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // "≥7 days for the smoothed line" footnote in the 2–6-point state.
            if ma.isEmpty, series.count >= 2 {
                Text("Moving average from 7 days of data")
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.tertiary)
            }
        }
    }

    // MARK: - Sparse state (< 2 daily points)

    private var sparseState: some View {
        // Audit-01 C1/H4 — the canonical `HLEmptyState` lockup (the bespoke
        // stack used a raw `.system(.title)` glyph + its own type recipe).
        HLEmptyState(
            icon: "chart.line.uptrend.xyaxis",
            title: "Not enough entries for a trend",
            message: "Log a few more moods to see your line."
        )
        .frame(height: 160)
    }

    private struct DailyPoint: Identifiable, Hashable {
        let date: Date
        let score: Double
        var id: Date {
            date
        }
    }
}

extension MoodTrendChart: AXChartDescriptorRepresentable {
    nonisolated func makeChartDescriptor() -> AXChartDescriptor {
        let series = entries
            .reduce(into: [Date: [Int]]()) { acc, e in
                let day = Calendar.current.startOfDay(for: e.date)
                acc[day, default: []].append(e.score)
            }
            .map { (day: $0.key, score: Double($0.value.reduce(0, +)) / Double($0.value.count)) }
            .sorted { $0.day < $1.day }

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
