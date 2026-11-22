// swiftlint:disable force_unwrapping

import Foundation
@testable import HealthLog
import Testing

/// Pure locks for the trend chart's 7-day moving-average
/// helper + the period-window filter. No SwiftUI render pass.
@Suite("Mood trend chart helpers")
struct MoodTrendChartTests {
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private static func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: anchor))!
    }

    @Test("moving average needs ≥7 daily points")
    func maRequiresSevenDays() {
        let series = (0 ..< 6).map { (date: Self.day(5 - $0), score: 3.0) }
        #expect(MoodTrendChart.movingAverage(series, calendar: Self.calendar).isEmpty)
    }

    @Test("moving average smooths a flat series to the same value")
    func maFlat() {
        // 10 contiguous flat days → anchors with ≥4 windowed days emit; the
        // first 3 (1/2/3 windowed points) are skipped per the ≥4 rule.
        let series = (0 ..< 10).map { (date: Self.day(9 - $0), score: 4.0) }
        let ma = MoodTrendChart.movingAverage(series, calendar: Self.calendar)
        #expect(ma.count == 7) // days index 3…9 each have ≥4 windowed points
        #expect(ma.allSatisfy { abs($0.score - 4.0) < 0.0001 })
    }

    @Test("moving average skips anchors with <4 windowed days (gaps)")
    func maSkipsSparseWindows() {
        // 10 days total but with a 5-day gap in the middle → some anchors
        // will have < 4 windowed days and must be skipped (no fabrication).
        let present = [0, 1, 2, 9, 10, 11, 12].map { (date: Self.day(12 - $0), score: 3.0) }
        let ma = MoodTrendChart.movingAverage(present.sorted { $0.date < $1.date }, calendar: Self.calendar)
        // The early cluster (days 0,1,2) has only 3 windowed points → skipped.
        // The late cluster (9-12) accrues ≥4 → some emitted.
        #expect(ma.count < present.count)
    }

    /// The O(n²) reference the sliding window replaced (D5 #9).
    private static func naiveMovingAverage(_ series: [(date: Date, score: Double)]) -> [(date: Date, score: Double)] {
        guard series.count >= 7 else { return [] }
        return series.compactMap { point in
            guard let windowStart = calendar.date(byAdding: .day, value: -6, to: point.date) else { return nil }
            let window = series.filter { $0.date >= windowStart && $0.date <= point.date }
            guard window.count >= 4 else { return nil }
            return (point.date, window.map(\.score).reduce(0, +) / Double(window.count))
        }
    }

    @Test("D5 #9: the one-pass moving average equals the per-point window filter, gaps included")
    func slidingWindowMatchesReference() {
        var generator = SystemRandomNumberGenerator()
        // Two years with random gaps of up to five days.
        var series: [(date: Date, score: Double)] = []
        var daysAgo = 730
        while daysAgo >= 0 {
            series.append((Self.day(daysAgo), Double(Int.random(in: 1 ... 5, using: &generator))))
            daysAgo -= Int.random(in: 1 ... 5, using: &generator)
        }
        let fast = MoodTrendChart.movingAverage(series, calendar: Self.calendar)
        let reference = Self.naiveMovingAverage(series)
        #expect(fast.count == reference.count)
        for (a, b) in zip(fast, reference) {
            #expect(a.date == b.date)
            #expect(abs(a.score - b.score) < 1e-9)
        }
    }

    @Test("D5 #9: the trend series is derived once with daily averages, moving average and mean")
    func trendSeriesDerivesOnce() {
        let entries = (0 ..< 10).flatMap { offset -> [MoodTrendChart.Entry] in
            // Two entries a day, 2 and 4: the daily average is 3.
            [
                MoodTrendChart.Entry(date: Self.day(offset).addingTimeInterval(3600), score: 2),
                MoodTrendChart.Entry(date: Self.day(offset).addingTimeInterval(7200), score: 4)
            ]
        }
        let series = MoodTrendSeries(entries: entries, calendar: Self.calendar)
        #expect(series.daily.count == 10)
        #expect(series.daily.allSatisfy { $0.score == 3 })
        #expect(series.movingAverage.count == 7)
        #expect(series.mean == 3)
        #expect(MoodTrendSeries(entries: [], calendar: Self.calendar).mean == nil)
    }

    @Test("period filter keeps only entries within the trailing window")
    func periodFilter() {
        let entries = [
            MoodEntry(id: "a", recordedAt: Self.day(5), score: 3),
            MoodEntry(id: "b", recordedAt: Self.day(40), score: 4),
            MoodEntry(id: "c", recordedAt: Self.day(200), score: 5)
        ]
        let d30 = MoodPeriod.month.filter(entries, now: Self.anchor, calendar: Self.calendar)
        #expect(d30.map(\.id) == ["a"])
        let d90 = MoodPeriod.sixMonths.filter(entries, now: Self.anchor, calendar: Self.calendar)
        #expect(Set(d90.map(\.id)) == ["a", "b"])
        let year = MoodPeriod.year.filter(entries, now: Self.anchor, calendar: Self.calendar)
        #expect(year.count == 3)
    }
}
