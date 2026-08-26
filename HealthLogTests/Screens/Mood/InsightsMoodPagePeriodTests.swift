// swiftlint:disable force_unwrapping

import Foundation
@testable import HealthLog
import Testing

/// I-4 Item 3 — locks the data-span → default-period auto-select on the Insights
/// Mood page. The page opens on a sensible window derived from the operator's
/// mood history span: more than ~3 months of data → the year lens; a moderate
/// span → 90 days; very little data → 30 days. Pure helpers, no render pass.
@Suite("Insights mood period auto-select")
struct InsightsMoodPagePeriodTests {
    /// UTC-anchored fixed calendar so the day-bucketing is deterministic across
    /// CI machine zones.
    private static var fixedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    private static func entry(daysAgo: Int, id: String = UUID().uuidString) -> MoodEntry {
        let cal = fixedCalendar
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        let stamp = cal.date(byAdding: .hour, value: 12, to: day)!
        return MoodEntry(id: id, recordedAt: stamp, score: 3)
    }

    // MARK: - spanDays

    @Test("empty history has zero span")
    func emptySpan() {
        #expect(InsightsMoodPage.spanDays(of: [], calendar: Self.fixedCalendar) == 0)
    }

    @Test("single-day history has zero span")
    func singleEntrySpan() {
        let entries = [Self.entry(daysAgo: 5)]
        #expect(InsightsMoodPage.spanDays(of: entries, calendar: Self.fixedCalendar) == 0)
    }

    @Test("span is the day-difference between earliest and latest entry")
    func multiEntrySpan() {
        let entries = [Self.entry(daysAgo: 200), Self.entry(daysAgo: 10), Self.entry(daysAgo: 0)]
        #expect(InsightsMoodPage.spanDays(of: entries, calendar: Self.fixedCalendar) == 200)
    }

    // MARK: - defaultPeriod rule

    @Test("more than ~3 months of data opens on the year lens")
    func longSpanPicksYear() {
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 200) == .year)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 91) == .year)
    }

    @Test("a moderate span opens on 90 days")
    func moderateSpanPicks90() {
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 90) == .days90)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 45) == .days90)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 31) == .days90)
    }

    @Test("very little data opens on 30 days")
    func shortSpanPicks30() {
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 30) == .days30)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 7) == .days30)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: 0) == .days30)
    }

    // MARK: - End-to-end (span → period)

    @Test("a full year of history auto-selects the year lens")
    func yearOfHistoryPicksYear() {
        let entries = [Self.entry(daysAgo: 365), Self.entry(daysAgo: 1)]
        let span = InsightsMoodPage.spanDays(of: entries, calendar: Self.fixedCalendar)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: span) == .year)
    }

    @Test("two weeks of history auto-selects 30 days")
    func sparseHistoryPicks30() {
        let entries = [Self.entry(daysAgo: 14), Self.entry(daysAgo: 0)]
        let span = InsightsMoodPage.spanDays(of: entries, calendar: Self.fixedCalendar)
        #expect(InsightsMoodPage.defaultPeriod(forSpanDays: span) == .days30)
    }
}
