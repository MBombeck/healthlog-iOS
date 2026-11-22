import Foundation

/// **The mood trend, derived once (D5 #9).**
///
/// `MoodTrendChart` used to derive its daily series in a computed property
/// that its body read four to five times per evaluation (body, chart, moving
/// average, mean, audio graph), and the moving average filtered the whole
/// series for every point, O(n²). Every scrub frame paid all of it. The series
/// is now built here once, off the main actor inside `MoodAnalysisCache`, and
/// handed to the chart as an immutable value.
struct MoodTrendSeries: Sendable, Equatable {
    struct Point: Identifiable, Hashable, Sendable {
        let date: Date
        let score: Double
        var id: Date {
            date
        }
    }

    /// One point per local day, ascending: the day's average score.
    let daily: [Point]
    /// The 7-day trailing moving average (see ``movingAverage(_:calendar:)``).
    let movingAverage: [Point]
    /// The mean of the daily averages; `nil` without a day.
    let mean: Double?

    static let empty = MoodTrendSeries(entries: [], calendar: .current)

    init(entries: [MoodTrendChart.Entry], calendar: Calendar) {
        var buckets: [Date: (sum: Int, count: Int)] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            buckets[day, default: (0, 0)].sum += entry.score
            buckets[day, default: (0, 0)].count += 1
        }
        let daily = buckets
            .map { Point(date: $0.key, score: Double($0.value.sum) / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
        self.daily = daily
        movingAverage = Self.movingAverage(daily.map { (date: $0.date, score: $0.score) }, calendar: calendar)
            .map { Point(date: $0.date, score: $0.score) }
        mean = daily.isEmpty ? nil : daily.map(\.score).reduce(0, +) / Double(daily.count)
    }

    /// 7-day trailing moving average over an ascending daily series. Emitted
    /// only where ≥ 4 of the 7 days up to and including the anchor carry data
    /// (else a gap, never fabricated; DESIGN-B §2.1). `[]` for < 7 points.
    ///
    /// One pass with a sliding window: the series is ascending, so the window
    /// of each anchor starts at or after the previous anchor's start.
    nonisolated static func movingAverage(
        _ series: [(date: Date, score: Double)],
        calendar: Calendar
    ) -> [(date: Date, score: Double)] {
        guard series.count >= 7 else { return [] }
        var result: [(date: Date, score: Double)] = []
        result.reserveCapacity(series.count)
        var lower = 0
        var sum = 0.0
        for (index, point) in series.enumerated() {
            sum += point.score
            guard let windowStart = calendar.date(byAdding: .day, value: -6, to: point.date) else { continue }
            while series[lower].date < windowStart {
                sum -= series[lower].score
                lower += 1
            }
            let count = index - lower + 1
            guard count >= 4 else { continue }
            result.append((point.date, sum / Double(count)))
        }
        return result
    }
}
