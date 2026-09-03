import Foundation
@testable import HealthLog
import Testing

/// Build 273 (A12) — window-based day totals (daily statistics, nutrients)
/// must catch up from the last completed sweep after dormancy instead of a
/// fixed lookback. Neither partition is incremental, so a phone left alone for
/// nine days lost days two to nine forever with a 7-day (stats) or 1-day
/// (nutrients) lookback.
@Suite("Day-total sweeps — catch-up from the last completed sweep")
struct HealthKitDormancyWindowTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date()
    }

    @Test("stats: last sweep 10 days ago beats the 7-day lookback (one day overlap)")
    func statsCatchesUp() {
        let now = date("2026-06-25T12:00:00Z")
        let from = HealthKitStatisticsSyncCoordinator.sweepWindowStart(
            now: now, lookbackDays: 7, lastCompletedSweepEnd: date("2026-06-15T12:00:00Z"), calendar: calendar
        )
        #expect(from == date("2026-06-14T12:00:00Z"))
    }

    @Test("stats: a recent sweep never narrows the lookback")
    func statsNeverNarrower() {
        let now = date("2026-06-25T12:00:00Z")
        let from = HealthKitStatisticsSyncCoordinator.sweepWindowStart(
            now: now, lookbackDays: 7, lastCompletedSweepEnd: date("2026-06-24T12:00:00Z"), calendar: calendar
        )
        #expect(from == date("2026-06-18T12:00:00Z"))
    }

    @Test("stats: catch-up is bounded")
    func statsBounded() {
        let now = date("2026-06-25T12:00:00Z")
        let from = HealthKitStatisticsSyncCoordinator.sweepWindowStart(
            now: now, lookbackDays: 7, lastCompletedSweepEnd: date("2026-01-01T12:00:00Z"), calendar: calendar
        )
        let bound = calendar.date(byAdding: .day, value: -HealthKitStatisticsSyncCoordinator.maxCatchUpDays, to: now)
        #expect(from == bound)
    }

    @Test("stats: no record of a sweep → the lookback as before")
    func statsNoRecord() {
        let now = date("2026-06-25T12:00:00Z")
        let from = HealthKitStatisticsSyncCoordinator.sweepWindowStart(
            now: now, lookbackDays: 3650, lastCompletedSweepEnd: nil, calendar: calendar
        )
        #expect(from == calendar.date(byAdding: .day, value: -3650, to: now))
    }

    @Test("nutrients: last sweep 9 days ago beats the 1-day lookback")
    func nutrientsCatchUp() {
        let now = date("2026-06-25T12:00:00Z")
        let from = NutrientDailySyncCoordinator.sweepWindowStart(
            now: now, lookbackDays: 1, lastCompletedSweepEnd: date("2026-06-16T12:00:00Z"), calendar: calendar
        )
        #expect(from == date("2026-06-15T12:00:00Z"))
    }
}
