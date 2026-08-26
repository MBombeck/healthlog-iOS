import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping type_body_length file_length

/// **v0.10 R1 §3.2 — parity oracle for `MedicationRecurrenceEngine`.**
///
/// Ports the server's `recurrence.test.ts` vectors verbatim where possible so
/// the iOS engine stays a faithful mirror of the canonical server engine. Any
/// divergence here is a parity bug, not a fixture quirk (R1 risk 1).
@Suite("MedicationRecurrenceEngine — server parity")
struct MedicationRecurrenceEngineTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let g = ISO8601DateFormatter()
        g.formatOptions = [.withInternetDateTime]
        return g.date(from: s)!
    }

    /// Build a UTC-midnight course date matching the server's `new Date("…Z")`
    /// at 00:00 UTC.
    private static func courseDate(_ ymd: String) -> Date {
        iso("\(ymd)T00:00:00Z")
    }

    private static func entry(
        cadence: Cadence,
        times: [String] = [],
        windowStart: String = "08:00",
        windowEnd: String = "09:00",
        grace: Int? = nil
    ) -> ScheduleEntry {
        ScheduleEntry(
            cadence: cadence,
            timesOfDay: times.compactMap { TimeOfDay.parse($0) },
            reminderGraceMinutes: grace,
            windowStart: TimeOfDay.parse(windowStart)!,
            windowEnd: TimeOfDay.parse(windowEnd)
        )
    }

    private static func ctx(
        startsOn: String? = nil,
        endsOn: String? = nil,
        oneShot: Bool = false,
        createdAt: String = "2026-01-01T00:00:00Z",
        lastIntakeAt: Date? = nil,
        tz: TimeZone = berlin
    ) -> MedicationRecurrenceEngine.Context {
        MedicationRecurrenceEngine.Context(
            startsOn: startsOn.map { courseDate($0) },
            endsOn: endsOn.map { courseDate($0) },
            oneShot: oneShot,
            createdAt: iso(createdAt),
            lastIntakeAt: lastIntakeAt,
            timeZone: tz
        )
    }

    private static func berlinDay(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func run(
        _ e: ScheduleEntry,
        _ c: MedicationRecurrenceEngine.Context,
        from: Date,
        to: Date
    ) -> [MedicationRecurrenceEngine.Occurrence] {
        MedicationRecurrenceEngine.occurrences(in: from ... to, entry: e, context: c)
    }

    // MARK: - RRULE DAILY

    @Test("DAILY 7-day window, one time → 7 occurrences")
    func dailySingleTime() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["08:00"]),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-07T23:59:59Z")
        )
        #expect(slots.count == 7)
    }

    @Test("DAILY 7-day window, two times → 14 occurrences")
    func dailyTwoTimes() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["08:00", "20:00"]),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-07T23:59:59Z")
        )
        #expect(slots.count == 14)
        let morning = slots.filter { $0.timeOfDay == TimeOfDay(hour: 8, minute: 0) }.count
        let evening = slots.filter { $0.timeOfDay == TimeOfDay(hour: 20, minute: 0) }.count
        #expect(morning == 7)
        #expect(evening == 7)
    }

    // MARK: - WEEKLY

    @Test("WEEKLY MO,WE,FR over 14 days → 6 occurrences")
    func weeklySubset() {
        let slots = run(
            Self.entry(cadence: .weekdays([.mon, .wed, .fri]), times: ["08:00"]),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-14T23:59:59Z")
        )
        #expect(slots.count == 6)
    }

    @Test("bi-weekly Wed anchored on Wed → 03 + 17 only")
    func biWeeklyWed() {
        let slots = run(
            Self.entry(cadence: .everyNWeeks(interval: 2, days: [.wed]), times: ["08:00"]),
            Self.ctx(startsOn: "2026-06-03"),
            from: Self.courseDate("2026-06-03"),
            to: Self.iso("2026-06-30T23:59:59Z")
        )
        #expect(slots.count == 2)
        #expect(slots.map { Self.berlinDay($0.at) } == ["2026-06-03", "2026-06-17"])
    }

    // MARK: - MONTHLY / QUARTERLY / YEARLY

    @Test("MONTHLY BYMONTHDAY=1 over Feb-Mar-Apr → 3")
    func monthlyFirst() {
        let slots = run(
            Self.entry(cadence: .monthly(day: 1), times: ["08:00"]),
            Self.ctx(startsOn: "2026-02-01"),
            from: Self.courseDate("2026-02-01"),
            to: Self.iso("2026-04-30T23:59:59Z")
        )
        #expect(slots.count == 3)
    }

    @Test("MONTHLY INTERVAL=3 BYMONTHDAY=15 Jan..Sep → 3 (Jan/Apr/Jul)")
    func quarterly() {
        let slots = run(
            Self.entry(cadence: .everyNMonths(interval: 3, day: 15), times: ["08:00"]),
            Self.ctx(startsOn: "2026-01-15"),
            from: Self.courseDate("2026-01-01"),
            to: Self.iso("2026-09-30T23:59:59Z")
        )
        #expect(slots.count == 3)
        #expect(slots.map { Self.berlinDay($0.at) } == ["2026-01-15", "2026-04-15", "2026-07-15"])
    }

    @Test("YEARLY Jan 1 over 24 months → 2")
    func yearly() {
        let slots = run(
            Self.entry(cadence: .yearly(month: 1, day: 1), times: ["08:00"]),
            Self.ctx(startsOn: "2026-01-01"),
            from: Self.courseDate("2026-01-01"),
            to: Self.iso("2027-12-31T23:59:59Z")
        )
        #expect(slots.count == 2)
    }

    // MARK: - Rolling

    @Test("rolling=7 + lastIntake=NOW-3d → one slot at lastIntake+7d")
    func rollingReAnchorsOnIntake() {
        let now = Self.iso("2026-06-10T12:00:00Z")
        let lastIntake = now.addingTimeInterval(-3 * 86400)
        let slots = run(
            Self.entry(cadence: .rolling(intervalDays: 7), times: ["08:00"]),
            Self.ctx(startsOn: "2026-06-01", lastIntakeAt: lastIntake),
            from: now,
            to: now.addingTimeInterval(14 * 86400)
        )
        #expect(slots.count == 1)
        let expected = lastIntake.addingTimeInterval(7 * 86400)
        #expect(Self.berlinDay(slots[0].at) == Self.berlinDay(expected))
    }

    @Test("rolling=7 + lastIntake=nil + startsOn=NOW-2d → one slot at startsOn+7d")
    func rollingAnchorsOnStartsOn() {
        let now = Self.iso("2026-06-10T12:00:00Z")
        // startsOn is a course date — model it as the 2-days-ago calendar day.
        let slots = run(
            Self.entry(cadence: .rolling(intervalDays: 7), times: ["08:00"]),
            Self.ctx(startsOn: "2026-06-08", lastIntakeAt: nil),
            from: now,
            to: now.addingTimeInterval(14 * 86400)
        )
        #expect(slots.count == 1)
        #expect(Self.berlinDay(slots[0].at) == "2026-06-15")
    }

    @Test("rolling terminates when endsOn falls before next-due")
    func rollingEndsOnTerminates() {
        let now = Self.iso("2026-06-10T12:00:00Z")
        let lastIntake = now.addingTimeInterval(-3 * 86400)
        let slots = run(
            Self.entry(cadence: .rolling(intervalDays: 7), times: ["08:00"]),
            Self.ctx(endsOn: "2026-06-12", lastIntakeAt: lastIntake),
            from: now,
            to: now.addingTimeInterval(14 * 86400)
        )
        #expect(slots.isEmpty)
    }

    @Test("rolling missed-extends: next slot stays overdue (one slot, not a backlog)")
    func rollingMissedExtends() {
        // lastIntake far in the past → next-due is in the past (overdue). The
        // engine still emits exactly ONE slot (the overdue one), not a backlog.
        let now = Self.iso("2026-06-20T12:00:00Z")
        let lastIntake = Self.iso("2026-06-01T08:00:00Z") // 19d ago, interval 7
        let slots = run(
            Self.entry(cadence: .rolling(intervalDays: 7), times: ["08:00"]),
            Self.ctx(lastIntakeAt: lastIntake),
            from: Self.iso("2026-05-01T00:00:00Z"),
            to: now.addingTimeInterval(14 * 86400)
        )
        #expect(slots.count == 1)
        #expect(Self.berlinDay(slots[0].at) == "2026-06-08") // lastIntake + 7d
    }

    // MARK: - One-shot

    @Test("one-shot emits one occurrence at startsOn + timesOfDay")
    func oneShotSingleSlot() {
        let now = Self.iso("2026-06-10T00:00:00Z")
        let slots = run(
            Self.entry(cadence: .oneShot, times: ["10:00"]),
            Self.ctx(startsOn: "2026-06-11", oneShot: true),
            from: now,
            to: now.addingTimeInterval(7 * 86400)
        )
        #expect(slots.count == 1)
        #expect(Self.berlinDay(slots[0].at) == "2026-06-11")
        #expect(slots[0].timeOfDay == TimeOfDay(hour: 10, minute: 0))
    }

    @Test("nextOccurrence returns nil past the one-shot date")
    func oneShotNextNil() {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T00:00:00Z"),
            entry: Self.entry(cadence: .oneShot, times: ["10:00"]),
            context: Self.ctx(startsOn: "2026-05-01", oneShot: true)
        )
        #expect(next == nil)
    }

    // MARK: - DST + cross-TZ

    @Test("02:30 Berlin spring-forward day forwards to 03:30 (= 01:30 UTC)")
    func dstSpringForward() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["02:30"]),
            Self.ctx(startsOn: "2026-03-28"),
            from: Self.courseDate("2026-03-28"),
            to: Self.iso("2026-03-31T23:59:59Z")
        )
        #expect(slots.count == 4)
        let transition = slots.first { Self.berlinDay($0.at) == "2026-03-29" }
        #expect(transition != nil)
        // 02:30 Berlin on the spring-forward day forwards to 03:30 = 01:30 UTC.
        #expect(transition?.at == Self.iso("2026-03-29T01:30:00Z"))
    }

    @Test("08:00 Tokyo (UTC+9) → 23:00 prior-day UTC")
    func tokyoOffset() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["08:00"]),
            Self.ctx(startsOn: "2026-06-15", tz: Self.tokyo),
            from: Self.iso("2026-06-14T00:00:00Z"),
            to: Self.iso("2026-06-16T23:59:59Z")
        )
        let utc = slots.map(\.at)
        #expect(utc.contains(Self.iso("2026-06-14T23:00:00Z")))
        #expect(utc.contains(Self.iso("2026-06-15T23:00:00Z")))
    }

    // MARK: - Legacy fallback

    @Test("legacy daysOfWeek=nil → daily (7 slots)")
    func legacyDaily() {
        let slots = run(
            Self.entry(cadence: .legacy(days: nil, intervalWeeks: 1), times: [], windowStart: "08:00"),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-07T23:59:59Z")
        )
        #expect(slots.count == 7)
    }

    @Test("legacy Mon/Wed/Fri → 3 slots in first week")
    func legacyMwf() {
        let slots = run(
            Self.entry(cadence: .legacy(days: [.mon, .wed, .fri], intervalWeeks: 1), times: [], windowStart: "08:00"),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-07T23:59:59Z")
        )
        #expect(slots.count == 3)
    }

    @Test("legacy i2;Wed → bi-weekly Wed (the intervalWeeks fix)")
    func legacyBiWeekly() {
        let slots = run(
            Self.entry(cadence: .legacy(days: [.wed], intervalWeeks: 2), times: [], windowStart: "08:00"),
            Self.ctx(startsOn: "2026-06-03"),
            from: Self.courseDate("2026-06-03"),
            to: Self.iso("2026-06-30T23:59:59Z")
        )
        #expect(slots.count == 2)
        #expect(slots.map { Self.berlinDay($0.at) } == ["2026-06-03", "2026-06-17"])
    }

    // MARK: - endsOn cap + startsOn floor

    @Test("nextOccurrence returns nil 5 years past endsOn")
    func endsOnCapNext() {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2031-07-01T00:00:00Z"),
            entry: Self.entry(cadence: .daily, times: ["08:00"]),
            context: Self.ctx(startsOn: "2026-06-01", endsOn: "2026-06-30")
        )
        #expect(next == nil)
    }

    @Test("legacy respects endsOn (01-03 inclusive → 3 slots)")
    func legacyEndsOn() {
        let slots = run(
            Self.entry(cadence: .legacy(days: nil, intervalWeeks: 1), times: [], windowStart: "08:00"),
            Self.ctx(startsOn: "2026-06-01", endsOn: "2026-06-03"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-10T23:59:59Z")
        )
        #expect(slots.count == 3)
    }

    @Test("startsOn floor — future startsOn emits only on/after it")
    func startsOnFloor() {
        let slots = run(
            Self.entry(cadence: .legacy(days: nil, intervalWeeks: 1), times: [], windowStart: "08:00"),
            Self.ctx(startsOn: "2026-06-10"),
            from: Self.courseDate("2026-06-05"),
            to: Self.iso("2026-06-12T23:59:59Z")
        )
        #expect(slots.map { Self.berlinDay($0.at) } == ["2026-06-10", "2026-06-11", "2026-06-12"])
    }

    // MARK: - empty timesOfDay fallback + grace

    @Test("empty timesOfDay falls back to windowStart")
    func emptyTimesFallback() {
        let slots = run(
            Self.entry(cadence: .daily, times: [], windowStart: "09:30"),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-02T23:59:59Z")
        )
        #expect(slots.count == 2)
        #expect(slots[0].timeOfDay == TimeOfDay(hour: 9, minute: 30))
    }

    @Test("grace: reminderGraceMinutes wins")
    func graceExplicit() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["08:00"], grace: 45),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-01T23:59:59Z")
        )
        #expect(slots.count == 1)
        #expect(slots[0].graceUntil.timeIntervalSince(slots[0].at) == 45 * 60)
    }

    @Test("grace: windowEnd - windowStart span")
    func graceSpan() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["08:00"], windowStart: "08:00", windowEnd: "10:00"),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-01T23:59:59Z")
        )
        #expect(slots[0].graceUntil.timeIntervalSince(slots[0].at) == 120 * 60)
    }

    @Test("grace: defaults to 60 when windowStart == windowEnd")
    func graceDefault() {
        let slots = run(
            Self.entry(cadence: .daily, times: ["08:00"], windowStart: "08:00", windowEnd: "08:00"),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-01T23:59:59Z")
        )
        #expect(slots[0].graceUntil.timeIntervalSince(slots[0].at) == 60 * 60)
    }

    // MARK: - nextOccurrence

    @Test("nextOccurrence walks to the next monthly-15th")
    func nextMonthly() throws {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-03-20T00:00:00Z"),
            entry: Self.entry(cadence: .monthly(day: 15), times: ["09:00"]),
            context: Self.ctx(startsOn: "2026-01-15")
        )
        #expect(next != nil)
        #expect(try Self.berlinDay(#require(next?.at)) == "2026-04-15")
    }

    @Test("nextOccurrence chunk-cap: future startsOn returns nil in bounded time")
    func nextChunkCap() {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T00:00:00Z"),
            entry: Self.entry(cadence: .daily, times: ["08:00"]),
            context: Self.ctx(startsOn: "2080-01-01")
        )
        #expect(next == nil)
    }

    // MARK: - PRN / as-needed (v1.7.0 SB-SCHED-5)

    @Test("asNeeded yields zero occurrences over any window")
    func asNeededNoOccurrences() {
        let slots = run(
            Self.entry(cadence: .asNeeded, times: ["08:00", "20:00"]),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-30T23:59:59Z")
        )
        #expect(slots.isEmpty)
    }

    @Test("asNeeded nextOccurrence is nil (no nextDueAt)")
    func asNeededNoNext() {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T00:00:00Z"),
            entry: Self.entry(cadence: .asNeeded, times: ["08:00"]),
            context: Self.ctx(startsOn: "2026-06-01")
        )
        #expect(next == nil)
    }

    @Test("asNeeded firesOn is always false")
    func asNeededFiresOnFalse() {
        let fires = MedicationRecurrenceEngine.firesOn(
            day: Self.courseDate("2026-06-15"),
            entry: Self.entry(cadence: .asNeeded, times: ["08:00"]),
            context: Self.ctx(startsOn: "2026-06-01")
        )
        #expect(fires == false)
    }

    // MARK: - Cyclic on/off-weeks (v1.7.0 SB-SCHED-5)

    /// 3-on / 1-off anchored on 2026-06-01 (a Monday). Weeks are Sunday-rooted:
    /// the anchor week starts 2026-05-31 (Sun). On-weeks: indices 0,1,2 of each
    /// 4-week period → weeks of 05-31, 06-07, 06-14 fire; week of 06-21 (off);
    /// week of 06-28 fires again (period restart).
    @Test("cyclic 3-on/1-off: off-week is silent, on-weeks fire daily")
    func cyclicThreeOnOneOff() {
        // 09-14 — the anchor is no longer an associated value of the cadence.
        // The phase is counted from the context's `startsOn`, which is the same
        // 2026-06-01 this case always passed, so every expected day is unchanged.
        let slots = run(
            Self.entry(
                cadence: .cyclic(weeksOn: 3, weeksOff: 1),
                times: ["08:00"]
            ),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-28T23:59:59Z")
        )
        // 2026-06-01..06-20 are on-weeks (20 days), 06-21..06-27 off (silent),
        // 06-28 on again (1 day). Daily within on-weeks.
        let days = Set(slots.map { Self.berlinDay($0.at) })
        #expect(days.contains("2026-06-15")) // on-week
        #expect(!days.contains("2026-06-24")) // off-week — silent
        #expect(days.contains("2026-06-28")) // period restart, on-week
    }

    @Test("cyclic off-week firesOn is false, on-week is true")
    func cyclicFiresOn() {
        let entry = Self.entry(
            cadence: .cyclic(weeksOn: 3, weeksOff: 1),
            times: ["08:00"]
        )
        let ctx = Self.ctx(startsOn: "2026-06-01")
        #expect(MedicationRecurrenceEngine.firesOn(day: Self.courseDate("2026-06-15"), entry: entry, context: ctx))
        #expect(!MedicationRecurrenceEngine.firesOn(day: Self.courseDate("2026-06-24"), entry: entry, context: ctx))
    }

    @Test("cyclic nextOccurrence skips the off-week to the next on-week")
    func cyclicNextSkipsOffWeek() throws {
        // Ask for the next occurrence from inside the off-week (2026-06-24) —
        // it must land in the following on-week (period restart on 06-28).
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-24T12:00:00Z"),
            entry: Self.entry(
                cadence: .cyclic(weeksOn: 3, weeksOff: 1),
                times: ["08:00"]
            ),
            context: Self.ctx(startsOn: "2026-06-01")
        )
        #expect(next != nil)
        let day = try Self.berlinDay(#require(next?.at))
        // The first on-day after the off-week is 2026-06-28 (Sunday, period
        // restart) per Sunday-rooted weeks.
        #expect(day == "2026-06-28")
    }

    @Test("cyclic weeksOff == 0 is always-on (every day fires)")
    func cyclicAlwaysOn() {
        let slots = run(
            Self.entry(
                cadence: .cyclic(weeksOn: 2, weeksOff: 0),
                times: ["08:00"]
            ),
            Self.ctx(startsOn: "2026-06-01"),
            from: Self.courseDate("2026-06-01"),
            to: Self.iso("2026-06-14T23:59:59Z")
        )
        #expect(slots.count == 14)
    }

    // MARK: - nextDueAt override (v1.7.0 SB-SCHED-3)

    private static func ctxNextDue(
        _ iso: String,
        startsOn: String? = nil,
        endsOn: String? = nil,
        oneShot: Bool = false
    ) -> MedicationRecurrenceEngine.Context {
        MedicationRecurrenceEngine.Context(
            startsOn: startsOn.map { courseDate($0) },
            endsOn: endsOn.map { courseDate($0) },
            oneShot: oneShot,
            createdAt: Self.iso("2026-01-01T00:00:00Z"),
            lastIntakeAt: nil,
            timeZone: berlin,
            serverNextDueAt: Self.iso(iso)
        )
    }

    @Test("nextDueAt overrides the engine for a rolling cadence")
    func nextDueOverridesRolling() {
        // Local engine would put the next rolling slot at createdAt + 30 days;
        // the server says it's actually 2026-07-04T06:00Z — the override wins.
        let serverInstant = Self.iso("2026-07-04T06:00:00Z")
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T00:00:00Z"),
            entry: Self.entry(cadence: .rolling(intervalDays: 30), times: ["09:00"]),
            context: Self.ctxNextDue("2026-07-04T06:00:00Z", startsOn: "2026-06-01")
        )
        #expect(next?.at == serverInstant)
    }

    @Test("nextDueAt overrides the engine for a monthly cadence")
    func nextDueOverridesMonthly() {
        let serverInstant = Self.iso("2026-06-15T07:30:00Z")
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T00:00:00Z"),
            entry: Self.entry(cadence: .monthly(day: 15), times: ["09:00"]),
            context: Self.ctxNextDue("2026-06-15T07:30:00Z", startsOn: "2026-01-15")
        )
        #expect(next?.at == serverInstant)
    }

    @Test("nextDueAt in the past (<= after) falls back to the local engine")
    func nextDuePastFallsBack() throws {
        // Server nextDueAt is BEFORE `after` → ignore it, use the local grid.
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-20T00:00:00Z"),
            entry: Self.entry(cadence: .monthly(day: 15), times: ["09:00"]),
            context: Self.ctxNextDue("2026-06-15T07:30:00Z", startsOn: "2026-01-15")
        )
        // Local engine → next 15th after 06-20 is 07-15.
        #expect(next != nil)
        #expect(try Self.berlinDay(#require(next?.at)) == "2026-07-15")
    }

    @Test("nextDueAt does NOT override a recurring daily cadence")
    func nextDueIgnoredForDaily() throws {
        // Daily arms a recurring rule, not the fixed slot → the server instant
        // is NOT substituted; the local engine's next daily slot wins.
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T10:00:00Z"),
            entry: Self.entry(cadence: .daily, times: ["09:00"]),
            context: Self.ctxNextDue("2026-12-31T06:00:00Z", startsOn: "2026-06-01")
        )
        #expect(next != nil)
        // Next daily 09:00 Berlin after 2026-06-01 10:00 UTC is 2026-06-02.
        #expect(try Self.berlinDay(#require(next?.at)) == "2026-06-02")
    }

    @Test("nextDueAt past endsOn returns nil")
    func nextDueBeyondEndsOn() {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.iso("2026-06-01T00:00:00Z"),
            entry: Self.entry(cadence: .rolling(intervalDays: 30), times: ["09:00"]),
            context: Self.ctxNextDue(
                "2026-08-01T06:00:00Z",
                startsOn: "2026-06-01",
                endsOn: "2026-07-01"
            )
        )
        #expect(next == nil)
    }
}
