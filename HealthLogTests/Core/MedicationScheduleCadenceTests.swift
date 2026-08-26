import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **W42 (v0.11) — `MedicationSchedule.isWeeklyCadence` correctness.**
///
/// `isWeeklyCadence` gates the card + detail glyph-track render between the
/// daily strip and the weekly "X Dosistage" due-count surface. The predicate
/// must classify a schedule as weekly ONLY when it does NOT fire every
/// calendar day. A daily med — whether it carries `weekdays == nil` OR the
/// FULL 7-day weekday set (some server rows encode "every day" as
/// `daysOfWeek = "0,1,2,3,4,5,6"`) — fires daily and must read `false`.
///
/// Symptom A repro: a twice-daily Lisinopril whose `daysOfWeek` is the full
/// 7-day set was misclassified weekly, collapsing the Verlauf glyph track to
/// the degenerate due-count strip ("~3 Dosistage").
@Suite("MedicationSchedule — isWeeklyCadence")
struct MedicationScheduleCadenceTests {
    @Test("Daily med (no weekdays) is NOT weekly")
    func dailyNilWeekdaysIsNotWeekly() {
        let schedule = MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        #expect(schedule.weekdays == nil)
        #expect(!schedule.isWeeklyCadence)
    }

    @Test("Twice-daily med (no weekdays) is NOT weekly")
    func twiceDailyIsNotWeekly() {
        let schedule = MedicationSchedule(times: [
            TimeOfDay(hour: 8, minute: 0),
            TimeOfDay(hour: 20, minute: 0)
        ])
        #expect(!schedule.isWeeklyCadence)
    }

    @Test("Full 7-day weekday set is NOT weekly (fires every day)")
    func fullSevenWeekdaySetIsNotWeekly() throws {
        let allDays: Set<Weekday> = Set(Weekday.allCases)
        #expect(allDays.count == 7)
        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)],
            weekdays: allDays
        )
        // The flattened legacy surface keeps the full set, but the cadence is
        // daily — it fires every calendar day.
        #expect(!schedule.isWeeklyCadence)
        // Sanity: it really does fire on every weekday.
        let calendar = Calendar.current
        for offset in 0 ..< 7 {
            let day = try #require(calendar.date(byAdding: .day, value: offset, to: .now))
            #expect(schedule.fires(on: day, calendar: calendar))
        }
    }

    @Test("Weekday SUBSET (Mon/Wed/Fri) IS weekly")
    func weekdaySubsetIsWeekly() {
        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0)],
            weekdays: [.mon, .wed, .fri]
        )
        #expect(schedule.isWeeklyCadence)
    }

    @Test("Single-weekday (Wednesday) IS weekly")
    func singleWeekdayIsWeekly() {
        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0)],
            weekdays: [.wed]
        )
        #expect(schedule.isWeeklyCadence)
    }

    @Test("Multi-week interval (every 2 weeks, no weekday filter) IS weekly")
    func intervalWeeklyIsWeekly() {
        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0)],
            weekdays: nil,
            intervalWeeks: 2
        )
        #expect(schedule.isWeeklyCadence)
    }

    @Test("Multi-week interval with a full 7-day set still reads weekly (interval drives it)")
    func intervalWithFullSetIsWeekly() {
        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0)],
            weekdays: Set(Weekday.allCases),
            intervalWeeks: 2
        )
        #expect(schedule.isWeeklyCadence)
    }

    @Test("Full 7-day set decoded from the wire (daysOfWeek=0..6) is NOT weekly")
    func fullSetFromWireIsNotWeekly() {
        // Mirror the read-path: a server schedule row with daysOfWeek covering
        // every day flattens through ScheduleEntry → MedicationSchedule.
        let dto = MedicationScheduleDTO(
            windowStart: "08:00",
            daysOfWeek: "0,1,2,3,4,5,6",
            timesOfDay: ["08:00", "20:00"]
        )
        let entry = ScheduleEntry.fromDTO(dto, oneShot: false)
        let schedule = MedicationSchedule(entries: [entry])
        #expect(schedule.weekdays?.count == 7)
        #expect(!schedule.isWeeklyCadence)
    }
}
