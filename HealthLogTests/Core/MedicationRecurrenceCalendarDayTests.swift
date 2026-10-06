import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **R1 — `startsOn` / `endsOn` are calendar days (server 1.39.3, A1 on #115).**
///
/// Ported from the server's own fixture file
/// `src/lib/medications/scheduling/__tests__/recurrence-timezones.test.ts` at
/// tag `v1.39.3` (commit `8a03654e8`): same schedules, same course dates (UTC
/// midnight, the way a `@db.Date` column arrives), same expected local days and
/// times, run over the zones the app has to agree with the server in. Every
/// assertion is read back on the user's wall clock.
///
/// Before the fix the engine floored the UTC midnight of `startsOn` in the
/// profile zone (the evening before, west of UTC), capped `endsOn` at the end
/// of the UTC day (the local afternoon), counted cyclic weeks from Sunday and
/// added N × 24 h to a rolling intake instant.
@Suite("MedicationRecurrenceEngine — calendar days across zones (server 1.39.3 parity)")
struct MedicationRecurrenceCalendarDayTests {
    static let zones = [
        "America/New_York",
        "America/Los_Angeles",
        "Pacific/Honolulu",
        "Europe/Berlin",
        "Asia/Tokyo",
        "Pacific/Kiritimati",
        "UTC"
    ]

    // MARK: - Fixture helpers (mirroring the server test's)

    static func tz(_ id: String) -> TimeZone {
        TimeZone(identifier: id)!
    }

    /// A calendar date the way the server hands back a `@db.Date` column.
    static func date(_ ymd: String) -> Date {
        ISO8601DateFormatter().date(from: "\(ymd)T00:00:00Z")!
    }

    static func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz(zone)
        return calendar
    }

    static func localYmd(_ at: Date, _ zone: String) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: at)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func localHm(_ at: Date, _ zone: String) -> String {
        let c = calendar(zone).dateComponents([.hour, .minute], from: at)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    static func weekday(_ at: Date, _ zone: String) -> Int {
        calendar(zone).component(.weekday, from: at) - 1
    }

    /// A local wall clock solved to an instant without the engine under test.
    static func zoned(_ zone: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    static func entry(_ cadence: Cadence, _ times: [String] = ["09:00"]) -> ScheduleEntry {
        ScheduleEntry(
            cadence: cadence,
            timesOfDay: times.compactMap { TimeOfDay.parse($0) },
            reminderGraceMinutes: nil,
            windowStart: TimeOfDay(hour: 9, minute: 0),
            windowEnd: TimeOfDay(hour: 10, minute: 0)
        )
    }

    static func context(
        _ zone: String,
        startsOn: String? = nil,
        endsOn: String? = nil,
        oneShot: Bool = false,
        lastIntakeAt: Date? = nil,
        serverNextDueAt: Date? = nil
    ) -> MedicationRecurrenceEngine.Context {
        MedicationRecurrenceEngine.Context(
            startsOn: startsOn.map(date),
            endsOn: endsOn.map(date),
            oneShot: oneShot,
            createdAt: instant("2026-01-01T12:00:00Z"),
            lastIntakeAt: lastIntakeAt,
            timeZone: tz(zone),
            serverNextDueAt: serverNextDueAt
        )
    }

    static let wideFrom = instant("2026-07-25T00:00:00Z")
    static let wideTo = instant("2026-12-31T00:00:00Z")

    static func slots(
        _ entry: ScheduleEntry,
        _ context: MedicationRecurrenceEngine.Context,
        from: Date = wideFrom,
        to: Date = wideTo
    ) -> [MedicationRecurrenceEngine.Occurrence] {
        MedicationRecurrenceEngine.occurrences(in: from ... to, entry: entry, context: context)
    }

    // MARK: - The server matrix

    @Test("FREQ=WEEKLY;BYDAY=MO fires on local Mondays at the local time", arguments: zones)
    func weeklyMonday(zone: String) {
        let slots = Self.slots(Self.entry(.weekdays([.mon])), Self.context(zone, startsOn: "2026-09-01"))
        #expect(slots.count > 10)
        for slot in slots {
            #expect(Self.weekday(slot.at, zone) == 1)
            #expect(Self.localHm(slot.at, zone) == "09:00")
        }
        #expect(Self.localYmd(slots[0].at, zone) == "2026-09-07")
    }

    @Test("FREQ=DAILY starts on startsOn, never the day before", arguments: zones)
    func dailyStartsOnStartDay(zone: String) {
        let slots = Self.slots(
            Self.entry(.daily, ["00:30", "23:30"]),
            Self.context(zone, startsOn: "2026-09-14"),
            to: Self.instant("2026-09-20T00:00:00Z")
        )
        #expect(Self.localYmd(slots[0].at, zone) == "2026-09-14")
        #expect(Self.localHm(slots[0].at, zone) == "00:30")
        let days = slots.map { Self.localYmd($0.at, zone) }
        for day in ["2026-09-14", "2026-09-15", "2026-09-16"] {
            #expect(days.filter { $0 == day }.count == 2, "\(day) in \(zone)")
        }
        #expect(days.allSatisfy { $0 >= "2026-09-14" })
    }

    @Test("FREQ=DAILY keeps the evening dose of the last course day", arguments: zones)
    func dailyKeepsLastEvening(zone: String) throws {
        let entry = Self.entry(.daily, ["08:00", "23:00"])
        let context = Self.context(zone, startsOn: "2026-09-14", endsOn: "2026-09-16")
        let slots = Self.slots(entry, context)
        #expect(slots.map { "\(Self.localYmd($0.at, zone)) \(Self.localHm($0.at, zone))" } == [
            "2026-09-14 08:00", "2026-09-14 23:00",
            "2026-09-15 08:00", "2026-09-15 23:00",
            "2026-09-16 08:00", "2026-09-16 23:00"
        ])
        // The next-due walk reaches the same last dose, and nothing after it.
        try #require(slots.count == 6)
        let next = MedicationRecurrenceEngine.nextOccurrence(after: slots[4].at, entry: entry, context: context)
        #expect(next?.at == slots[5].at)
        #expect(MedicationRecurrenceEngine.nextOccurrence(after: slots[5].at, entry: entry, context: context) == nil)
    }

    @Test("FREQ=MONTHLY;BYMONTHDAY=1 lands on the first of the local month", arguments: zones)
    func monthlyFirst(zone: String) {
        let slots = Self.slots(Self.entry(.monthly(day: 1)), Self.context(zone, startsOn: "2026-08-01"))
        #expect(slots.map { Self.localYmd($0.at, zone) } == [
            "2026-08-01", "2026-09-01", "2026-10-01", "2026-11-01", "2026-12-01"
        ])
    }

    @Test("legacy every-other-Monday honours startsOn and the week phase", arguments: zones)
    func legacyEveryOtherMonday(zone: String) {
        let slots = Self.slots(
            Self.entry(.legacy(days: [.mon], intervalWeeks: 2)),
            Self.context(zone, startsOn: "2026-09-14"),
            to: Self.instant("2026-10-31T00:00:00Z")
        )
        #expect(slots.map { Self.localYmd($0.at, zone) } == ["2026-09-14", "2026-09-28", "2026-10-12", "2026-10-26"])
    }

    @Test("legacy daily walk stops after the evening dose of endsOn", arguments: zones)
    func legacyDailyEndsOn(zone: String) {
        let slots = Self.slots(
            Self.entry(.legacy(days: nil, intervalWeeks: 1), ["21:00"]),
            Self.context(zone, startsOn: "2026-09-14", endsOn: "2026-09-15")
        )
        #expect(slots.map { Self.localYmd($0.at, zone) } == ["2026-09-14", "2026-09-15"])
    }

    @Test("a one-shot dose lands on its own date", arguments: zones)
    func oneShotOwnDate(zone: String) {
        let slots = Self.slots(
            Self.entry(.oneShot, ["08:00"]),
            Self.context(zone, startsOn: "2026-09-14", endsOn: "2026-09-14", oneShot: true)
        )
        #expect(slots.map { "\(Self.localYmd($0.at, zone)) \(Self.localHm($0.at, zone))" } == ["2026-09-14 08:00"])
    }

    @Test("a rolling first dose is due on startsOn", arguments: zones)
    func rollingFirstDose(zone: String) {
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.instant("2026-09-01T12:00:00Z"),
            entry: Self.entry(.rolling(intervalDays: 7)),
            context: Self.context(zone, startsOn: "2026-09-14")
        )
        #expect(next.map { Self.localYmd($0.at, zone) } == "2026-09-14")
        #expect(next.map { Self.localHm($0.at, zone) } == "09:00")
    }

    @Test("a rolling cadence counts calendar days from a late-evening intake", arguments: zones)
    func rollingLateEvening(zone: String) {
        // 23:30 local on 2026-10-30; +7 calendar days crosses the northern
        // fall-back weekend.
        let intake = Self.zoned(zone, 2026, 10, 30, 23, 30)
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: intake,
            entry: Self.entry(.rolling(intervalDays: 7)),
            context: Self.context(zone, startsOn: "2026-09-14", lastIntakeAt: intake)
        )
        #expect(next.map { Self.localYmd($0.at, zone) } == "2026-11-06")
    }

    @Test("CYCLIC 3 on / 1 off counts whole weeks from startsOn in the local calendar", arguments: zones)
    func cyclicFromStartDay(zone: String) {
        // Starts on a Wednesday; the three "on" weeks are 21 consecutive days.
        let slots = Self.slots(
            Self.entry(.cyclic(weeksOn: 3, weeksOff: 1), ["23:30"]),
            Self.context(zone, startsOn: "2026-09-16"),
            to: Self.instant("2026-11-10T00:00:00Z")
        )
        let days = slots.map { Self.localYmd($0.at, zone) }
        #expect(days.first == "2026-09-16")
        #expect(days.contains("2026-10-06"))
        #expect(!days.contains("2026-10-07"))
        #expect(!days.contains("2026-10-13"))
        #expect(days.contains("2026-10-14"))
        #expect(days.filter { $0 < "2026-10-14" }.count == 21)
    }

    // MARK: - DST transition days

    struct DSTCase {
        let zone: String
        let spring: String
        let fall: String
    }

    static let dstCases = [
        DSTCase(zone: "America/New_York", spring: "2026-03-08", fall: "2026-11-01"),
        DSTCase(zone: "America/Los_Angeles", spring: "2026-03-08", fall: "2026-11-01"),
        DSTCase(zone: "Europe/Berlin", spring: "2026-03-29", fall: "2026-10-25")
    ]

    @Test("one dose per local time across both DST days", arguments: dstCases.map(\.zone))
    func dstDaysKeepEveryDose(zone: String) throws {
        let dst = try #require(Self.dstCases.first { $0.zone == zone })
        for day in [dst.spring, dst.fall] {
            let start = Self.date(day)
            let slots = Self.slots(
                Self.entry(.daily, ["00:30", "08:00", "23:30"]),
                Self.context(zone, startsOn: "2026-01-01"),
                from: start.addingTimeInterval(-3 * 86400),
                to: start.addingTimeInterval(3 * 86400)
            )
            let onDay = slots.filter { Self.localYmd($0.at, zone) == day }
            #expect(onDay.count == 3, "\(zone) \(day)")
            guard onDay.count == 3 else { continue }
            #expect(Self.localHm(onDay[1].at, zone) == "08:00")
            #expect(Self.localHm(onDay[2].at, zone) == "23:30")
        }
    }

    @Test("a rolling cadence across the spring-forward day keeps calendar days", arguments: dstCases.map(\.zone))
    func rollingAcrossSpringForward(zone: String) throws {
        let dst = try #require(Self.dstCases.first { $0.zone == zone })
        let parts = dst.spring.split(separator: "-").compactMap { Int($0) }
        // 23:30 local three days before the clocks go forward; 7 × 24 h later
        // is 00:30 on the day after the due day.
        let intake = Self.zoned(zone, parts[0], parts[1], parts[2] - 3, 23, 30)
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: intake,
            entry: Self.entry(.rolling(intervalDays: 7)),
            context: Self.context(zone, startsOn: "2026-01-01", lastIntakeAt: intake)
        )
        let due = Self.date(dst.spring).addingTimeInterval(4 * 86400)
        #expect(next.map { Self.localYmd($0.at, zone) } == Self.localYmd(due, "UTC"))
    }

    // MARK: - Beyond the five A1 points: rrule.js expansion rules

    /// `FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,WE` from a Wednesday, expanded by the
    /// server's rrule.js 2.x (`WKST` defaults to Monday). Reference output from
    /// the server's own `node_modules/rrule`:
    /// `2026-09-16, 09-20, 09-30, 10-04, 10-14, 10-18`. The Sunday belongs to
    /// the Monday-rooted week of the Wednesday before it.
    @Test("every-2-weeks Sun+Wed counts Monday-rooted weeks like rrule.js", arguments: zones)
    func everyTwoWeeksMondayRooted(zone: String) {
        let slots = Self.slots(
            Self.entry(.everyNWeeks(interval: 2, days: [.sun, .wed])),
            Self.context(zone, startsOn: "2026-09-16"),
            to: Self.instant("2026-10-20T00:00:00Z")
        )
        #expect(slots.map { Self.localYmd($0.at, zone) } == [
            "2026-09-16", "2026-09-20", "2026-09-30", "2026-10-04", "2026-10-14", "2026-10-18"
        ])
    }

    /// `FREQ=MONTHLY;BYMONTHDAY=31` from 2026-06-01, rrule.js reference:
    /// `2026-07-31, 2026-08-31` — a month without the day is skipped.
    @Test("BYMONTHDAY=31 skips the short months like rrule.js", arguments: zones)
    func monthDay31Skips(zone: String) {
        let slots = Self.slots(
            Self.entry(.monthly(day: 31)),
            Self.context(zone, startsOn: "2026-06-01"),
            from: Self.instant("2026-06-01T00:00:00Z"),
            to: Self.instant("2026-10-20T00:00:00Z")
        )
        #expect(slots.map { Self.localYmd($0.at, zone) } == ["2026-07-31", "2026-08-31"])
    }

    // MARK: - The server's nextDueAt and the course end

    @Test("a server nextDueAt on the evening of endsOn is kept west of UTC", arguments: zones)
    func serverNextDueOnLastEvening(zone: String) {
        let evening = Self.zoned(zone, 2026, 9, 16, 21, 0)
        let next = MedicationRecurrenceEngine.nextOccurrence(
            after: Self.zoned(zone, 2026, 9, 16, 8, 0),
            entry: Self.entry(.rolling(intervalDays: 2), ["21:00"]),
            context: Self.context(zone, startsOn: "2026-09-10", endsOn: "2026-09-16", serverNextDueAt: evening)
        )
        #expect(next?.at == evening)
    }

    @Test("the course bounds are the local start of startsOn and the local end of endsOn", arguments: zones)
    func courseBounds(zone: String) throws {
        let context = Self.context(zone, startsOn: "2026-09-14", endsOn: "2026-09-16")
        let start = try #require(MedicationRecurrenceEngine.startOfCourse(context))
        let end = try #require(MedicationRecurrenceEngine.endOfCourse(context))
        #expect(Self.localYmd(start, zone) == "2026-09-14")
        #expect(Self.localHm(start, zone) == "00:00")
        #expect(Self.localYmd(end, zone) == "2026-09-16")
        #expect(Self.localHm(end, zone) == "23:59")
    }
}
