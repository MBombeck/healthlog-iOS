// swiftlint:disable force_unwrapping

import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — pure locks for the trend chart's 7-day moving-average
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

    @Test("period filter keeps only entries within the trailing window")
    func periodFilter() {
        let entries = [
            MoodEntry(id: "a", recordedAt: Self.day(5), score: 3),
            MoodEntry(id: "b", recordedAt: Self.day(40), score: 4),
            MoodEntry(id: "c", recordedAt: Self.day(200), score: 5)
        ]
        let d30 = MoodPeriod.days30.filter(entries, now: Self.anchor, calendar: Self.calendar)
        #expect(d30.map(\.id) == ["a"])
        let d90 = MoodPeriod.days90.filter(entries, now: Self.anchor, calendar: Self.calendar)
        #expect(Set(d90.map(\.id)) == ["a", "b"])
        let year = MoodPeriod.year.filter(entries, now: Self.anchor, calendar: Self.calendar)
        #expect(year.count == 3)
    }
}
