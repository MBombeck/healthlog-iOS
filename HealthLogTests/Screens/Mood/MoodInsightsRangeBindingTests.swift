// swiftlint:disable force_unwrapping

import Foundation
@testable import HealthLog
import Testing

/// v0.14.4 E1 + E3 — locks that the Insights Mood page's pixel grid and its
/// bottom "Show all measurements" drill-down are both driven by the SAME page
/// range (`MoodPeriod`), the single source of truth, instead of a duplicate
/// selector. Pure helpers, no render pass.
@Suite("Insights mood — page-range single source of truth")
struct MoodInsightsRangeBindingTests {
    private static var fixedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    private static func entry(daysAgo: Int) -> MoodEntry {
        let cal = fixedCalendar
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        let stamp = cal.date(byAdding: .hour, value: 12, to: day)!
        return MoodEntry(id: UUID().uuidString, recordedAt: stamp, score: 3)
    }

    // MARK: - E1: the grid window follows the page range

    @Test("the pixel grid sizes its compact window to the page range, not a fixed 12 weeks")
    func gridWindowFollowsRange() {
        // 30d → 5 weeks (ceil 30/7), 90d → 13 weeks (ceil 90/7).
        #expect(MoodHeatmapSection.compactWeeks(forPeriod: .days30) == 5)
        #expect(MoodHeatmapSection.compactWeeks(forPeriod: .days90) == 13)
    }

    @Test("the year lens and the no-period fallback keep the canonical layout")
    func gridYearAndFallback() {
        // .year routes to the year grid (compact-week count is the 12 fallback,
        // unused), and nil (the More host) keeps the canonical 12-week grid.
        #expect(MoodHeatmapSection.compactWeeks(forPeriod: .year) == 12)
        #expect(MoodHeatmapSection.compactWeeks(forPeriod: nil) == 12)
    }

    @Test("changing the page range changes the grid window")
    func rangeChangeChangesWindow() {
        let thirty = MoodHeatmapSection.compactWeeks(forPeriod: .days30)
        let ninety = MoodHeatmapSection.compactWeeks(forPeriod: .days90)
        #expect(thirty != ninety)
    }

    // MARK: - E3: the drill-down resolves entries via the SAME page range

    @Test("the drill-down count is the page-range-bound entry count (same filter the grid uses)")
    func drillDownCountFollowsRange() {
        let entries = [
            Self.entry(daysAgo: 1),
            Self.entry(daysAgo: 20),
            Self.entry(daysAgo: 60), // outside 30d, inside 90d
            Self.entry(daysAgo: 200) // outside both
        ]
        let in30 = MoodPeriod.days30.filter(entries, now: Self.now, calendar: Self.fixedCalendar).count
        let in90 = MoodPeriod.days90.filter(entries, now: Self.now, calendar: Self.fixedCalendar).count
        #expect(in30 == 2)
        #expect(in90 == 3)
    }

    @Test("an empty window with data elsewhere is the outside-the-period case (D2 honesty)")
    func outsideRangeDetected() {
        let entries = [Self.entry(daysAgo: 200)]
        let in30 = MoodPeriod.days30.filter(entries, now: Self.now, calendar: Self.fixedCalendar).count
        #expect(in30 == 0)
        #expect(!entries.isEmpty) // → drill-down shows "Entries outside the period"
    }
}
