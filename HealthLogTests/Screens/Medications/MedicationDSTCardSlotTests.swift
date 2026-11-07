import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **MED (e), #151 — the medication card on the day the clocks change.**
///
/// Server report (v1.4.1-b299 against 1.46.0 RC, 2026-10-25, Europe/Berlin):
/// the web had already marked today's 20:00 dose, and "Taken" on the card
/// re-stamped YESTERDAY's row. The server picked today's slot for every replayed
/// request, so the app sent yesterday's dose.
///
/// Finding: the card resolves today's rows correctly (calendar bounds, profile
/// zone, the 25-hour day included) and shows "Taken" when the today list holds
/// the web's mark. When that list lacks the row (the old server ended the
/// 25-hour day's list early) the tap falls through to the ad-hoc path, whose
/// 60-day look-back picked the latest slot at or before now. Tapped before
/// tonight's 20:00 that is yesterday's 20:00. The ad-hoc path now sends
/// today's slot when the medication doses today, and looks back only when it
/// does not (a weekly med on an off-day, H3).
///
/// Every case runs for the autumn change (2026-10-25), the spring change
/// (2026-03-29) and a zone without changes (Asia/Tokyo), each with a daily
/// 20:00 medication.
@Suite("MED — card slot on the DST change day (e)")
struct MedicationDSTCardSlotTests {
    struct Day: Sendable, CustomTestStringConvertible {
        let zone: String
        let year: Int, month: Int, day: Int
        var testDescription: String {
            "\(zone) \(year)-\(month)-\(day)"
        }

        var timeZone: TimeZone {
            TimeZone(identifier: zone)!
        }

        var calendar: Calendar {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            return cal
        }

        func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day + dayOffset, hour: hour, minute: minute))!
        }
    }

    static let days: [Day] = [
        Day(zone: "Europe/Berlin", year: 2026, month: 10, day: 25),
        Day(zone: "Europe/Berlin", year: 2026, month: 3, day: 29),
        Day(zone: "Asia/Tokyo", year: 2026, month: 10, day: 25),
        Day(zone: "Asia/Tokyo", year: 2026, month: 3, day: 29)
    ]

    static func dailyEvening(_ day: Day) -> Medication {
        Medication(
            id: "med-lisinopril",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 20, minute: 0)]),
            createdAt: day.at(9, dayOffset: -40)
        )
    }

    @Test("Fixture pins the change: Berlin 25.10. has 25 hours, 29.03. has 23, Tokyo 24", arguments: days)
    func fixtureLengths(_ day: Day) throws {
        let start = day.calendar.startOfDay(for: day.at(12))
        let end = try #require(day.calendar.date(byAdding: .day, value: 1, to: start))
        let hours = end.timeIntervalSince(start) / 3600
        switch (day.zone, day.month) {
        case ("Europe/Berlin", 10): #expect(hours == 25)
        case ("Europe/Berlin", 3): #expect(hours == 23)
        default: #expect(hours == 24)
        }
        // Today's 20:00 is a real local 20:00 on the change day.
        #expect(day.calendar.component(.hour, from: day.at(20)) == 20)
    }

    @Test("Web already took today's 20:00: the card says Taken, with and without synthesis", arguments: days)
    func webTakenShowsTaken(_ day: Day) {
        let med = Self.dailyEvening(day)
        let now = day.at(20, 30)
        let webTaken = MedicationIntake(
            id: "srv-today",
            medicationId: med.id,
            scheduledAt: day.at(20),
            takenAt: day.at(19, 50),
            status: .taken
        )
        // Slot-materialising server: the store trusts the today rows (gate off).
        let trusted = [webTaken].filter {
            $0.scheduledAt >= day.calendar.startOfDay(for: now)
                && $0.scheduledAt < day.calendar.date(byAdding: .day, value: 1, to: day.calendar.startOfDay(for: now))!
        }
        #expect(MedicationQuickMarkState.resolve(medicationId: med.id, todayIntakes: trusted, now: now) == .takenToday)
        // Older server: synthesis on, no shadow placeholder next to the taken row.
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [webTaken],
            medications: [med],
            now: now,
            calendar: day.calendar
        )
        #expect(derived.map(\.id) == ["srv-today"])
        #expect(MedicationQuickMarkState.resolve(medicationId: med.id, todayIntakes: derived, now: now) == .takenToday)
        #expect(ActiveMedicationsSection.resolveDispatchDose(medicationId: med.id, todayIntakes: derived, now: now) == nil)
    }

    @Test("Today list lost the row, tapped before 20:00: the app sends today's 20:00, never yesterday's", arguments: days)
    func adHocBeforeEveningSendsToday(_ day: Day) {
        let med = Self.dailyEvening(day)
        let resolved = ActiveMedicationsSection.resolveAdHocScheduledFor(
            medication: med,
            now: day.at(19, 30),
            timeZone: day.timeZone
        )
        #expect(resolved == day.at(20))
        #expect(resolved != day.at(20, dayOffset: -1))
    }

    @Test("Today list lost the row, tapped after 20:00: today's 20:00", arguments: days)
    func adHocAfterEveningSendsToday(_ day: Day) {
        let med = Self.dailyEvening(day)
        let resolved = ActiveMedicationsSection.resolveAdHocScheduledFor(
            medication: med,
            now: day.at(21, 15),
            timeZone: day.timeZone
        )
        #expect(resolved == day.at(20))
    }

    @Test("The synthesised 20:00 slot on the change day is the real local 20:00", arguments: days)
    func synthesisedSlotIsLocalEvening(_ day: Day) {
        let med = Self.dailyEvening(day)
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: day.at(19, 30),
            calendar: day.calendar
        )
        #expect(derived.map(\.scheduledAt) == [day.at(20)])
        let pick = ActiveMedicationsSection.resolveDispatchDose(medicationId: med.id, todayIntakes: derived, now: day.at(19, 30))
        #expect(pick?.scheduledAt == day.at(20))
    }

    @Test("A weekly medication on an off-day still looks back to its last slot (H3 kept)")
    func weeklyOffDayStillLooksBack() {
        let day = Self.days[0]
        let entry = ScheduleEntry(
            cadence: .weekdays([.mon]),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        let med = Medication(
            id: "weekly",
            name: "Trulicity",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            createdAt: day.at(9, dayOffset: -60)
        )
        // 25.10.2026 is a Sunday; the last Monday 09:00 is 19.10.
        let resolved = ActiveMedicationsSection.resolveAdHocScheduledFor(
            medication: med,
            now: day.at(14),
            timeZone: day.timeZone
        )
        #expect(resolved == day.at(9, dayOffset: -6))
    }
}

// swiftlint:enable force_unwrapping
