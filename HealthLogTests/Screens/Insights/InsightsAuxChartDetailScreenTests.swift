import Foundation
@testable import HealthLog
import Testing

/// v0.6.2.3 — boundary regression for the Stabilität tile's rolling
/// 7-day spread. Earlier code filtered `recordedAt <= cursor` where
/// `cursor` is `startOfDay(...)`, which dropped every entry logged
/// after midnight on the labelled day. The hero strip headlines today's
/// number with today's date, so today MUST be included in the window.
@Suite("InsightsAuxMoodStabilityDetail rolling spread")
struct InsightsAuxChartDetailScreenTests {
    private var calendar: Calendar {
        Calendar.current
    }

    /// Fixed local-time anchor so the window math stays deterministic
    /// independent of the test host's clock. Returns `nil` only on a
    /// pathological calendar — every test guards on it explicitly.
    private func today() -> Date? {
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 3
        comps.day = 14
        comps.hour = 12
        return calendar.date(from: comps)
    }

    private func mood(score: Int, daysAgo: Int, hour: Int = 12, from anchor: Date) -> MoodEntry? {
        guard let base = calendar.date(byAdding: .day, value: -daysAgo, to: anchor) else { return nil }
        let dayStart = calendar.startOfDay(for: base)
        guard let at = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { return nil }
        return MoodEntry(id: "m-\(daysAgo)-\(hour)-\(score)", recordedAt: at, score: score)
    }

    // MARK: - Boundary fix (the off-by-one this commit closes)

    @Test("Today's entries fall inside the bucket labelled with today")
    func todaysEntriesIncludedInTodayBucket() throws {
        let anchor = try #require(today())
        // Two entries logged today after `startOfDay(today)` — the old
        // `<= startOfDay` filter excluded both, so the spread bucket
        // for today either disappeared or showed yesterday's spread.
        let entries: [MoodEntry] = try [
            #require(mood(score: 2, daysAgo: 6, hour: 9, from: anchor)),
            #require(mood(score: 3, daysAgo: 3, hour: 9, from: anchor)),
            #require(mood(score: 1, daysAgo: 0, hour: 8, from: anchor)),
            #require(mood(score: 5, daysAgo: 0, hour: 20, from: anchor))
        ]

        let buckets = InsightsAuxMoodStabilityDetailScreen.computeRollingSpread(
            entries: entries,
            calendar: calendar
        )

        // The last bucket MUST be today and MUST reflect today's 1↔5
        // delta (the max-spread that only exists when today is included).
        let todayStart = calendar.startOfDay(for: anchor)
        let last = try #require(buckets.last)
        #expect(calendar.isDate(last.date, inSameDayAs: todayStart))
        #expect(last.value == 4.0)
    }

    @Test("Entry exactly at startOfDay(cursor + 1) is excluded (half-open window)")
    func nextDayMidnightExcluded() throws {
        let anchor = try #require(today())
        let nextDayStart = try #require(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor))
        )
        // One entry today 09:00, one entry exactly at tomorrow 00:00.
        // The bucket labelled `today` covers `[today-6d, tomorrow 00:00)`,
        // so the tomorrow-midnight sample must NOT influence today's
        // spread — it belongs to tomorrow's bucket.
        let entries: [MoodEntry] = try [
            #require(mood(score: 3, daysAgo: 6, hour: 12, from: anchor)),
            #require(mood(score: 3, daysAgo: 0, hour: 9, from: anchor)),
            MoodEntry(id: "boundary", recordedAt: nextDayStart, score: 5)
        ]

        let buckets = InsightsAuxMoodStabilityDetailScreen.computeRollingSpread(
            entries: entries,
            calendar: calendar
        )

        if let todayBucket = buckets.first(where: { calendar.isDate($0.date, inSameDayAs: anchor) }) {
            #expect(todayBucket.value == 0.0)
        }
    }

    // MARK: - Existing behaviour (regression cover)

    @Test("Empty input yields no buckets")
    func emptyInput() {
        #expect(InsightsAuxMoodStabilityDetailScreen.computeRollingSpread(entries: []).isEmpty)
    }

    @Test("Single entry yields no bucket (need ≥2 in window)")
    func singleEntryNoBucket() throws {
        let anchor = try #require(today())
        let entries: [MoodEntry] = try [#require(mood(score: 3, daysAgo: 0, from: anchor))]
        #expect(InsightsAuxMoodStabilityDetailScreen.computeRollingSpread(entries: entries).isEmpty)
    }

    @Test("Spread equals max-min across the trailing 7 days")
    func spreadIsMaxMinusMin() throws {
        let anchor = try #require(today())
        let entries: [MoodEntry] = try [
            #require(mood(score: 1, daysAgo: 5, hour: 9, from: anchor)),
            #require(mood(score: 5, daysAgo: 2, hour: 9, from: anchor)),
            #require(mood(score: 3, daysAgo: 0, hour: 9, from: anchor))
        ]
        let buckets = InsightsAuxMoodStabilityDetailScreen.computeRollingSpread(
            entries: entries,
            calendar: calendar
        )
        let last = try #require(buckets.last)
        #expect(last.value == 4.0) // 5 − 1
    }

    @Test("Entry older than 7 days falls out of the window")
    func entryOlderThanSevenDaysExcluded() throws {
        let anchor = try #require(today())
        // Day -7 entry must NOT influence the bucket labelled "today",
        // because the window is [today - 6d, today + 1d).
        let entries: [MoodEntry] = try [
            #require(mood(score: 1, daysAgo: 7, hour: 9, from: anchor)),
            #require(mood(score: 4, daysAgo: 5, hour: 9, from: anchor)),
            #require(mood(score: 5, daysAgo: 0, hour: 9, from: anchor))
        ]
        let buckets = InsightsAuxMoodStabilityDetailScreen.computeRollingSpread(
            entries: entries,
            calendar: calendar
        )
        // Find the bucket labelled "today" and assert its spread is 5−4=1,
        // not 5−1=4 (the wrong answer if the 7-day-ago sample leaked in).
        let todayBucket = try #require(buckets.first(where: { calendar.isDate($0.date, inSameDayAs: anchor) }))
        #expect(todayBucket.value == 1.0)
    }
}
