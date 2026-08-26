import Foundation
@testable import HealthLog
import Testing

/// v0.10 W-Meds-B — covers the form-state prefill helper backing
/// `EditMedicationSheet`, now cadence-aware. The sheet itself drives a SwiftUI
/// view; this pure mapping struct lets us pin the field-by-field prefill +
/// cadence-inference contract without standing up a view host.
@Suite("EditMedicationSheet — EditMedicationFormState prefill")
struct EditMedicationFormStateTests {
    @Test("Prefills name, dose, schedule, treatment class, and category from the model")
    func prefillCanonicalRow() {
        let medication = Medication(
            id: "srv-1",
            name: "Ozempic",
            dose: "1.0 mg",
            treatmentClass: "GLP1",
            category: "HORMONE",
            dosesPerUnit: 4,
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 21, minute: 30)],
                weekdays: [.mon, .wed, .fri]
            ),
            notificationsEnabled: true,
            active: true
        )

        let state = EditMedicationFormState(from: medication)

        #expect(state.name == "Ozempic")
        #expect(state.dose == "1.0 mg")
        #expect(state.times.count == 2)
        #expect(state.times.first?.hour == 9)
        #expect(state.times.last?.minute == 30)
        #expect(state.category == .hormone)
        #expect(state.treatmentClass == .glp1)
        #expect(state.dosesPerUnitText == "4")
        #expect(state.notificationsEnabled)
        // Weekday subset → `.weekdays` picker kind with the same set.
        #expect(state.cadenceKind == .weekdays)
        #expect(state.cadenceSub.weekdays == [.mon, .wed, .fri])
    }

    @Test("Empty schedule.times falls back to a sensible default (08:00)")
    func prefillEmptyTimesDefaults() {
        let medication = Medication(
            id: "srv-1",
            name: "Empty",
            dose: "1 mg",
            schedule: MedicationSchedule(times: [], weekdays: nil)
        )
        let state = EditMedicationFormState(from: medication)
        #expect(state.times.count == 1)
        #expect(state.times.first?.hour == 8)
        #expect(state.times.first?.minute == 0)
    }

    @Test("Unknown category string falls back to .other (defensive against schema drift)")
    func prefillUnknownCategoryDefaultsToOther() {
        let medication = Medication(
            id: "srv-1",
            name: "Future drug",
            dose: "1 mg",
            treatmentClass: nil,
            category: "FUTURE_NEW_CATEGORY",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let state = EditMedicationFormState(from: medication)
        #expect(state.category == .other)
    }

    @Test("Nil treatmentClass defaults to .generic")
    func prefillNilTreatmentClassDefaultsToGeneric() {
        let medication = Medication(
            id: "srv-1",
            name: "Aspirin",
            dose: "100 mg",
            treatmentClass: nil,
            category: "PAIN_RELIEF",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let state = EditMedicationFormState(from: medication)
        #expect(state.treatmentClass == .generic)
    }

    @Test("No weekday constraint infers the daily picker kind")
    func prefillDailyKind() {
        let medication = Medication(
            id: "srv-1",
            name: "Daily",
            dose: "1 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)], weekdays: nil)
        )
        let state = EditMedicationFormState(from: medication)
        #expect(state.cadenceKind == .daily)
    }

    @Test("Nil dosesPerUnit yields empty text field")
    func prefillNilDosesPerUnitEmptyText() {
        let medication = Medication(
            id: "srv-1",
            name: "Aspirin",
            dose: "100 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let state = EditMedicationFormState(from: medication)
        #expect(state.dosesPerUnitText.isEmpty)
    }

    @Test("notificationsEnabled echoes the model's flag (off vs. on)")
    func prefillNotificationsRoundTrip() {
        let withOn = Medication(
            id: "srv-1",
            name: "On",
            dose: "1 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            notificationsEnabled: true
        )
        let withOff = Medication(
            id: "srv-2",
            name: "Off",
            dose: "1 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            notificationsEnabled: false
        )
        #expect(EditMedicationFormState(from: withOn).notificationsEnabled)
        #expect(!EditMedicationFormState(from: withOff).notificationsEnabled)
    }

    // MARK: - Cadence round-trip inference (edit re-selects the right kind)

    /// Build a medication from a single decoded `ScheduleEntry` so we can pin
    /// the edit-path inference for each cadence kind.
    private func medication(entry: ScheduleEntry, oneShot: Bool = false) -> Medication {
        Medication(
            id: "srv-1",
            name: "Med",
            dose: "1 mg",
            schedule: MedicationSchedule(entries: [entry]),
            oneShot: oneShot
        )
    }

    @Test("Rolling med re-selects the rolling picker with the right interval")
    func roundTripRolling() {
        let med = medication(entry: ScheduleEntry(
            cadence: .rolling(intervalDays: 30),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.cadenceKind == .rolling)
        #expect(state.cadenceSub.rollingDays == 30)
    }

    @Test("RRULE everyNWeeks med re-selects the everyNWeeks picker")
    func roundTripEveryNWeeks() {
        let med = medication(entry: ScheduleEntry(
            cadence: .everyNWeeks(interval: 6, days: [.wed]),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.cadenceKind == .everyNWeeks)
        #expect(state.cadenceSub.intervalWeeks == 6)
        #expect(state.cadenceSub.weekdays == [.wed])
    }

    @Test("PRN med re-selects the asNeeded picker")
    func roundTripPRN() {
        let med = medication(entry: ScheduleEntry(
            cadence: .asNeeded,
            timesOfDay: [],
            windowStart: TimeOfDay(hour: 8, minute: 0)
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.cadenceKind == .asNeeded)
    }

    @Test("Cyclic med re-selects the cyclic picker with on/off weeks")
    func roundTripCyclic() {
        let med = medication(entry: ScheduleEntry(
            cadence: .cyclic(weeksOn: 3, weeksOff: 1),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.cadenceKind == .cyclic)
        #expect(state.cadenceSub.cyclicOnWeeks == 3)
        #expect(state.cadenceSub.cyclicOffWeeks == 1)
    }

    @Test("One-shot med re-selects the oneShot picker regardless of schedule")
    func roundTripOneShot() {
        let med = medication(
            entry: ScheduleEntry(
                cadence: .oneShot,
                timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
                windowStart: TimeOfDay(hour: 9, minute: 0)
            ),
            oneShot: true
        )
        let state = EditMedicationFormState(from: med)
        #expect(state.cadenceKind == .oneShot)
        #expect(state.isOneShot)
    }

    @Test("Monthly med re-selects the monthly picker with day-of-month")
    func roundTripMonthly() {
        let med = medication(entry: ScheduleEntry(
            cadence: .monthly(day: 15),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.cadenceKind == .monthly)
        #expect(state.cadenceSub.dayOfMonth == 15)
    }

    @Test("Reminder grace is surfaced when the schedule carries one")
    func prefillGrace() {
        let med = medication(entry: ScheduleEntry(
            cadence: .daily,
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            reminderGraceMinutes: 120,
            windowStart: TimeOfDay(hour: 9, minute: 0)
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.graceMinutes == 120)
    }

    // MARK: - RMW: schedule-change detection (delivery-only edit → schedules nil)

    private func snapshot(
        kind: CadenceKind = .daily,
        sub: CadenceSubControls = .makeDefault(),
        times: [TimeOfDay] = [TimeOfDay(hour: 9, minute: 0)],
        grace: Int? = nil
    ) -> MedicationCadenceLogic.ScheduleSnapshot {
        MedicationCadenceLogic.ScheduleSnapshot(
            cadenceKind: kind,
            cadenceSub: sub,
            times: times,
            startsOn: nil,
            endsOn: nil,
            isOneShot: false,
            graceMinutes: grace
        )
    }

    @Test("Delivery-only edit: identical schedule snapshot → no schedule change (PUT schedules == nil)")
    func rmwUnchangedScheduleStaysNil() {
        let base = snapshot()
        #expect(!MedicationCadenceLogic.scheduleDidChange(baseline: base, current: base))
    }

    @Test("Changing the cadence kind is detected as a schedule change")
    func rmwCadenceChangeDetected() {
        let base = snapshot(kind: .daily)
        let changed = snapshot(kind: .rolling, times: [TimeOfDay(hour: 9, minute: 0)])
        #expect(MedicationCadenceLogic.scheduleDidChange(baseline: base, current: changed))
    }

    @Test("Changing a reminder time is detected as a schedule change")
    func rmwTimeChangeDetected() {
        let base = snapshot(times: [TimeOfDay(hour: 9, minute: 0)])
        let changed = snapshot(times: [TimeOfDay(hour: 21, minute: 0)])
        #expect(MedicationCadenceLogic.scheduleDidChange(baseline: base, current: changed))
    }

    @Test("Nil baseline forces a rebuild (defensive)")
    func rmwNilBaselineRebuilds() {
        #expect(MedicationCadenceLogic.scheduleDidChange(baseline: nil, current: snapshot()))
    }

    // MARK: - Per-slot raw inventory dose (08-21, #219 / v1.37.19)

    /// The server stores one schedule row per slot, and `schedules` is a
    /// REPLACE — so the form has to see every row's dose time or the next save
    /// deletes the ones it never showed.
    @Test("Prefill keeps every schedule row's dose time, not just the first row's")
    func prefillUnionsEverySlotTime() {
        let med = Medication(
            id: "srv-1",
            name: "Metformin",
            dose: "1000 mg",
            schedule: MedicationSchedule(entries: [
                ScheduleEntry(
                    cadence: .daily,
                    timesOfDay: [TimeOfDay(hour: 20, minute: 0)],
                    windowStart: TimeOfDay(hour: 20, minute: 0)
                ),
                ScheduleEntry(
                    cadence: .daily,
                    timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                    windowStart: TimeOfDay(hour: 8, minute: 0)
                )
            ])
        )
        let state = EditMedicationFormState(from: med)
        #expect(state.times == [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)])
    }

    /// Two slots sharing a dose time (different labels) must not render twice —
    /// a duplicated `timesOfDay` entry is a server refine failure on save.
    @Test("Duplicate slot times collapse to one form row")
    func prefillDeduplicatesSharedSlotTimes() {
        let time = TimeOfDay(hour: 9, minute: 0)
        let med = Medication(
            id: "srv-1",
            name: "Shared",
            dose: "1 mg",
            schedule: MedicationSchedule(entries: [
                ScheduleEntry(cadence: .daily, timesOfDay: [time], label: "A", windowStart: time),
                ScheduleEntry(cadence: .daily, timesOfDay: [time], label: "B", windowStart: time)
            ])
        )
        #expect(EditMedicationFormState(from: med).times == [time])
    }

    /// Raw and resolved arrive as two separate maps and neither is derived from
    /// the other: the inheriting slot has NO raw entry but does have a resolved
    /// one, which is exactly the pair an edit surface needs to tell an explicit
    /// choice from inheritance.
    @Test("Prefill separates the raw per-slot override from the server-resolved figure")
    func prefillSeparatesRawFromResolved() {
        let med = Medication(
            id: "srv-1",
            name: "Metformin",
            dose: "1000 mg",
            schedule: MedicationSchedule(entries: [
                ScheduleEntry(
                    cadence: .daily,
                    timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                    windowStart: TimeOfDay(hour: 8, minute: 0),
                    unitsPerDose: nil,
                    resolvedUnitsPerDose: 1
                ),
                ScheduleEntry(
                    cadence: .daily,
                    timesOfDay: [TimeOfDay(hour: 20, minute: 0)],
                    windowStart: TimeOfDay(hour: 20, minute: 0),
                    unitsPerDose: 0.5,
                    resolvedUnitsPerDose: 0.5
                )
            ])
        )
        let state = EditMedicationFormState(from: med)
        #expect(state.slotUnitsPerDose == ["20:00": 0.5])
        #expect(state.serverEffectiveUnitsPerDose == ["08:00": 1, "20:00": 0.5])
    }

    /// The tri-state, at the level the form holds it.
    @Test("Untouched keeps, clear removes, set replaces")
    func slotDoseIntentsResolveAsThreeStates() {
        let existing = ["08:00": 1.0, "20:00": 0.5]
        #expect(MedicationCadenceLogic.resolveSlotUnitsPerDose(existing: existing, intents: [:]) == existing)
        #expect(
            MedicationCadenceLogic.resolveSlotUnitsPerDose(existing: existing, intents: ["20:00": .unchanged])
                == existing
        )
        #expect(
            MedicationCadenceLogic.resolveSlotUnitsPerDose(existing: existing, intents: ["20:00": .clear])
                == ["08:00": 1.0]
        )
        #expect(
            MedicationCadenceLogic.resolveSlotUnitsPerDose(existing: existing, intents: ["20:00": .set(0.25)])
                == ["08:00": 1.0, "20:00": 0.25]
        )
        // Clearing a slot that never had an override is a no-op, not an entry.
        #expect(MedicationCadenceLogic.resolveSlotUnitsPerDose(existing: [:], intents: ["08:00": .clear]).isEmpty)
    }

    @Test("A slot-dose-only edit is a schedule change (otherwise the PUT omits schedules)")
    func rmwSlotDoseChangeDetected() {
        var base = snapshot()
        base.slotUnitsPerDose = ["09:00": 0.5]
        var changed = base
        changed.slotUnitsPerDose = ["09:00": 1]
        #expect(MedicationCadenceLogic.scheduleDidChange(baseline: base, current: changed))
        #expect(!MedicationCadenceLogic.scheduleDidChange(baseline: base, current: base))
    }
}
