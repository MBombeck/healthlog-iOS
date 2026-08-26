import Foundation
@testable import HealthLog
import Testing

/// Disambiguate from Foundation.Measurement<Unit> — HealthLog ships its own
/// domain Measurement and the test file scopes both via Foundation + HealthLog.
private typealias Measurement = HealthLog.Measurement

/// Pin the Apple-Health-style grouping rules introduced in v0.4.1. The
/// audit's headline complaint was a flat "Older" bucket exploding into a
/// wall of rows for daily loggers — the new rules collapse to weekly /
/// monthly summary cards once a period crosses its threshold.
@Suite("MeasurementBucketing — Apple-Health adaptive grouping")
struct MeasurementBucketingTests {
    private var calendar: Calendar {
        get throws {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            cal.firstWeekday = 2 // Monday — matches Apple Health locale default
            return cal
        }
    }

    private func now() throws -> Date {
        // Friday 2026-05-15 14:00 local Berlin time — stable reference for
        // bucketing boundaries (gives clean Mon..Sun week boundaries).
        var c = DateComponents()
        c.year = 2026
        c.month = 5
        c.day = 15
        c.hour = 14
        return try #require(calendar.date(from: c))
    }

    private func measurement(daysAgo: Int, value: Double = 80, secondary: Double? = nil) throws -> Measurement {
        let date = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: now()))
        return Measurement(
            id: "m-\(daysAgo)",
            kind: secondary == nil ? .weight : .bloodPressure,
            recordedAt: date,
            value: secondary.map { .bloodPressure(systolic: value, diastolic: $0) } ?? .scalar(value),
            note: nil,
            source: .manual
        )
    }

    @Test("Last-7-day window emits per-day sections — no aggregation")
    func recentSevenDaysAreDayRows() throws {
        let items = try (0 ... 6).map { try measurement(daysAgo: $0) }
        let sections = try MeasurementBucketing.sections(for: items, now: now(), calendar: calendar)
        for section in sections {
            if case .day = section {} else {
                Issue.record("Recent section was not .day: \(section)")
            }
        }
        #expect(sections.count == 7) // one per day
    }

    @Test("Week with ≤5 items (boundary) still renders per-day rows")
    func weekAtThresholdIsRawRows() throws {
        // 5 items spread across days 8..12 — same ISO week, all in mid-range
        // (older than 7 days, younger than 90). At the threshold (≤5) we
        // should still see day sections, not a weeklySummary.
        let items = try (8 ... 12).map { try measurement(daysAgo: $0) }
        let sections = try MeasurementBucketing.sections(for: items, now: now(), calendar: calendar)
        let hasWeekly = sections.contains { if case .weeklySummary = $0 { true } else { false } }
        #expect(!hasWeekly, "5 items/week must NOT collapse to weeklySummary")
    }

    @Test("Week with 6 items (over-threshold) collapses to weeklySummary")
    func weekOverThresholdCollapsesToSummary() throws {
        // Pin "now" to a Sunday so the prior full ISO week is days 8..14
        // (one full week, Mon..Sun) — counting > 5 items there must collapse.
        var sundayComponents = DateComponents()
        sundayComponents.year = 2026
        sundayComponents.month = 5
        sundayComponents.day = 17 // Sunday
        sundayComponents.hour = 14
        let sundayNow = try #require(calendar.date(from: sundayComponents))
        // 6 items spread across the previous week (days 8..13 from Sunday →
        // Sat 2026-05-09 back to Mon 2026-05-04, all in week 19).
        let items = try (8 ... 13).map { daysAgo -> Measurement in
            let date = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: sundayNow))
            return Measurement(id: "m-\(daysAgo)", kind: .weight, recordedAt: date, value: .scalar(80))
        }
        let sections = try MeasurementBucketing.sections(for: items, now: sundayNow, calendar: calendar)
        let hasWeekly = sections.contains { if case .weeklySummary = $0 { true } else { false } }
        #expect(hasWeekly, "6 items in one ISO week must collapse to weeklySummary")
    }

    @Test("Month with >20 items collapses to monthlySummary")
    func monthOverThresholdCollapsesToSummary() throws {
        // 25 items spread across 25 days, all > 90 days back.
        let items = try (100 ... 124).map { try measurement(daysAgo: $0) }
        let sections = try MeasurementBucketing.sections(for: items, now: now(), calendar: calendar)
        let hasMonthly = sections.contains { if case .monthlySummary = $0 { true } else { false } }
        #expect(hasMonthly, "25 items/month must collapse to monthlySummary")
    }

    @Test("Sections sort newest-first across all variants")
    func sectionsNewestFirst() throws {
        let items: [Measurement] = try [
            measurement(daysAgo: 0), measurement(daysAgo: 30), measurement(daysAgo: 100)
        ]
        let sections = try MeasurementBucketing.sections(for: items, now: now(), calendar: calendar)
        // Recent (day) → mid-range (day, since count == 1) → older (day).
        #expect(sections.count == 3)
        // Pull the first item.recordedAt from each section and assert
        // descending order.
        let dates: [Date] = sections.map {
            switch $0 {
            case let .day(_, items): items.first?.recordedAt ?? .distantPast
            case let .weeklySummary(_, items): items.first?.recordedAt ?? .distantPast
            case let .monthlySummary(_, items): items.first?.recordedAt ?? .distantPast
            }
        }
        let sorted = dates.sorted(by: >)
        #expect(dates == sorted)
    }

    @Test("Empty input → empty sections")
    func emptyPassthrough() throws {
        let out = try MeasurementBucketing.sections(for: [], now: now(), calendar: calendar)
        #expect(out.isEmpty)
    }
}

/// SummaryStats pure-math pin — Min/Avg/Max from a measurement bucket,
/// including the BP secondary path used by weekly BP rollup rendering.
@Suite("SummaryStats — measurement aggregate math")
struct SummaryStatsTests {
    @Test("Scalar bucket computes min/mean/max")
    func scalarStats() {
        let items: [Measurement] = [
            Measurement(id: "a", kind: .weight, recordedAt: .distantPast, value: .scalar(80)),
            Measurement(id: "b", kind: .weight, recordedAt: .distantPast, value: .scalar(82)),
            Measurement(id: "c", kind: .weight, recordedAt: .distantPast, value: .scalar(84))
        ]
        let stats = SummaryStats.compute(items: items)
        #expect(stats.count == 3)
        #expect(stats.mean == 82)
        #expect(stats.min == 80)
        #expect(stats.max == 84)
        #expect(stats.secondaryMean == nil)
    }

    @Test("BP bucket computes systolic + diastolic means in parallel")
    func bpStats() {
        let items: [Measurement] = [
            Measurement(
                id: "a",
                kind: .bloodPressure,
                recordedAt: .distantPast,
                value: .bloodPressure(systolic: 120, diastolic: 78)
            ),
            Measurement(
                id: "b",
                kind: .bloodPressure,
                recordedAt: .distantPast,
                value: .bloodPressure(systolic: 124, diastolic: 82)
            )
        ]
        let stats = SummaryStats.compute(items: items)
        #expect(stats.mean == 122) // systolic mean
        #expect(stats.secondaryMean == 80) // diastolic mean
        #expect(stats.secondaryMin == 78)
        #expect(stats.secondaryMax == 82)
    }
}
