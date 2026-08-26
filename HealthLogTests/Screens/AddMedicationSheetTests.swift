import Foundation
@testable import HealthLog
import Testing

/// v0.10 W-Meds-B — pure-logic coverage of the form validator + cadence
/// encoder backing `AddMedicationSheet`. The view itself is exercised
/// indirectly through `MedicationsStore.create`; these tests pin the rules
/// that govern *what* the sheet sends.
@Suite("AddMedicationSheet — MedicationFormLogic core")
struct AddMedicationSheetFormLogicTests {
    // MARK: - isValidCore

    @Test("Valid name + dose passes the core validator")
    func coreValidHappyPath() {
        #expect(MedicationFormLogic.isValidCore(name: "Ozempic", dose: "1.0 mg"))
    }

    @Test("Blank name fails the core validator")
    func coreRejectsBlankName() {
        #expect(!MedicationFormLogic.isValidCore(name: "   ", dose: "1 mg"))
    }

    @Test("Name > 100 chars fails (server schema cap)")
    func coreRejectsLongName() {
        #expect(!MedicationFormLogic.isValidCore(name: String(repeating: "X", count: 101), dose: "1 mg"))
    }

    @Test("Dose > 50 chars fails")
    func coreRejectsLongDose() {
        #expect(!MedicationFormLogic.isValidCore(name: "Ozempic", dose: String(repeating: "1", count: 51)))
    }

    @Test("Blank dose fails")
    func coreRejectsBlankDose() {
        #expect(!MedicationFormLogic.isValidCore(name: "Ozempic", dose: "  "))
    }

    // MARK: - parseDosesPerUnit

    @Test("parseDosesPerUnit accepts 1...100")
    func parseDosesPerUnitInRange() {
        #expect(MedicationFormLogic.parseDosesPerUnit("4") == 4)
        #expect(MedicationFormLogic.parseDosesPerUnit("100") == 100)
        #expect(MedicationFormLogic.parseDosesPerUnit("1") == 1)
    }

    @Test("parseDosesPerUnit rejects out-of-range + garbage")
    func parseDosesPerUnitRejectsBad() {
        #expect(MedicationFormLogic.parseDosesPerUnit("") == nil)
        #expect(MedicationFormLogic.parseDosesPerUnit("0") == nil)
        #expect(MedicationFormLogic.parseDosesPerUnit("101") == nil)
        #expect(MedicationFormLogic.parseDosesPerUnit("abc") == nil)
        #expect(MedicationFormLogic.parseDosesPerUnit("1.5") == nil)
    }

    // MARK: - Wire-value sanity

    @Test("Category enum's wireValue matches the server's MEDICATION_CATEGORY_VALUES")
    func categoryWireValuesAreCanonical() {
        let expected: Set = [
            "BLOOD_PRESSURE", "VITAMIN", "SUPPLEMENT", "PAIN_RELIEF",
            "ALLERGY", "DIGESTIVE", "THYROID", "HORMONE", "SKIN",
            "SLEEP_AID", "OTHER"
        ]
        #expect(Set(MedicationCategoryOption.allCases.map(\.wireValue)) == expected)
    }

    @Test("TreatmentClass enum's wireValue matches the server's allowed set")
    func treatmentClassWireValuesAreCanonical() {
        #expect(Set(MedicationTreatmentClassOption.allCases.map(\.wireValue)) == ["GENERIC", "GLP1"])
    }

    @Test("DeliveryForm option maps .unspecified to nil, rest to the server enum")
    func deliveryFormWireValues() {
        #expect(MedicationDeliveryFormOption.unspecified.wireValue == nil)
        #expect(MedicationDeliveryFormOption.oral.wireValue == "ORAL")
        #expect(MedicationDeliveryFormOption.injection.wireValue == "INJECTION")
        #expect(MedicationDeliveryFormOption.other.wireValue == "OTHER")
        #expect(MedicationDeliveryFormOption.from(wire: "INJECTION") == .injection)
        #expect(MedicationDeliveryFormOption.from(wire: nil) == .unspecified)
        #expect(MedicationDeliveryFormOption.from(wire: "FUTURE") == .unspecified)
    }
}

/// v0.10 W-Meds-B — the cadence encoder / validator / schedule builder. These
/// pin parity with the web oracle (`encodeCadence` in `CadencePicker.tsx`) and
/// the server cross-field invariants (`medication.ts` refines).
@Suite("MedicationCadenceLogic — encode / validate / build")
struct MedicationCadenceLogicTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }

    private func sub() -> CadenceSubControls {
        .makeDefault()
    }

    // MARK: - Encode → wire

    @Test("daily encodes FREQ=DAILY")
    func encodeDaily() {
        let v = MedicationCadenceLogic.encode(.daily, sub())
        #expect(v.rrule == "FREQ=DAILY")
        #expect(v.rollingIntervalDays == nil)
        #expect(!v.oneShot && !v.asNeeded)
    }

    @Test("weekdays encodes FREQ=WEEKLY;BYDAY in Mon→Sun order")
    func encodeWeekdays() {
        var s = sub()
        s.weekdays = [.fri, .mon, .wed]
        let v = MedicationCadenceLogic.encode(.weekdays, s)
        #expect(v.rrule == "FREQ=WEEKLY;BYDAY=MO,WE,FR")
    }

    @Test("everyNWeeks encodes INTERVAL + BYDAY")
    func encodeEveryNWeeks() {
        var s = sub()
        s.intervalWeeks = 6
        s.weekdays = [.wed]
        let v = MedicationCadenceLogic.encode(.everyNWeeks, s)
        #expect(v.rrule == "FREQ=WEEKLY;INTERVAL=6;BYDAY=WE")
    }

    @Test("monthly encodes BYMONTHDAY")
    func encodeMonthly() {
        var s = sub()
        s.dayOfMonth = 15
        let v = MedicationCadenceLogic.encode(.monthly, s)
        #expect(v.rrule == "FREQ=MONTHLY;BYMONTHDAY=15")
    }

    @Test("everyNMonths encodes INTERVAL + BYMONTHDAY")
    func encodeEveryNMonths() {
        var s = sub()
        s.intervalMonths = 3
        s.dayOfMonth = 1
        let v = MedicationCadenceLogic.encode(.everyNMonths, s)
        #expect(v.rrule == "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1")
    }

    @Test("yearly encodes BYMONTH + BYMONTHDAY from the date")
    func encodeYearly() throws {
        var s = sub()
        // 2024-03-09
        s.yearlyDate = try #require(calendar.date(from: DateComponents(year: 2024, month: 3, day: 9)))
        let v = MedicationCadenceLogic.encode(.yearly, s, calendar: calendar)
        #expect(v.rrule == "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=9")
    }

    @Test("rolling encodes rollingIntervalDays, no rrule")
    func encodeRolling() {
        var s = sub()
        s.rollingDays = 30
        let v = MedicationCadenceLogic.encode(.rolling, s)
        #expect(v.rrule == nil)
        #expect(v.rollingIntervalDays == 30)
    }

    /// **09-14 — inverted.** The anchor clause is gone because the anchor is
    /// gone: the published contract has no per-schedule anchor and the phase is
    /// counted from the medication's course start.
    @Test("cyclic encodes on/off weeks, no rrule/rolling, no anchor")
    func encodeCyclic() {
        var s = sub()
        s.cyclicOnWeeks = 3
        s.cyclicOffWeeks = 1
        let v = MedicationCadenceLogic.encode(.cyclic, s, calendar: calendar)
        #expect(v.rrule == nil && v.rollingIntervalDays == nil)
        #expect(v.cyclicOnWeeks == 3 && v.cyclicOffWeeks == 1)
    }

    @Test("oneShot sets the medication-level flag, no recurrence")
    func encodeOneShot() {
        let v = MedicationCadenceLogic.encode(.oneShot, sub())
        #expect(v.oneShot)
        #expect(v.rrule == nil && v.rollingIntervalDays == nil)
    }

    @Test("asNeeded sets the schedule-level PRN flag, no recurrence")
    func encodeAsNeeded() {
        let v = MedicationCadenceLogic.encode(.asNeeded, sub())
        #expect(v.asNeeded)
        #expect(v.rrule == nil && v.rollingIntervalDays == nil)
    }

    // MARK: - buildSchedules → DTO

    @Test("daily build emits one DTO with rrule + timesOfDay")
    func buildDaily() {
        let v = MedicationCadenceLogic.encode(.daily, sub())
        let dtos = MedicationCadenceLogic.buildSchedules(
            value: v,
            times: [TimeOfDay(hour: 20, minute: 30), TimeOfDay(hour: 8, minute: 0)],
            graceMinutes: nil
        )
        #expect(dtos.count == 1)
        #expect(dtos[0].rrule == "FREQ=DAILY")
        #expect(dtos[0].timesOfDay == ["08:00", "20:30"]) // sorted
        #expect(dtos[0].windowStart == "08:00")
        #expect(dtos[0].rollingIntervalDays == nil)
        #expect(dtos[0].scheduleType == nil)
    }

    @Test("rolling build emits rollingIntervalDays + the single time + grace")
    func buildRolling() {
        var s = sub()
        s.rollingDays = 30
        let v = MedicationCadenceLogic.encode(.rolling, s)
        let dtos = MedicationCadenceLogic.buildSchedules(
            value: v,
            times: [TimeOfDay(hour: 9, minute: 0)],
            graceMinutes: 120
        )
        #expect(dtos.count == 1)
        #expect(dtos[0].rollingIntervalDays == 30)
        #expect(dtos[0].rrule == nil)
        #expect(dtos[0].reminderGraceMinutes == 120)
    }

    /// **09-14 — inverted.** The row used to carry `asNeeded: true`, a key the
    /// accepted `MedicationScheduleInput` does not declare and Zod therefore
    /// stripped, leaving a cadence-less row the create route stamped
    /// `rrule = "FREQ=DAILY"` — a PRN medication became a daily plan.
    ///
    /// A whole-medication PRN carries **no schedule rows at all**: the flag is
    /// the MEDICATION-level `asNeeded`, and the route 422s any entry beside it.
    /// (`scheduleType: PRN` is the other, narrower spelling — a single as-needed
    /// slot on a medication that also has scheduled ones. iOS holds one cadence
    /// per medication, so that case cannot arise here.) The pairing is asserted
    /// through `scheduleWrite`, which is the only way either half is built.
    @Test("asNeeded build emits no rows at all, with the medication-level flag set")
    func buildAsNeeded() {
        let v = MedicationCadenceLogic.encode(.asNeeded, sub())
        let write = MedicationCadenceLogic.scheduleWrite(value: v, times: [], graceMinutes: nil)
        #expect(write.schedules.isEmpty)
        #expect(write.asNeeded)
    }

    @Test("a scheduled cadence sends the flag as an explicit false, never nil")
    func scheduledWriteClearsTheAsNeededFlag() {
        let v = MedicationCadenceLogic.encode(.daily, sub())
        let write = MedicationCadenceLogic.scheduleWrite(
            value: v,
            times: [TimeOfDay(hour: 9, minute: 0)],
            graceMinutes: nil
        )
        // An omitted flag would leave a medication PRN forever once it had been
        // made PRN once, and an empty array without the flag is a 422 the other
        // way — so the two halves are asserted together.
        #expect(!write.asNeeded)
        #expect(write.schedules.count == 1)
    }

    /// **09-14 — inverted.** The anchor assertion is replaced by the
    /// discriminator assertion, which is the thing that actually decides whether
    /// the server stores a cyclic row at all: `cyclicOnWeeks` / `cyclicOffWeeks`
    /// are published as "ignored otherwise" unless `scheduleType` is CYCLIC.
    @Test("cyclic build emits the on/off weeks and the CYCLIC discriminator")
    func buildCyclic() {
        var s = sub()
        s.cyclicOnWeeks = 3
        s.cyclicOffWeeks = 1
        let v = MedicationCadenceLogic.encode(.cyclic, s, calendar: calendar)
        let dtos = MedicationCadenceLogic.buildSchedules(
            value: v,
            times: [TimeOfDay(hour: 9, minute: 0)],
            graceMinutes: nil,
            calendar: calendar
        )
        #expect(dtos.count == 1)
        #expect(dtos[0].cyclicOnWeeks == 3)
        #expect(dtos[0].cyclicOffWeeks == 1)
        #expect(dtos[0].scheduleType == .cyclic)
    }

    /// Regression for audit H-1 — the local-vs-UTC day skew, **re-pointed at the
    /// field that survived**. Production threads `Calendar.current`
    /// (device-local, here Berlin/UTC+2) into `isoDay`. The old `isoDay` read UTC
    /// day-components of a local-midnight date, rolling 10 July back to 09 July.
    ///
    /// **09-14 — this used to assert the skew through `cycleAnchor`.** That key
    /// is gone, but the defect it guarded is not: the same `isoDay` still writes
    /// the medication's `startsOn`, which is now the ONLY anchor the cyclic phase
    /// is counted from — so a one-day skew there shifts the on/off weeks exactly
    /// as it used to, and the regression matters more than before, not less.
    @Test("the course start stores the picked local day (audit H-1)")
    func courseStartHonoursPickedLocalDay() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // User picks 10 July 2026 (summer time → Berlin is UTC+2).
        let picked = try #require(berlin.date(from: DateComponents(year: 2026, month: 7, day: 10)))
        #expect(MedicationCadenceLogic.isoDay(picked, calendar: berlin) == "2026-07-10")
    }

    // MARK: - Validation invariants (mirror server refines)

    private func validate(
        _ kind: CadenceKind,
        _ s: CadenceSubControls,
        times: [TimeOfDay],
        startsOn: Date? = nil,
        endsOn: Date? = nil,
        grace: Int? = nil
    ) -> Bool {
        let v = MedicationCadenceLogic.encode(kind, s, calendar: calendar)
        return MedicationCadenceLogic.isCadenceValid(
            value: v, times: times, startsOn: startsOn, endsOn: endsOn, graceMinutes: grace
        )
    }

    @Test("daily requires at least one time")
    func validateDailyRequiresTime() {
        #expect(validate(.daily, sub(), times: [TimeOfDay(hour: 8, minute: 0)]))
        #expect(!validate(.daily, sub(), times: []))
    }

    @Test("rolling rejects more than one time")
    func validateRollingMaxOneTime() {
        var s = sub()
        s.rollingDays = 30
        #expect(validate(.rolling, s, times: [TimeOfDay(hour: 9, minute: 0)]))
        #expect(!validate(.rolling, s, times: [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 21, minute: 0)]))
    }

    @Test("oneShot requires startsOn")
    func validateOneShotNeedsStart() {
        #expect(!validate(.oneShot, sub(), times: [TimeOfDay(hour: 9, minute: 0)], startsOn: nil))
        #expect(validate(.oneShot, sub(), times: [TimeOfDay(hour: 9, minute: 0)], startsOn: Date()))
    }

    @Test("endsOn before startsOn is rejected")
    func validateEndsAfterStart() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2024, month: 6, day: 1)))
        let endBefore = try #require(calendar.date(from: DateComponents(year: 2024, month: 5, day: 1)))
        let endAfter = try #require(calendar.date(from: DateComponents(year: 2024, month: 7, day: 1)))
        #expect(!validate(.daily, sub(), times: [TimeOfDay(hour: 8, minute: 0)], startsOn: start, endsOn: endBefore))
        #expect(validate(.daily, sub(), times: [TimeOfDay(hour: 8, minute: 0)], startsOn: start, endsOn: endAfter))
    }

    @Test("asNeeded rejects times + grace")
    func validateAsNeededNoTimesNoGrace() {
        #expect(validate(.asNeeded, sub(), times: []))
        #expect(!validate(.asNeeded, sub(), times: [TimeOfDay(hour: 9, minute: 0)]))
        #expect(!validate(.asNeeded, sub(), times: [], grace: 60))
    }

    /// **09-14 — inverted.** The rule dropped its anchor clause, because the
    /// form field it named no longer exists. It deliberately did NOT gain a
    /// `startsOn != nil` clause: the server falls back to the medication's
    /// creation day and iOS mirrors that fallback, so requiring a course start
    /// would be a new hard gate on an edit that previously saved.
    @Test("cyclic requires weeksOn ≥ 1 and weeksOff ≥ 0, and no anchor")
    func validateCyclic() {
        var s = sub()
        s.cyclicOnWeeks = 3
        s.cyclicOffWeeks = 1
        #expect(validate(.cyclic, s, times: [TimeOfDay(hour: 9, minute: 0)]))
        #expect(validate(.cyclic, s, times: [TimeOfDay(hour: 9, minute: 0)], startsOn: nil))
    }

    // MARK: - maxTimes

    @Test("maxTimes: rolling 1, asNeeded 0, others 8")
    func maxTimesPerKind() {
        #expect(MedicationCadenceLogic.maxTimes(for: .rolling) == 1)
        #expect(MedicationCadenceLogic.maxTimes(for: .asNeeded) == 0)
        #expect(MedicationCadenceLogic.maxTimes(for: .daily) == 8)
        #expect(MedicationCadenceLogic.maxTimes(for: .cyclic) == 8)
    }
}

/// Audit H-1 regression — `MedicationCadenceLogic.isoDay` must serialize a
/// course-window / cyclic-anchor date on the LOCAL calendar day the user
/// actually picked, in every timezone. Production feeds it a local-midnight
/// `Date` (SwiftUI date pickers + `Calendar.current.startOfDay(for:)`). Reading
/// UTC day-components of that instant rolled the stored day BACK one calendar
/// day for users east of UTC (Berlin/UTC+2: 10 Jul local-midnight = 09 Jul
/// 22:00 UTC → "2026-07-09"), so course `startsOn`/`endsOn` and the cyclic
/// anchor were stored a day early. These cases construct the input exactly the
/// way production does (explicit TimeZone, no wall-clock reads) and pin the
/// picked day across east-of-UTC, west-of-UTC, and the UTC edge.
@Suite("MedicationCadenceLogic.isoDay — picked-local-day fidelity (audit H-1)")
struct MedicationCadenceLogicIsoDayTests {
    @Test(
        "isoDay serializes the picked local day, not the UTC-shifted day",
        arguments: [
            "Europe/Berlin", // UTC+1/+2 — the reported regression
            "Asia/Tokyo", // UTC+9 — far east
            "Pacific/Kiritimati", // UTC+14 — extreme east of the date line
            "America/Los_Angeles", // UTC-7/-8 — west of UTC
            "America/Sao_Paulo", // UTC-3
            "UTC" // edge: zero offset
        ]
    )
    func isoDayEmitsPickedLocalDay(zoneID: String) throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: zoneID))
        // The user picks 10 July 2026 in their own local calendar; production
        // reduces the picked date to local midnight before serializing.
        let picked = try #require(local.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9)))
        let localMidnight = local.startOfDay(for: picked)
        let iso = MedicationCadenceLogic.isoDay(localMidnight, calendar: local)
        #expect(iso == "2026-07-10", "zone \(zoneID) shifted the stored day off the picked day")
    }
}

/// therapy-interim-merge (2026-05-16) — covers the post-merge wiring
/// contract between `AddMedicationSheet` and T-6's `PhotoOfMedSheet`. The form
/// fills empty fields from the draft and never overwrites user input.
@Suite("AddMedicationSheet — PhotoOfMed prefill")
struct AddMedicationSheetPhotoPrefillTests {
    private func draft(
        name: String = "Ozempic",
        doseStrength: String? = "1.0 mg"
    ) -> MedicationDraft {
        MedicationDraft(
            name: name,
            doseStrength: doseStrength,
            doseForm: nil,
            manufacturerHint: nil,
            source: .heuristic
        )
    }

    @Test("Empty form is prefilled with name + dose from the draft")
    func prefillIntoEmptyForm() {
        let result = MedicationFormLogic.applyPhotoOfMedPrefill(currentName: "", currentDose: "", draft: draft())
        #expect(result.name == "Ozempic")
        #expect(result.dose == "1.0 mg")
    }

    @Test("Whitespace-only fields are treated as empty and prefilled")
    func prefillIntoWhitespaceOnlyForm() {
        let result = MedicationFormLogic.applyPhotoOfMedPrefill(currentName: "   ", currentDose: "\t  \n", draft: draft())
        #expect(result.name == "Ozempic")
        #expect(result.dose == "1.0 mg")
    }

    @Test("User-typed name is never overwritten by the draft")
    func prefillNeverOverwritesName() {
        let result = MedicationFormLogic.applyPhotoOfMedPrefill(
            currentName: "Eigene Eingabe", currentDose: "", draft: draft(name: "Ozempic")
        )
        #expect(result.name == "Eigene Eingabe")
        #expect(result.dose == "1.0 mg")
    }

    @Test("User-typed dose is never overwritten by the draft")
    func prefillNeverOverwritesDose() {
        let result = MedicationFormLogic.applyPhotoOfMedPrefill(
            currentName: "", currentDose: "2.0 mg", draft: draft(doseStrength: "1.0 mg")
        )
        #expect(result.name == "Ozempic")
        #expect(result.dose == "2.0 mg")
    }

    @Test("Missing doseStrength on the draft leaves the empty dose untouched")
    func prefillSkipsMissingDose() {
        let result = MedicationFormLogic.applyPhotoOfMedPrefill(
            currentName: "", currentDose: "", draft: draft(doseStrength: nil)
        )
        #expect(result.name == "Ozempic")
        #expect(result.dose.isEmpty)
    }
}
