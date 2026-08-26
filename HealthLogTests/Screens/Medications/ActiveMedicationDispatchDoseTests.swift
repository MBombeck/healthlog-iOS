import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.1 ITEM-A — daily multi-dose intake-mark dispatch.**
///
/// Operator bug (post-b147): tapping "Genommen" on **Lisinopril** (a daily,
/// multi-time oral med) played the confirm beam but the dose the operator
/// thought they logged never showed up in Verlauf as the *current* dose,
/// while **Trulicity** (weekly, single dose) recorded correctly.
///
/// Root cause: `ActiveMedicationsSection.dispatchMark` resolved the dose by
/// picking the **earliest pending slot of the day**. For a single-dose weekly
/// med that is always the right (and only) slot. For a daily multi-dose med
/// with several pending slots, an evening tap marked the long-past *morning*
/// slot — recorded against a `scheduledFor` hours in the past that the
/// operator never recognised as "the dose I just took".
///
/// `ActiveMedicationsSection.resolveDispatchDose` now prefers the most-recent
/// already-due slot (the dose being acted on right now), falling back to the
/// soonest upcoming slot. These tests pin that selection.
@Suite("ActiveMedicationsSection — dispatch-dose resolution (ITEM-A)")
struct ActiveMedicationDispatchDoseTests {
    private static let med = "med-lisinopril"

    private static func intake(_ hour: Int, status: IntakeStatus = .pending, id: String? = nil) -> MedicationIntake {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = cal.date(from: DateComponents(year: 2026, month: 6, day: 4))!
        let at = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return MedicationIntake(
            id: id ?? "slot-\(hour)",
            medicationId: med,
            scheduledAt: at,
            takenAt: status == .taken ? at : nil,
            status: status,
            snoozedUntil: nil
        )
    }

    private static func now(_ hour: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = cal.date(from: DateComponents(year: 2026, month: 6, day: 4))!
        return cal.date(bySettingHour: hour, minute: 30, second: 0, of: day)!
    }

    @Test("Evening tap marks the most-recent already-due slot, not the stale morning slot")
    func picksMostRecentDueSlot() {
        let intakes = [Self.intake(8), Self.intake(14), Self.intake(20)]
        let resolved = ActiveMedicationsSection.resolveDispatchDose(
            medicationId: Self.med,
            todayIntakes: intakes,
            now: Self.now(20) // 20:30 — all three are due/overdue
        )
        #expect(resolved?.id == "slot-20")
    }

    @Test("Midday tap marks the 14:00 slot once it has passed, not the morning slot")
    func picksCurrentWindowSlot() {
        let intakes = [Self.intake(8), Self.intake(14), Self.intake(20)]
        let resolved = ActiveMedicationsSection.resolveDispatchDose(
            medicationId: Self.med,
            todayIntakes: intakes,
            now: Self.now(14) // 14:30 — 08:00 + 14:00 due, 20:00 upcoming
        )
        #expect(resolved?.id == "slot-14")
    }

    @Test("Early tap (before any slot is due) marks the soonest upcoming slot")
    func picksSoonestUpcomingWhenNoneDue() {
        let intakes = [Self.intake(8), Self.intake(14), Self.intake(20)]
        let resolved = ActiveMedicationsSection.resolveDispatchDose(
            medicationId: Self.med,
            todayIntakes: intakes,
            now: Self.now(6) // 06:30 — nothing due yet
        )
        #expect(resolved?.id == "slot-8")
    }

    @Test("Already-taken slots are skipped; the next pending due slot is chosen")
    func skipsTakenSlots() {
        let intakes = [
            Self.intake(8, status: .taken),
            Self.intake(14, status: .pending),
            Self.intake(20, status: .pending)
        ]
        let resolved = ActiveMedicationsSection.resolveDispatchDose(
            medicationId: Self.med,
            todayIntakes: intakes,
            now: Self.now(20)
        )
        #expect(resolved?.id == "slot-20")
    }

    @Test("Weekly single-dose med resolves its one slot unchanged (Trulicity parity)")
    func weeklySingleSlotUnchanged() {
        let intakes = [Self.intake(9, id: "trulicity-week")]
        let resolved = ActiveMedicationsSection.resolveDispatchDose(
            medicationId: Self.med,
            todayIntakes: intakes,
            now: Self.now(20)
        )
        #expect(resolved?.id == "trulicity-week")
    }

    @Test("No pending dose returns nil so the caller falls back to the ad-hoc synth POST")
    func nilWhenNoPending() {
        let intakes = [Self.intake(8, status: .taken)]
        let resolved = ActiveMedicationsSection.resolveDispatchDose(
            medicationId: Self.med,
            todayIntakes: intakes,
            now: Self.now(20)
        )
        #expect(resolved == nil)
    }
}

// swiftlint:disable force_unwrapping

/// **v0.14.2 H3 — ad-hoc mark `scheduledFor` resolution.**
///
/// When `resolveDispatchDose` finds no pending today-row the tap falls through
/// to the ad-hoc synth POST. The old path keyed it on `scheduledFor = .now`,
/// which mis-attributes a scheduled (non-PRN) med marked on a weekly off-day /
/// cyclic off-week to the wrong slot. `resolveAdHocScheduledFor` now resolves
/// the nearest DUE recurrence slot for scheduled meds (PRN keeps `now`).
@Suite("ActiveMedicationsSection — ad-hoc scheduledFor resolution (H3)")
struct ActiveMedicationAdHocScheduledForTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = berlin
        return c
    }

    /// Saturday 2026-06-06 14:30 — an off-day for a Monday-only weekly med.
    private static let saturdayNow: Date = Self.cal().date(from: DateComponents(year: 2026, month: 6, day: 6, hour: 14, minute: 30))!

    private static func weeklyMondayMed() -> Medication {
        let entry = ScheduleEntry(
            cadence: .weekdays([.mon]),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        return Medication(
            id: "weekly",
            name: "Trulicity",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            createdAt: Self.cal().date(byAdding: .day, value: -60, to: Self.saturdayNow)
        )
    }

    @Test("Weekly med marked on an off-day resolves to the real Monday slot, not now")
    func weeklyOffDayResolvesToScheduledSlot() {
        let med = Self.weeklyMondayMed()
        let resolved = ActiveMedicationsSection.resolveAdHocScheduledFor(
            medication: med,
            now: Self.saturdayNow,
            timeZone: Self.berlin
        )
        // Must NOT be "now" (the Saturday off-day) — it must snap to a Monday.
        #expect(abs(resolved.timeIntervalSince(Self.saturdayNow)) > 60)
        let cal = Self.cal()
        #expect(cal.component(.weekday, from: resolved) == 2) // Monday
        // The nearest already-due slot is the PAST Monday (2026-06-01), so the
        // resolved instant is before now.
        #expect(resolved < Self.saturdayNow)
    }

    @Test("PRN med keeps now (the act IS the slot)")
    func prnKeepsNow() {
        let med = Medication(
            id: "prn",
            name: "Naproxen",
            dose: "400 mg",
            schedule: MedicationSchedule(times: []),
            createdAt: Self.cal().date(byAdding: .day, value: -10, to: Self.saturdayNow)
        )
        let resolved = ActiveMedicationsSection.resolveAdHocScheduledFor(
            medication: med,
            now: Self.saturdayNow,
            timeZone: Self.berlin
        )
        #expect(resolved == Self.saturdayNow)
    }

    @Test("Daily med marked between slots resolves to the most-recent due slot")
    func dailyResolvesMostRecentDue() {
        let med = Medication(
            id: "daily",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)]),
            createdAt: Self.cal().date(byAdding: .day, value: -30, to: Self.saturdayNow)
        )
        let resolved = ActiveMedicationsSection.resolveAdHocScheduledFor(
            medication: med,
            now: Self.saturdayNow, // 14:30 — 08:00 due, 20:00 upcoming
            timeZone: Self.berlin
        )
        let cal = Self.cal()
        // Most-recent due slot today is the 08:00 dose.
        #expect(cal.component(.hour, from: resolved) == 8)
        #expect(cal.isDate(resolved, inSameDayAs: Self.saturdayNow))
    }
}

// swiftlint:enable force_unwrapping

// swiftlint:enable force_unwrapping
