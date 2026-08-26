import Foundation
@testable import HealthLog
import Testing

/// **09-15 — the day boundary.**
///
/// 09-01 recorded that `MedicationDueNowRenderTests` fails near midnight and
/// left the interesting question open: is that only the test's construction, or
/// is the production due-state logic also wrong across a day boundary?
///
/// This suite answers it with the ordinary scenario rather than a contrived
/// one — a daily 23:00 dose whose row publishes an explicit three-hour on-time
/// window, `23:00–02:00`. `MedicationWindowStatus.resolveDoseBands` builds a
/// dose band three ways, and its legacy entry-level branch models exactly this
/// shape (`else if end < start { end += 24 * 60 }`), which is what the whole
/// `inYesterdayTail` machinery in `resolvedWindowStatus` exists to evaluate.
/// Its **explicit per-dose branch** did not: it accepted a published window
/// only `if minutes(start) <= minutes(end)` and otherwise fell through,
/// silently, to the ±60-minute default band around the dose time. So the
/// reducer graded a `23:00–02:00` window as `22:00–23:59` — while
/// `MedicationScheduleSection.doseWindowLines` printed the declared band
/// verbatim to the user.
///
/// Every instant here is injected. Nothing reads the live clock, so the suite
/// gives the same verdict at 23:55, at 00:35 and at any other minute.
@Suite("MedicationWindowStatus — day boundary")
struct MedicationWindowStatusMidnightTests {
    private let tz = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = tz
        return value
    }

    /// A wall-clock instant on the fixed reference Wednesday (2026-05-20)
    /// shifted by `dayOffset` days — the same fixture day the b179/b180 suites
    /// use, so a reader can compare vectors across all three.
    private func berlin(dayOffset: Int = 0, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 20 + dayOffset,
            hour: hour,
            minute: minute
        )) ?? .distantPast
    }

    /// A daily 23:00 dose with a declared `23:00–02:00` on-time window.
    ///
    /// `nextDueAt` is the un-served 23:00 slot itself, which is what the server
    /// publishes for a dose that is due and not yet taken (`W-B179 (b)` pins
    /// the same shape). It is therefore in the PAST at every post-slot vector
    /// below, so the b179/b183 future-due gate never fires and the verdicts
    /// here are the local band arithmetic's alone.
    private func overnightDose(todayEventCount: Int = 0) -> Medication {
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 23, minute: 0)],
            windowStart: TimeOfDay(hour: 23, minute: 0),
            windowEnd: TimeOfDay(hour: 2, minute: 0),
            doseWindows: [MedicationDoseWindowDTO(
                timeOfDay: "23:00",
                start: "23:00",
                end: "02:00"
            )]
        )
        return Medication(
            id: "med-09-15-overnight",
            name: "Testpräparat Nacht",
            dose: "1 Stk",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: todayEventCount,
            active: true,
            nextDueAt: berlin(hour: 23, minute: 0),
            nextDueOverdue: false
        )
    }

    /// The control fixture: the same shape with a window that does NOT cross
    /// midnight. Its verdicts must be identical before and after any change to
    /// the wrap rule, or the fix moved something it had no business moving.
    private func daytimeDose() -> Medication {
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0),
            windowEnd: TimeOfDay(hour: 10, minute: 0),
            doseWindows: [MedicationDoseWindowDTO(
                timeOfDay: "09:00",
                start: "09:00",
                end: "10:00"
            )]
        )
        return Medication(
            id: "med-09-15-daytime",
            name: "Testpräparat Tag",
            dose: "1 Stk",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(hour: 9, minute: 0),
            nextDueOverdue: false
        )
    }

    private func status(
        _ medication: Medication,
        dayOffset: Int = 0,
        hour: Int,
        minute: Int
    ) -> MedicationWindowStatus? {
        MedicationWindowStatus.reduce(
            medication: medication,
            now: berlin(dayOffset: dayOffset, hour: hour, minute: minute),
            timeZone: tz
        )
    }

    /// The declared band the row publishes, as the reducer resolves it.
    private func declaredBandSpanMinutes(_ medication: Medication) -> Int? {
        guard let entry = medication.schedule.entries.first,
              let band = MedicationWindowStatus.resolveDoseBands(entry).first else { return nil }
        return band.endMinutes - band.startMinutes
    }

    // MARK: - The accumulating clause

    @Test("a declared 23:00–02:00 window is graded across the day boundary")
    func midnightCrossingDoseWindowKeepsItsDeclaredBand() {
        let overnight = overnightDose()
        var violations: [String] = []

        // The band itself. A published 23:00–02:00 window spans 180 minutes;
        // the substituted ±60 anchor band around 23:00, clamped at 23:59,
        // spans 119.
        let span = declaredBandSpanMinutes(overnight)
        if span != 180 {
            violations.append(
                "declared 23:00–02:00 band spans \(span.map(String.init) ?? "nil") min, expected 180"
            )
        }

        // False negatives — the post-midnight half of the declared window.
        // A user taking a late medication at 00:35 sees no "Jetzt fällig".
        if status(overnight, dayOffset: 1, hour: 0, minute: 35) != .inWindow {
            violations.append("00:35, 85 min before the declared window closes: not inWindow")
        }
        if status(overnight, dayOffset: 1, hour: 1, minute: 59) != .inWindow {
            violations.append("01:59, one minute before the declared window closes: not inWindow")
        }

        // The overdue grading is shifted by the same substitution: 90 minutes
        // past a declared 02:00 close, un-served, is "Überfällig".
        if status(overnight, dayOffset: 1, hour: 3, minute: 30) != .late {
            violations.append("03:30, 90 min past the declared close, un-served: not late")
        }

        // False positive — the substituted band opens an hour early, so the
        // card paints green while the declared window is still shut.
        if status(overnight, hour: 22, minute: 15) != nil {
            violations.append("22:15, 45 min before the declared window opens: painted due-now")
        }

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: a dose window crossing midnight loses its declared band (\(violations))"
        )
    }

    // MARK: - Controls (must hold before AND after the fix)

    @Test("inside the declared window before midnight is still due-now")
    func beforeMidnightInsideTheWindowIsUnchanged() {
        #expect(status(overnightDose(), hour: 23, minute: 30) == .inWindow)
    }

    @Test("a window that does not cross midnight is untouched")
    func nonWrappingWindowIsUnchanged() {
        let daytime = daytimeDose()
        #expect(status(daytime, hour: 9, minute: 30) == .inWindow)
        #expect(status(daytime, hour: 8, minute: 30) == nil)
        #expect(declaredBandSpanMinutes(daytime) == 60)
    }

    @Test("an intake inside the overnight band still suppresses the prompt")
    func intakeInsideTheOvernightBandSuppresses() {
        // The coverage guard reads `lastTakenAt` in band minutes, so it has to
        // keep working once the band legitimately runs past midnight: a dose
        // taken at 23:10 must not be re-prompted at 23:30.
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 23, minute: 0)],
            windowStart: TimeOfDay(hour: 23, minute: 0),
            windowEnd: TimeOfDay(hour: 2, minute: 0),
            doseWindows: [MedicationDoseWindowDTO(
                timeOfDay: "23:00",
                start: "23:00",
                end: "02:00"
            )]
        )
        let medication = Medication(
            id: "med-09-15-overnight-taken",
            name: "Testpräparat Nacht",
            dose: "1 Stk",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: berlin(hour: 23, minute: 10),
            todayEventCount: 1,
            active: true,
            nextDueAt: berlin(hour: 23, minute: 0),
            nextDueOverdue: false
        )
        #expect(status(medication, hour: 23, minute: 30) == nil)
    }
}
