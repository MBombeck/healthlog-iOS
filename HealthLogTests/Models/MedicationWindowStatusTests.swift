import Foundation
@testable import HealthLog
import Testing

/// **v0.10.0 Walkthrough-1 B11.** Verifies the display-only current-window
/// dose status helper that drives the "Jetzt fällig / Überfällig" pill on the
/// medication card — the iOS port of the web's
/// `reduceCurrentWindowStatus` (`src/lib/medications/window-status.ts`).
///
/// Vectors mirror the web rule: in-window → `inWindow`; +90 min past a 1-h
/// window (uncovered) → `late`; +200 min (uncovered) → `veryLate`; +90 min
/// but covered by today's intake → `nil`; +300 min (past `missedMinutes`) →
/// `nil`. Thresholds = web defaults (late 120 / missed 240).
@Suite("MedicationWindowStatus.reduce — B11")
struct MedicationWindowStatusTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return cal
    }

    private let tz = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    /// A fixed reference day at the given wall-clock time in Berlin.
    private func berlin(hour: Int, minute: Int) -> Date {
        // 2026-05-20 is a Wednesday — irrelevant for daily cadence vectors.
        var c = DateComponents()
        c.year = 2026
        c.month = 5
        c.day = 20
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c) ?? .distantPast
    }

    /// Daily medication with a single `[19:00, 20:00]` window (1-h grace).
    private func med(
        windowStart: TimeOfDay = TimeOfDay(hour: 19, minute: 0),
        windowEnd: TimeOfDay? = TimeOfDay(hour: 20, minute: 0),
        active: Bool = true,
        lastTakenAt: Date? = nil,
        todayEventCount: Int = 0
    ) -> Medication {
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [windowStart],
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        return Medication(
            id: "med-B11",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTakenAt,
            todayEventCount: todayEventCount,
            active: active
        )
    }

    @Test("in-window → inWindow")
    func inWindow() {
        let now = berlin(hour: 19, minute: 10) // 10 min into [19:00,20:00]
        let status = MedicationWindowStatus.reduce(
            medication: med(), now: now, timeZone: tz
        )
        #expect(status == .inWindow)
    }

    @Test("+90 min past window end, uncovered → late")
    func lateUncovered() {
        // Window ends 20:00; 21:30 = 90 min past, ≤ 120 lateMinutes.
        let now = berlin(hour: 21, minute: 30)
        let status = MedicationWindowStatus.reduce(
            medication: med(todayEventCount: 0), now: now, timeZone: tz
        )
        #expect(status == .late)
    }

    @Test("+200 min past window end, uncovered → veryLate")
    func veryLateUncovered() {
        // Window ends 20:00; 23:20 = 200 min past, > 120 & ≤ 240.
        let now = berlin(hour: 23, minute: 20)
        let status = MedicationWindowStatus.reduce(
            medication: med(todayEventCount: 0), now: now, timeZone: tz
        )
        #expect(status == .veryLate)
    }

    @Test("+90 min past window end but covered by intake → nil")
    func lateButCovered() {
        let now = berlin(hour: 21, minute: 30)
        // One passed schedule, one of today's intakes covers it.
        let status = MedicationWindowStatus.reduce(
            medication: med(todayEventCount: 1), now: now, timeZone: tz
        )
        #expect(status == nil)
    }

    @Test("+300 min past window end (beyond missedMinutes) → nil")
    func beyondMissed() {
        // Window ends 20:00; +300 min = 01:00 next day. Use same-day proxy
        // by evaluating at 23:59 + a +300 vector is past midnight, so assert
        // the bound directly: 300 min > 240 missedMinutes → nil even at the
        // last same-day minute past the threshold.
        let now = berlin(hour: 23, minute: 59) // 239 min past — still veryLate
        #expect(
            MedicationWindowStatus.reduce(medication: med(), now: now, timeZone: tz)
                == .veryLate
        )
        // One minute later crosses 240 → nil (next-dose line takes over).
        let past = berlin(hour: 23, minute: 59).addingTimeInterval(120) // 241 min past
        #expect(
            MedicationWindowStatus.reduce(medication: med(), now: past, timeZone: tz) == nil
        )
    }

    @Test("inactive medication → nil")
    func inactive() {
        let now = berlin(hour: 19, minute: 10)
        let status = MedicationWindowStatus.reduce(
            medication: med(active: false), now: now, timeZone: tz
        )
        #expect(status == nil)
    }

    @Test("in-window but last intake already inside window → nil")
    func inWindowAlreadyTaken() {
        let now = berlin(hour: 19, minute: 30)
        let taken = berlin(hour: 19, minute: 5) // inside [19:00,20:00] today
        let status = MedicationWindowStatus.reduce(
            medication: med(lastTakenAt: taken, todayEventCount: 1),
            now: now,
            timeZone: tz
        )
        #expect(status == nil)
    }

    @Test("no explicit windowEnd → 60-min grace fallback")
    func graceFallback() {
        // windowStart 19:00, no end → engine grace fallback = 60 min → 20:00.
        // 21:30 = 90 min past the derived end → late.
        let now = berlin(hour: 21, minute: 30)
        let status = MedicationWindowStatus.reduce(
            medication: med(windowEnd: nil), now: now, timeZone: tz
        )
        #expect(status == .late)
    }

    // MARK: - W-MEDVERIFY (v0.14.8) — weekday gate on the per-entry window

    /// Sunday-only weekly med (demo Trulicity: `FREQ=WEEKLY;BYDAY=SU`,
    /// window 08:00–10:00). 2026-05-20 is a Wednesday.
    private func weeklySundayMed(
        lastTakenAt: Date? = nil,
        todayEventCount: Int = 0
    ) -> Medication {
        let entry = ScheduleEntry(
            cadence: .everyNWeeks(interval: 1, days: [.sun]),
            timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
            windowStart: TimeOfDay(hour: 8, minute: 0),
            windowEnd: TimeOfDay(hour: 10, minute: 0)
        )
        return Medication(
            id: "med-trulicity",
            name: "Trulicity",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTakenAt,
            todayEventCount: todayEventCount,
            active: true
        )
    }

    @Test("W-MEDVERIFY — Sunday-only weekly med is NOT 'Jetzt fällig' on a Wednesday morning")
    func weeklyOffDayNeverInWindow() {
        // Demo-walkthrough regression: 09:36 on a Friday/Wednesday sat inside
        // the 08:00–10:00 wall-clock window, so the ungated per-entry check
        // painted ".inWindow" → "Jetzt fällig" every single morning while the
        // server graded the dose `upcoming` (next Sunday).
        let now = berlin(hour: 9, minute: 36) // Wednesday, inside 08:00–10:00
        let status = MedicationWindowStatus.reduce(
            medication: weeklySundayMed(), now: now, timeZone: tz
        )
        #expect(status == nil)
    }

    @Test("W-MEDVERIFY — same med on its scheduled Sunday → inWindow")
    func weeklyOnDayInWindow() {
        // 2026-05-24 is a Sunday.
        var c = DateComponents()
        c.year = 2026
        c.month = 5
        c.day = 24
        c.hour = 9
        c.minute = 0
        let now = calendar.date(from: c) ?? .distantPast
        let status = MedicationWindowStatus.reduce(
            medication: weeklySundayMed(), now: now, timeZone: tz
        )
        #expect(status == .inWindow)
    }

    // MARK: - W-B179 — "Jetzt fällig" must NOT fire before the window start

    /// A wall-clock instant on the fixed reference Wednesday (2026-05-20)
    /// shifted by `dayOffset` days. Used for the overnight-tail vectors.
    private func berlin(dayOffset: Int, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 5
        c.day = 20 + dayOffset
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c) ?? .distantPast
    }

    /// b179 operator regression: weekly med firing TODAY at 21:00 whose
    /// stored window is zero-length (`windowStart == windowEnd == 21:00`).
    /// The zero-span wire shape made `effectiveWindowEndMinutes` read the
    /// window as wrapping a full 24 h past midnight, so the overnight-tail
    /// arithmetic painted ".inWindow" → green "Jetzt fällig" ALL morning
    /// while the web correctly read "Today, 21:00" off `nextDueAt`.
    @Test("W-B179 (a) — dose due today 21:00, now 10:30 → NOT 'Jetzt fällig'")
    func futureDueTodayIsNotInWindow() {
        let ninePM = TimeOfDay(hour: 21, minute: 0)
        let entry = ScheduleEntry(
            cadence: .everyNWeeks(interval: 1, days: [.wed]), // fires today (Wed)
            timesOfDay: [ninePM],
            windowStart: ninePM,
            windowEnd: ninePM // zero-length window — degenerate wire shape
        )
        let medication = Medication(
            id: "med-b179-a",
            name: "Trulicity",
            dose: "7,5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(hour: 21, minute: 0) // server: today, 21:00
        )
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(hour: 10, minute: 30), timeZone: tz
        )
        #expect(status == nil)
    }

    /// Same SOLL via the server-authority gate alone: a rolling med whose
    /// multi-day catch-up grace (`reminderGraceMinutes`) spans past midnight
    /// must not read ".inWindow" before today's 21:00 start when the server
    /// says the next dose is still upcoming.
    @Test("W-B179 (a') — rolling med with multi-day grace, due tonight → NOT 'Jetzt fällig' at 10:30")
    func rollingLargeGraceFutureDueIsNotInWindow() {
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 7),
            timesOfDay: [TimeOfDay(hour: 21, minute: 0)],
            reminderGraceMinutes: 2 * 24 * 60, // 2-day catch-up band
            windowStart: TimeOfDay(hour: 21, minute: 0)
        )
        let medication = Medication(
            id: "med-b179-a2",
            name: "Trulicity",
            dose: "7,5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(hour: 21, minute: 0) // server: today, 21:00 (future)
        )
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(hour: 10, minute: 30), timeZone: tz
        )
        #expect(status == nil)
    }

    /// W-B183 (operator bug) — a rolling every-7-days med whose NEXT dose is
    /// still days away (server `nextDueAt` in the future, 100% compliance)
    /// must NOT read "Stark überfällig" on an off-day. Before the fix the
    /// daily-evaluated rolling entry hit `.veryLate` once `now` passed its
    /// window end (Trulicity: last dose Fri, next dose weeks away); the
    /// future-due gate previously suppressed only `.inWindow`.
    @Test("W-B183 — rolling med, next dose days away, off-day afternoon → NOT overdue")
    func rollingFutureDueIsNotOverdue() {
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 7),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0),
            windowEnd: TimeOfDay(hour: 10, minute: 0)
        )
        let medication = Medication(
            id: "med-b183",
            name: "Trulicity",
            dose: "7,5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(dayOffset: 5, hour: 9, minute: 0) // server: 5 days away
        )
        // 13:00 = 180 min past the 10:00 window end → `.veryLate` without the
        // gate; the future server due must suppress it (nothing is overdue).
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(hour: 13, minute: 0), timeZone: tz
        )
        #expect(status == nil)
    }

    /// Vector (b): a passed, unserved morning dose stays overdue — the
    /// server gate must not swallow real due-or-overdue states
    /// (`nextDueAt` lies in the PAST here).
    @Test("W-B179 (b) — nextDue 08:00, now 10:30, unserved → overdue")
    func pastDueUncoveredStaysOverdue() {
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
            windowStart: TimeOfDay(hour: 8, minute: 0),
            windowEnd: TimeOfDay(hour: 9, minute: 0)
        )
        let medication = Medication(
            id: "med-b179-b",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(hour: 8, minute: 0) // past, unresolved
        )
        // 10:30 = 90 min past the 09:00 window end → late.
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(hour: 10, minute: 30), timeZone: tz
        )
        #expect(status == .late)
    }

    /// Vector (c): the b175 `nextDueOverdue` server flag keeps composing to
    /// an overdue affordance (`reduce(...) ?? serverOverdueFallback(...)`).
    @Test("W-B179 (c) — server nextDueOverdue with past instant → overdue")
    func serverOverdueFlagStaysOverdue() {
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 7),
            timesOfDay: [TimeOfDay(hour: 21, minute: 0)],
            windowStart: TimeOfDay(hour: 21, minute: 0)
        )
        let medication = Medication(
            id: "med-b179-c",
            name: "Trulicity",
            dose: "7,5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(dayOffset: -3, hour: 21, minute: 0), // 3 days ago
            nextDueOverdue: true
        )
        let now = berlin(hour: 10, minute: 30)
        let status = MedicationWindowStatus.reduce(medication: medication, now: now, timeZone: tz)
            ?? MedicationWindowStatus.serverOverdueFallback(medication: medication, now: now)
        #expect(status == .late)
    }

    /// True positive stays green: once the window start is reached and the
    /// server instant has passed, ".inWindow" must keep firing.
    @Test("W-B179 — in window with passed nextDueAt → still inWindow")
    func inWindowNotSuppressedWhenDueReached() {
        let medication = Medication(
            id: "med-b179-true",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [ScheduleEntry(
                cadence: .daily,
                timesOfDay: [TimeOfDay(hour: 19, minute: 0)],
                windowStart: TimeOfDay(hour: 19, minute: 0),
                windowEnd: TimeOfDay(hour: 20, minute: 0)
            )]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(hour: 19, minute: 0)
        )
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(hour: 19, minute: 10), timeZone: tz
        )
        #expect(status == .inWindow)
    }

    /// Genuine overnight window: a Friday-only 22:00–02:00 med IS still in
    /// window at Saturday 01:00 — the b178 gate skipped the entry because
    /// SATURDAY is not in the weekday set, but the open window belongs to
    /// FRIDAY's dose. The post-midnight tail must gate on yesterday's
    /// weekday. (2026-05-22 is a Friday, 2026-05-23 a Saturday.)
    @Test("W-B179 — overnight tail gates on YESTERDAY's weekday (Fri dose, Sat 01:00 → inWindow)")
    func overnightTailUsesYesterdayWeekday() {
        let entry = ScheduleEntry(
            cadence: .everyNWeeks(interval: 1, days: [.fri]),
            timesOfDay: [],
            windowStart: TimeOfDay(hour: 22, minute: 0),
            windowEnd: TimeOfDay(hour: 2, minute: 0)
        )
        let medication = Medication(
            id: "med-b179-overnight",
            name: "Abendmed",
            dose: "1 Stk",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(dayOffset: 2, hour: 22, minute: 0) // Fri 22:00, passed
        )
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(dayOffset: 3, hour: 1, minute: 0), timeZone: tz
        )
        #expect(status == .inWindow)
    }

    /// Mirror direction: a SATURDAY-only 22:00–02:00 med at Saturday 01:00
    /// is NOT in window — today's dose starts tonight at 22:00 and
    /// yesterday (Friday) never fired, so the post-midnight tail does not
    /// belong to any dose.
    @Test("W-B179 — overnight tail does NOT fire when yesterday had no dose (Sat med, Sat 01:00 → nil)")
    func overnightTailNotForNonFiringYesterday() {
        let entry = ScheduleEntry(
            cadence: .everyNWeeks(interval: 1, days: [.sat]),
            timesOfDay: [],
            windowStart: TimeOfDay(hour: 22, minute: 0),
            windowEnd: TimeOfDay(hour: 2, minute: 0)
        )
        let medication = Medication(
            id: "med-b179-satnight",
            name: "Abendmed",
            dose: "1 Stk",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(dayOffset: 3, hour: 22, minute: 0) // Sat 22:00 (future)
        )
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(dayOffset: 3, hour: 1, minute: 0), timeZone: tz
        )
        #expect(status == nil)
    }
}

/// W-B180 — green from WINDOW start, not from the slot instant.
///
/// Daily med, window `[20:30, 22:00]`, server slot 21:00. The b179
/// future-due gate compared against the SLOT instant, so the card stayed
/// neutral inside the open window. These vectors pin the precise SOLL:
/// neutral before window start, green from window start, green past the
/// slot — while the b179 pre-window suppression stays intact (its vectors
/// live in ``MedicationWindowStatusTests``).
@Suite("MedicationWindowStatus — W-B180 window-start gate")
struct MedicationWindowStatusWindowStartGateTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return cal
    }

    private let tz = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    /// A wall-clock instant on the fixed reference Wednesday (2026-05-20)
    /// shifted by `dayOffset` days, matching the b179 suite's fixture day.
    private func berlin(dayOffset: Int = 0, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 5
        c.day = 20 + dayOffset
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c) ?? .distantPast
    }

    private func slotWindowMed() -> Medication {
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 21, minute: 0)],
            windowStart: TimeOfDay(hour: 20, minute: 30),
            windowEnd: TimeOfDay(hour: 22, minute: 0),
            doseWindows: [MedicationDoseWindowDTO(
                timeOfDay: "21:00",
                start: "20:30",
                end: "22:00"
            )]
        )
        return Medication(
            id: "med-b180",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(hour: 21, minute: 0) // server slot: today, 21:00
        )
    }

    @Test("W-B180 (a) — before window start (20:00 < 20:30) → neutral")
    func beforeWindowStartStaysNeutral() {
        let status = MedicationWindowStatus.reduce(
            medication: slotWindowMed(), now: berlin(hour: 20, minute: 0), timeZone: tz
        )
        #expect(status == nil)
    }

    @Test("W-B180 (b) — inside window but before slot (20:45, slot 21:00) → inWindow")
    func inWindowBeforeSlotIsGreen() {
        // b179 regression: the slot-instant gate suppressed this to neutral
        // while the Live-Activity surface already showed the dose as due.
        let status = MedicationWindowStatus.reduce(
            medication: slotWindowMed(), now: berlin(hour: 20, minute: 45), timeZone: tz
        )
        #expect(status == .inWindow)
    }

    @Test("W-B180 (c) — slot instant passed (21:15) → still inWindow")
    func pastSlotStaysGreen() {
        let status = MedicationWindowStatus.reduce(
            medication: slotWindowMed(), now: berlin(hour: 21, minute: 15), timeZone: tz
        )
        #expect(status == .inWindow)
    }

    @Test("W-B180 (d) — 00:30 dose ignores stale 22:00–02:00 legacy window → neutral at 23:00")
    func firstClassMidnightDoseIgnoresLegacyOvernightWindow() {
        // `timesOfDay` is first-class. Without an explicit dose window the
        // server derives a clamped 00:00–01:30 band for this 00:30 dose;
        // the stale legacy 22:00–02:00 pair must not open it the prior day.
        let entry = ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 0, minute: 30)],
            windowStart: TimeOfDay(hour: 22, minute: 0),
            windowEnd: TimeOfDay(hour: 2, minute: 0)
        )
        let medication = Medication(
            id: "med-b180-overnight",
            name: "Nachtmed",
            dose: "1 Stk",
            schedule: MedicationSchedule(entries: [entry]),
            todayEventCount: 0,
            active: true,
            nextDueAt: berlin(dayOffset: 1, hour: 0, minute: 30)
        )
        let status = MedicationWindowStatus.reduce(
            medication: medication, now: berlin(hour: 23, minute: 0), timeZone: tz
        )
        #expect(status == nil)
    }
}
