import Foundation
@testable import HealthLog
import Testing

@Suite("MedicationWindowStatus — per-dose server parity")
struct MedicationWindowStatusPerDoseParityTests {
    private let tz = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = tz
        return value
    }

    private func berlin(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 20,
            hour: hour,
            minute: minute
        )) ?? .distantPast
    }

    private func twiceDaily(
        lastTakenAt: Date? = nil,
        todayEventCount: Int = 0,
        nextDueAt: Date? = nil,
        windowStart: TimeOfDay = TimeOfDay(hour: 9, minute: 0),
        windowEnd: TimeOfDay? = TimeOfDay(hour: 10, minute: 0),
        doseWindows: [MedicationDoseWindowDTO]? = nil
    ) -> Medication {
        Medication(
            id: "med-lisinopril-per-dose",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(
                cadence: .daily,
                timesOfDay: [
                    TimeOfDay(hour: 9, minute: 0),
                    TimeOfDay(hour: 21, minute: 0)
                ],
                windowStart: windowStart,
                windowEnd: windowEnd,
                doseWindows: doseWindows
            )]),
            lastTakenAt: lastTakenAt,
            todayEventCount: todayEventCount,
            active: true,
            nextDueAt: nextDueAt,
            nextDueOverdue: false
        )
    }

    @Test("08:59 morning take suppresses 09:00 prompt while server next due is 21:00")
    func earlyMorningTakeSuppressesCoveredBand() {
        let medication = twiceDaily(
            lastTakenAt: berlin(hour: 8, minute: 59),
            todayEventCount: 1,
            nextDueAt: berlin(hour: 21, minute: 0),
            doseWindows: [
                MedicationDoseWindowDTO(timeOfDay: "09:00", start: "09:00", end: "10:00"),
                MedicationDoseWindowDTO(timeOfDay: "21:00", start: "21:00", end: "22:00")
            ]
        )

        #expect(MedicationWindowStatus.reduce(
            medication: medication,
            now: berlin(hour: 9, minute: 10),
            timeZone: tz
        ) == nil)
    }

    @Test("timesOfDay bands ignore stale legacy 07:00 point window")
    func firstClassDoseTimesBeatStaleLegacyWindow() {
        let seven = TimeOfDay(hour: 7, minute: 0)
        let medication = twiceDaily(
            nextDueAt: berlin(hour: 21, minute: 0),
            windowStart: seven,
            windowEnd: seven
        )

        #expect(MedicationWindowStatus.reduce(
            medication: medication,
            now: berlin(hour: 7, minute: 10),
            timeZone: tz
        ) == nil)
    }

    @Test("real evening dose band becomes due when its window opens")
    func eveningBandStillBecomesActionable() {
        let medication = twiceDaily(
            lastTakenAt: berlin(hour: 8, minute: 59),
            todayEventCount: 1,
            nextDueAt: berlin(hour: 21, minute: 0)
        )

        #expect(MedicationWindowStatus.reduce(
            medication: medication,
            now: berlin(hour: 20, minute: 30),
            timeZone: tz
        ) == .inWindow)
    }
}
