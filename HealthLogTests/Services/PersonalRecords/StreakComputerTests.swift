import Foundation
@testable import HealthLog
import Testing

/// v0.5.4-BF7 — StreakComputer derivation contract tests.
///
/// Pins the two-record output shape (best-day + longest streak ≥
/// threshold), the consecutive-day gap detection, the threshold filter,
/// and the empty-series / unsupported-kind short-circuits. The screen
/// renders `PersonalRecordDTO` directly so this test acts as the
/// behavioural anchor for the operator-visible "Schritte"-section.
@Suite("StreakComputer — Schritte best-day + streak derivation")
struct StreakComputerTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return c
    }()

    @Test("Empty series returns no records")
    func emptySeriesReturnsEmpty() {
        let result = StreakComputer.derive(
            points: [],
            kind: .steps,
            userId: "u1",
            now: Date(timeIntervalSince1970: 1_716_000_000),
            calendar: cal
        )
        #expect(result.isEmpty)
    }

    @Test("Unsupported kind returns no records")
    func unsupportedKindReturnsEmpty() {
        // Pulse is server-supported as a series but is NOT in
        // `canonicalConfigs` — the streak heuristic only applies to
        // cumulative kinds (Schritte / Active Energy etc.). Verify the
        // computer short-circuits cleanly.
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let points = [
            SeriesPoint(id: "p1", at: now, value: 80, secondary: nil)
        ]
        let result = StreakComputer.derive(
            points: points,
            kind: .pulse,
            userId: "u1",
            now: now,
            calendar: cal
        )
        #expect(result.isEmpty)
    }

    @Test("Single high-step day yields best-day record without streak")
    func singleDayProducesBestDayOnly() {
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let points = [
            SeriesPoint(id: "p1", at: day, value: 18500, secondary: nil)
        ]
        let result = StreakComputer.derive(
            points: points,
            kind: .steps,
            userId: "u1",
            now: day,
            calendar: cal
        )
        #expect(result.count == 1)
        #expect(result.first?.id == "client.steps.best")
        #expect(result.first?.value == 18500)
        #expect(result.first?.metricType == "ACTIVITY_STEPS")
        #expect(result.first?.direction == .max)
        #expect(result.first?.unit == "steps")
    }

    @Test("Three consecutive 10k-days produce a streak record of length 3")
    func consecutiveHighDaysProduceStreak() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let points = (0 ..< 3).map { offset -> SeriesPoint in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            return SeriesPoint(id: "p\(offset)", at: date, value: 12000, secondary: nil)
        }
        let result = StreakComputer.derive(
            points: points,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        // Expect best-day + streak record.
        #expect(result.count == 2)
        let streak = result.first { $0.id == "client.steps.streak" }
        #expect(streak != nil)
        #expect(streak?.value == 3)
        #expect(streak?.unit == "Tage")
        #expect(streak?.metricSlot?.contains("Längste Serie") == true)
        #expect(streak?.metricSlot?.contains("3 Tage") == true)
    }

    @Test("Gap day breaks the streak — best run wins")
    func gapBreaksStreak() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        // Pattern: 2 high days, 1 low day, 4 high days → longest = 4
        let valueByOffset: [Int: Double] = [
            0: 11000,
            1: 10500,
            2: 4000, // breaks the streak
            3: 12000,
            4: 12500,
            5: 11200,
            6: 13000
        ]
        let points = valueByOffset.keys.sorted().map { offset -> SeriesPoint in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            return SeriesPoint(id: "p\(offset)", at: date, value: valueByOffset[offset] ?? 0, secondary: nil)
        }
        let result = StreakComputer.derive(
            points: points,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        let streak = result.first { $0.id == "client.steps.streak" }
        #expect(streak != nil)
        #expect(streak?.value == 4)
    }

    @Test("Calendar-day gap (missing point) also breaks the streak")
    func calendarGapBreaksStreak() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        // Day 0 + Day 1 high, then SKIP day 2 (no point at all), Day 3 + 4 high.
        let offsets = [0, 1, 3, 4]
        let points = offsets.map { offset -> SeriesPoint in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            return SeriesPoint(id: "p\(offset)", at: date, value: 12000, secondary: nil)
        }
        let result = StreakComputer.derive(
            points: points,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        let streak = result.first { $0.id == "client.steps.streak" }
        #expect(streak?.value == 2)
    }

    @Test("All days below threshold yields best-day but no streak")
    func belowThresholdProducesBestDayOnly() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let points = (0 ..< 5).map { offset -> SeriesPoint in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            return SeriesPoint(id: "p\(offset)", at: date, value: 4500, secondary: nil)
        }
        let result = StreakComputer.derive(
            points: points,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        // Best-day surfaces (value > 0), streak is filtered out.
        #expect(result.count == 1)
        #expect(result.first?.id == "client.steps.best")
        #expect(result.first?.value == 4500)
    }

    @Test("Best-day skips zero-value entries")
    func bestDayIgnoresZeros() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let pts = [
            SeriesPoint(id: "p0", at: start, value: 0, secondary: nil),
            SeriesPoint(id: "p1", at: cal.date(byAdding: .day, value: 1, to: start) ?? start, value: 8400, secondary: nil)
        ]
        let result = StreakComputer.derive(
            points: pts,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        #expect(result.first?.value == 8400)
        #expect(result.first?.sourceMeasurementId == "p1")
    }

    @Test("Single-day streak is suppressed — only 2+ qualifies")
    func singleDayStreakSuppressed() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        // One isolated 10k day, then a gap of 5 days, then another 10k day.
        let pts = [
            SeriesPoint(id: "p0", at: start, value: 12000, secondary: nil),
            SeriesPoint(
                id: "p5",
                at: cal.date(byAdding: .day, value: 5, to: start) ?? start,
                value: 11000,
                secondary: nil
            )
        ]
        let result = StreakComputer.derive(
            points: pts,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        // Best-day only — no streak because no run ≥ 2 consecutive days.
        #expect(result.count == 1)
        #expect(result.first?.id == "client.steps.best")
    }

    @Test("Streak record's achievedAt is the end of the run")
    func streakAchievedAtIsRunEnd() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let points = (0 ..< 4).map { offset -> SeriesPoint in
            let date = cal.date(byAdding: .day, value: offset, to: start) ?? start
            return SeriesPoint(id: "p\(offset)", at: date, value: 12000, secondary: nil)
        }
        let result = StreakComputer.derive(
            points: points,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        let streak = result.first { $0.id == "client.steps.streak" }
        let expectedEnd = cal.date(byAdding: .day, value: 3, to: start) ?? start
        #expect(streak?.achievedAt == expectedEnd)
    }

    @Test("Out-of-order input is sorted defensively")
    func defensiveSort() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        // Submit days in shuffled order — should still detect the 3-day run.
        let pts = [
            SeriesPoint(id: "p2", at: cal.date(byAdding: .day, value: 2, to: start) ?? start, value: 12000, secondary: nil),
            SeriesPoint(id: "p0", at: start, value: 12000, secondary: nil),
            SeriesPoint(id: "p1", at: cal.date(byAdding: .day, value: 1, to: start) ?? start, value: 12000, secondary: nil)
        ]
        let result = StreakComputer.derive(
            points: pts,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        let streak = result.first { $0.id == "client.steps.streak" }
        #expect(streak?.value == 3)
    }

    // MARK: - v0.5.5.3 REG-9 regression — multi-row-per-day handling

    /// Operator TestFlight build 23 (2026-05-21) reported "8123 Schritte
    /// am 15.05.2024" surfacing as a record when the actual all-time best
    /// was 10843 Schritte am 14.03.2024. Root cause: the server `series`
    /// endpoint emits one row per `Measurement` (not one per calendar
    /// day). When a user has legacy per-sample rows or multi-source
    /// uploads, picking the largest single row understates the daily
    /// total. This test pins the fix: aggregate by `startOfDay` and sum
    /// before ranking.
    @Test("REG-9: multiple rows per day sum into the daily total before max-day ranking")
    func multipleRowsPerDayAreSummed() {
        let day14March = cal.startOfDay(
            for: cal.date(from: DateComponents(year: 2024, month: 3, day: 14, hour: 12)) ?? Date()
        )
        let day15May = cal.startOfDay(
            for: cal.date(from: DateComponents(year: 2024, month: 5, day: 15, hour: 12)) ?? Date()
        )
        // 14.03.2024 has three hour-bucket rows that sum to 10843 (max day).
        // 15.05.2024 has a single 8123-step row (a per-sample legacy row).
        // Picking max(row.value) would surface 8123; picking max(sum-per-day)
        // surfaces 10843.
        let pts = [
            SeriesPoint(
                id: "march-morning",
                at: cal.date(byAdding: .hour, value: 8, to: day14March) ?? day14March,
                value: 4123,
                secondary: nil
            ),
            SeriesPoint(
                id: "march-noon",
                at: cal.date(byAdding: .hour, value: 13, to: day14March) ?? day14March,
                value: 3500,
                secondary: nil
            ),
            SeriesPoint(
                id: "march-evening",
                at: cal.date(byAdding: .hour, value: 19, to: day14March) ?? day14March,
                value: 3220,
                secondary: nil
            ),
            SeriesPoint(
                id: "may-rogue-large-sample",
                at: cal.date(byAdding: .hour, value: 12, to: day15May) ?? day15May,
                value: 8123,
                secondary: nil
            )
        ]
        let result = StreakComputer.derive(
            points: pts,
            kind: .steps,
            userId: "u1",
            now: day15May,
            calendar: cal
        )
        let best = result.first { $0.id == "client.steps.best" }
        #expect(best != nil)
        #expect(best?.value == 10843)
        #expect(best?.achievedAt == day14March)
        // The previously-broken predicate would have returned 8123 — guard
        // against any regression that re-introduces the per-row max-pick.
        #expect(best?.value != 8123)
    }

    @Test("REG-9: streak threshold checks the day total, not individual rows")
    func streakRunsOnDailyTotal() {
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        // Each day has two 6000-step rows. Per-row, no single value hits
        // the 10k threshold, but the daily sum (12000) clears it on each
        // of three consecutive days. Old code would have returned no
        // streak; new code returns a 3-day streak.
        var pts: [SeriesPoint] = []
        for offset in 0 ..< 3 {
            let day = cal.date(byAdding: .day, value: offset, to: start) ?? start
            pts.append(SeriesPoint(
                id: "morning-\(offset)",
                at: cal.date(byAdding: .hour, value: 8, to: day) ?? day,
                value: 6000,
                secondary: nil
            ))
            pts.append(SeriesPoint(
                id: "evening-\(offset)",
                at: cal.date(byAdding: .hour, value: 19, to: day) ?? day,
                value: 6000,
                secondary: nil
            ))
        }
        let result = StreakComputer.derive(
            points: pts,
            kind: .steps,
            userId: "u1",
            now: start,
            calendar: cal
        )
        let streak = result.first { $0.id == "client.steps.streak" }
        #expect(streak?.value == 3)
    }

    @Test("REG-9: single-day with multiple rows yields a single daily bucket")
    func singleDayMultipleRowsCollapseToOneBucket() {
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let pts = [
            SeriesPoint(id: "a", at: day, value: 5000, secondary: nil),
            SeriesPoint(
                id: "b",
                at: cal.date(byAdding: .hour, value: 10, to: day) ?? day,
                value: 7000,
                secondary: nil
            ),
            SeriesPoint(
                id: "c",
                at: cal.date(byAdding: .hour, value: 18, to: day) ?? day,
                value: 3000,
                secondary: nil
            )
        ]
        let result = StreakComputer.derive(
            points: pts,
            kind: .steps,
            userId: "u1",
            now: day,
            calendar: cal
        )
        // Best-day surfaces with the summed value (15000), not the
        // largest single row (7000). No streak because a single-day run
        // is suppressed.
        #expect(result.count == 1)
        #expect(result.first?.id == "client.steps.best")
        #expect(result.first?.value == 15000)
        #expect(result.first?.achievedAt == day)
    }
}
