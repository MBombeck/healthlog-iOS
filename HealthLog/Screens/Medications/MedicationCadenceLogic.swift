import Foundation

// MARK: - Cadence encode / infer / validate (R1 §3.7)

/// Pure cadence helpers backing `CadencePicker` + the Add/Edit sheets. Mirrors
/// the web oracle's `encodeCadence` (`CadencePicker.tsx`) and
/// `inferCadenceFromLegacy` (`legacy-bridge.ts`) so the two clients encode the
/// same wire shape and re-select the same picker kind on edit.
///
/// Kept `internal` + value-only so unit tests can pin the mapping without a
/// SwiftUI host.
enum MedicationCadenceLogic {
    // MARK: - Encode (kind + sub-controls → CadenceValue)

    /// Map a `(kind, subControls)` pair to a `CadenceValue`. Pure; the picker
    /// calls this on every interaction. Mirrors the web `encodeCadence`
    /// switch verbatim, with the cyclic / PRN extensions appended.
    static func encode(
        _ kind: CadenceKind,
        _ sub: CadenceSubControls,
        calendar: Calendar = .current
    ) -> CadenceValue {
        switch kind {
        case .daily:
            return value(kind, rrule: "FREQ=DAILY")
        case .weekdays:
            let days = sub.weekdays.isEmpty ? [Weekday.mon] : Array(sub.weekdays)
            return value(kind, rrule: "FREQ=WEEKLY;BYDAY=\(byDay(days))")
        case .everyNWeeks:
            let days = sub.weekdays.isEmpty ? [Weekday.mon] : Array(sub.weekdays)
            let n = clamp(sub.intervalWeeks, 1, 52)
            return value(kind, rrule: "FREQ=WEEKLY;INTERVAL=\(n);BYDAY=\(byDay(days))")
        case .monthly:
            let d = clamp(sub.dayOfMonth, 1, 31)
            return value(kind, rrule: "FREQ=MONTHLY;BYMONTHDAY=\(d)")
        case .everyNMonths:
            let n = clamp(sub.intervalMonths, 1, 12)
            let d = clamp(sub.dayOfMonth, 1, 31)
            return value(kind, rrule: "FREQ=MONTHLY;INTERVAL=\(n);BYMONTHDAY=\(d)")
        case .yearly:
            let comps = calendar.dateComponents([.month, .day], from: sub.yearlyDate)
            let month = comps.month ?? 1
            let day = comps.day ?? 1
            return value(kind, rrule: "FREQ=YEARLY;BYMONTH=\(month);BYMONTHDAY=\(day)")
        case .rolling:
            let n = clamp(sub.rollingDays, 1, 365)
            return value(kind, rollingIntervalDays: n)
        case .cyclic:
            let on = max(1, sub.cyclicOnWeeks)
            let off = max(0, sub.cyclicOffWeeks)
            return value(kind, cyclicOnWeeks: on, cyclicOffWeeks: off)
        case .oneShot:
            return value(kind, oneShot: true)
        case .asNeeded:
            return value(kind, asNeeded: true)
        }
    }

    // MARK: - Infer (existing medication → picker selection)

    /// Re-select the picker kind + sub-controls from a decoded medication's
    /// primary `ScheduleEntry` (the edit path). Mirrors the web
    /// `inferCadenceFromLegacy` plus the v1.5/v1.7 cases the iOS engine already
    /// decodes (`ScheduleEntry.cadence`), so a rolling / RRULE / PRN / cyclic
    /// med re-opens with the right radio. Never invents a recurrence the server
    /// didn't carry.
    static func infer(
        from medication: Medication,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> (kind: CadenceKind, sub: CadenceSubControls) {
        let sub = CadenceSubControls.makeDefault(now: now)
        // One-shot is medication-level and wins regardless of the schedule row.
        if medication.oneShot {
            return (.oneShot, sub)
        }
        // 09-14 — as-needed is medication-level too, and it has to be read
        // BEFORE the entries: a PRN medication is defined by having none, so
        // the guard below would otherwise re-select it as a daily plan and the
        // next save would give the user a reminder every morning.
        if medication.asNeeded {
            return (.asNeeded, sub)
        }
        guard let entry = medication.schedule.entries.first else {
            return (.daily, sub)
        }
        return inferFromCadence(entry.cadence, sub: sub, now: now, calendar: calendar)
    }

    /// The `entry.cadence` → `(kind, sub)` mapping. Split out of `infer` so
    /// each function stays under the cyclomatic budget; the medication-level
    /// `oneShot` short-circuit is handled by the caller.
    private static func inferFromCadence(
        _ cadence: Cadence,
        sub baseSub: CadenceSubControls,
        now: Date,
        calendar: Calendar
    ) -> (kind: CadenceKind, sub: CadenceSubControls) {
        var sub = baseSub
        switch cadence {
        case .daily:
            return (.daily, sub)
        case let .weekdays(days):
            sub.weekdays = days.isEmpty ? [.mon] : days
            return (.weekdays, sub)
        case let .everyNWeeks(interval, days):
            sub.intervalWeeks = clamp(interval, 1, 52)
            sub.weekdays = days.isEmpty ? [.mon] : days
            return (.everyNWeeks, sub)
        case let .monthly(day):
            sub.dayOfMonth = clamp(day, 1, 31)
            return (.monthly, sub)
        case let .everyNMonths(interval, day):
            sub.intervalMonths = clamp(interval, 1, 12)
            sub.dayOfMonth = clamp(day, 1, 31)
            return (.everyNMonths, sub)
        case let .yearly(month, day):
            sub.yearlyDate = dateFrom(month: month, day: day, now: now, calendar: calendar)
            return (.yearly, sub)
        case let .rolling(intervalDays):
            sub.rollingDays = clamp(intervalDays, 1, 365)
            return (.rolling, sub)
        case let .cyclic(weeksOn, weeksOff):
            sub.cyclicOnWeeks = max(1, weeksOn)
            sub.cyclicOffWeeks = max(0, weeksOff)
            return (.cyclic, sub)
        case .oneShot:
            return (.oneShot, sub)
        case .asNeeded:
            return (.asNeeded, sub)
        case let .legacy(days, intervalWeeks):
            return inferLegacy(days: days, intervalWeeks: intervalWeeks, sub: sub)
        }
    }

    /// Mirror of `inferCadenceFromLegacy` (`legacy-bridge.ts`): empty days +
    /// interval 1 → daily; days + interval 1 → weekdays; interval > 1 →
    /// everyNWeeks. Extracted so `infer` stays under the cyclomatic budget.
    private static func inferLegacy(
        days: Set<Weekday>?,
        intervalWeeks: Int,
        sub baseSub: CadenceSubControls
    ) -> (kind: CadenceKind, sub: CadenceSubControls) {
        var sub = baseSub
        let set = days ?? []
        if set.isEmpty, intervalWeeks <= 1 {
            return (.daily, sub)
        }
        if intervalWeeks > 1 {
            sub.intervalWeeks = clamp(intervalWeeks, 1, 52)
            sub.weekdays = set.isEmpty ? [.mon] : set
            return (.everyNWeeks, sub)
        }
        sub.weekdays = set
        return (.weekdays, sub)
    }

    // MARK: - Validation (mirror server cross-field invariants)

    /// Cross-field cadence/course validity, mirroring the server's
    /// `medication.ts` refines + `route.ts` invariants:
    ///
    /// - rrule XOR rolling (the encoder guarantees this; asserted defensively).
    /// - `oneShot ⇒ startsOn set & no recurrence`.
    /// - `endsOn ≥ startsOn`.
    /// - `rolling ⇒ ≤ 1 time-of-day`.
    /// - `asNeeded ⇒ no recurrence / no times / no grace`.
    /// - `cyclic ⇒ weeksOn ≥ 1 & weeksOff ≥ 0`. **09-14 — no anchor clause.**
    ///   The old rule also demanded a per-schedule anchor, which was a form
    ///   field with no wire destination. The phase is counted from the course
    ///   start (`startsOn`), and the server falls back to the medication's
    ///   creation day when there is none — so requiring `startsOn` here would be
    ///   a new hard gate on an edit that previously saved, with no evidence to
    ///   justify it. The course-start picker in `CourseWindowRow` is the handle.
    static func isCadenceValid(
        value: CadenceValue,
        times: [TimeOfDay],
        startsOn: Date?,
        endsOn: Date?,
        graceMinutes: Int?
    ) -> Bool {
        // rrule XOR rolling.
        if value.rrule != nil, value.rollingIntervalDays != nil { return false }

        if let startsOn, let endsOn, endsOn < startsOn { return false }

        switch value.kind {
        case .oneShot:
            return startsOn != nil && value.rrule == nil && value.rollingIntervalDays == nil
        case .rolling:
            return times.count <= 1
        case .asNeeded:
            return value.rrule == nil
                && value.rollingIntervalDays == nil
                && times.isEmpty
                && graceMinutes == nil
        case .cyclic:
            guard let on = value.cyclicOnWeeks, on >= 1,
                  let off = value.cyclicOffWeeks, off >= 0 else { return false }
            return true
        case .daily, .weekdays, .everyNWeeks, .monthly, .everyNMonths, .yearly:
            return !times.isEmpty
        }
    }

    /// Max number of reminder times the cadence allows. Rolling accepts ≤ 1
    /// (server refine); PRN accepts 0; everything else ≤ 8.
    static func maxTimes(for kind: CadenceKind) -> Int {
        switch kind {
        case .rolling: 1
        case .asNeeded: 0
        case .daily, .weekdays, .everyNWeeks, .monthly, .everyNMonths, .yearly,
             .cyclic, .oneShot:
            8
        }
    }

    // MARK: - RMW: did the schedule change?

    /// Schedule-shaping snapshot used to decide whether an edit must rebuild
    /// `schedules` on the PUT. When nothing in this snapshot changed the PUT
    /// omits `schedules` (sends `nil`) so the server-side replace keeps the
    /// decoded rrule/rolling/asNeeded/cyclic untouched (R1 risk 5 — RMW-safety).
    struct ScheduleSnapshot: Equatable {
        var cadenceKind: CadenceKind
        var cadenceSub: CadenceSubControls
        var times: [TimeOfDay]
        var startsOn: Date?
        var endsOn: Date?
        var isOneShot: Bool
        var graceMinutes: Int?
        /// Resolved raw per-slot doses. Part of the snapshot because a
        /// slot-dose-only edit IS a schedule change: without it the PUT would
        /// omit `schedules` and the user's choice would be discarded in silence.
        var slotUnitsPerDose: [String: Double] = [:]
    }

    /// `true` when any schedule-shaping field differs from the prefill baseline.
    /// A `nil` baseline (defensive) forces a rebuild.
    static func scheduleDidChange(
        baseline: ScheduleSnapshot?,
        current: ScheduleSnapshot
    ) -> Bool {
        guard let baseline else { return true }
        return baseline != current
    }

    // MARK: - Build the wire DTO array

    /// Build the `MedicationScheduleDTO` array for the new cadence model. Emits
    /// only keys the accepted `MedicationScheduleInput` declares: `timesOfDay` +
    /// `rrule` / `rollingIntervalDays` + `reminderGraceMinutes` + `scheduleType`
    /// + the cyclic pair. One-shot and PRN emit a single schedule row; the
    /// calendar/rolling kinds carry every time in one row's `timesOfDay` array
    /// (the server fans them out per matched day).
    ///
    /// **09-14 — the cyclic row now carries `scheduleType: CYCLIC`.** Without
    /// the discriminator the published schema says the two week counts are
    /// "ignored otherwise", so a cyclic save was created as a plain SCHEDULED
    /// row that the create route then stamped `rrule = "FREQ=DAILY"`.
    static func buildSchedules(
        value: CadenceValue,
        times: [TimeOfDay],
        graceMinutes: Int?,
        calendar: Calendar = .current,
        existingDoseWindows: [MedicationDoseWindowDTO]? = nil,
        slotUnitsPerDose: [String: Double] = [:]
    ) -> [MedicationScheduleDTO] {
        let sortedTimes = times.sorted()
        let timeStrings = sortedTimes.map(MedicationFormLogic.formatTime)
        let primary = sortedTimes.first ?? TimeOfDay(hour: 8, minute: 0)
        let windowStart = MedicationFormLogic.formatTime(primary)
        // #219 — the raw per-slot inventory dose is subject to exactly the
        // same REPLACE hazard as the dose windows below: a rebuilt row that
        // omits it is created with `unitsPerDose` NULL, i.e. the user's
        // explicit ½-tablet slot silently falls back to inheritance. The
        // grouping keeps the historical single-row shape whenever the slots
        // agree and only fans out when they cannot be expressed as one row.
        let groups = slotGroups(
            timeStrings.isEmpty ? [windowStart] : timeStrings,
            slotUnitsPerDose: slotUnitsPerDose
        )

        switch value.kind {
        case .asNeeded:
            // PRN — **no schedule rows at all.** A whole-medication PRN is the
            // MEDICATION-level `asNeeded: true` with an empty `schedules` array;
            // the route 422s any entry alongside the flag. The pairing is built
            // by `scheduleWrite` — never call this branch without it, or the
            // empty array arrives unflagged and the route 422s the other way.
            return []
        case .cyclic:
            return groups.map { group in
                MedicationScheduleDTO(
                    windowStart: group.times.first ?? windowStart,
                    windowEnd: group.times.first ?? windowStart,
                    unitsPerDose: group.unitsPerDose,
                    timesOfDay: timeStrings.isEmpty ? nil : group.times,
                    reminderGraceMinutes: graceMinutes,
                    cyclicOnWeeks: value.cyclicOnWeeks,
                    cyclicOffWeeks: value.cyclicOffWeeks,
                    scheduleType: .cyclic,
                    doseWindows: windows(existingDoseWindows, group: group, surviving: timeStrings)
                )
            }
        case .oneShot:
            // One-shot — medication-level `oneShot`; the schedule row carries no
            // recurrence, just the single dose time.
            return groups.map { group in
                MedicationScheduleDTO(
                    windowStart: group.times.first ?? windowStart,
                    windowEnd: group.times.first ?? windowStart,
                    unitsPerDose: group.unitsPerDose,
                    timesOfDay: timeStrings.isEmpty ? nil : group.times,
                    reminderGraceMinutes: graceMinutes,
                    doseWindows: windows(existingDoseWindows, group: group, surviving: timeStrings)
                )
            }
        case .rolling:
            return groups.map { group in
                MedicationScheduleDTO(
                    windowStart: group.times.first ?? windowStart,
                    windowEnd: group.times.first ?? windowStart,
                    unitsPerDose: group.unitsPerDose,
                    timesOfDay: timeStrings.isEmpty ? nil : group.times,
                    rollingIntervalDays: value.rollingIntervalDays,
                    reminderGraceMinutes: graceMinutes,
                    doseWindows: windows(existingDoseWindows, group: group, surviving: timeStrings)
                )
            }
        case .daily, .weekdays, .everyNWeeks, .monthly, .everyNMonths, .yearly:
            return groups.map { group in
                MedicationScheduleDTO(
                    windowStart: group.times.first ?? windowStart,
                    windowEnd: group.times.first ?? windowStart,
                    unitsPerDose: group.unitsPerDose,
                    timesOfDay: timeStrings.isEmpty ? nil : group.times,
                    rrule: value.rrule,
                    reminderGraceMinutes: graceMinutes,
                    doseWindows: windows(existingDoseWindows, group: group, surviving: timeStrings)
                )
            }
        }
    }

    /// The `schedules` array and the medication-level `asNeeded` flag as ONE
    /// value, because the accepted contract treats them as one.
    ///
    /// `UpdateMedicationRequest` and `CreateMedicationRequest` enforce the
    /// pairing in both directions: `asNeeded: true` alongside any schedule entry
    /// is a 422, and an empty `schedules` array without `asNeeded: true` is
    /// likewise a 422. Two independent expressions in two sheets is exactly how
    /// those drift, so both sheets take the pair from here and neither names
    /// `asNeeded` on its own.
    ///
    /// The flag is always a real boolean, never nil, whenever the schedule was
    /// rebuilt — switching a PRN medication back to a scheduled cadence has to
    /// send `asNeeded: false`, and an omitted key would leave it PRN forever.
    /// A caller that did not touch the schedule sends `nil` for both by not
    /// calling this at all.
    static func scheduleWrite(
        value: CadenceValue,
        times: [TimeOfDay],
        graceMinutes: Int?,
        calendar: Calendar = .current,
        existingDoseWindows: [MedicationDoseWindowDTO]? = nil,
        slotUnitsPerDose: [String: Double] = [:]
    ) -> (schedules: [MedicationScheduleDTO], asNeeded: Bool) {
        let schedules = buildSchedules(
            value: value,
            times: times,
            graceMinutes: graceMinutes,
            calendar: calendar,
            existingDoseWindows: existingDoseWindows,
            slotUnitsPerDose: slotUnitsPerDose
        )
        return (schedules, value.asNeeded)
    }

    /// W3-MEDCONTRACT (v0.14.8) — RMW echo of the per-dose on-time windows
    /// (v1.15.18): a `schedules` REPLACE re-creates the rows server-side and
    /// resets an omitted `doseWindows` to NULL, wiping bands the user
    /// configured on the web. Echo every window whose dose time survives this
    /// edit and belongs to this row (server refine: each window's `timeOfDay`
    /// must match one of the row's `timesOfDay` entries, no duplicates). A
    /// cadence with no dose times carries no windows at all, exactly as before.
    private static func windows(
        _ existing: [MedicationDoseWindowDTO]?,
        group: (times: [String], unitsPerDose: Double?),
        surviving timeStrings: [String]
    ) -> [MedicationDoseWindowDTO]? {
        echoDoseWindows(existing, surviving: timeStrings.isEmpty ? [] : group.times)
    }

    /// Filter the decoded per-dose windows down to the dose times that
    /// survive a schedule edit, de-duplicated by `timeOfDay` (first wins —
    /// mirrors the server's "must not repeat a timeOfDay" refine). Returns
    /// `nil` when nothing survives so the wire body omits the key.
    static func echoDoseWindows(
        _ existing: [MedicationDoseWindowDTO]?,
        surviving timeStrings: [String]
    ) -> [MedicationDoseWindowDTO]? {
        guard let existing, !existing.isEmpty else { return nil }
        let survivors = Set(timeStrings)
        var seen = Set<String>()
        let echoed = existing.filter { window in
            guard survivors.contains(window.timeOfDay) else { return false }
            return seen.insert(window.timeOfDay).inserted
        }
        return echoed.isEmpty ? nil : echoed
    }

    /// ISO `YYYY-MM-DD` for a course-window / cyclic-anchor date, emitting the
    /// LOCAL wall-clock day the user actually picked.
    ///
    /// The date arrives as a local-midnight `Date` (SwiftUI date pickers +
    /// `calendar.startOfDay(for:)`), so its calendar day must be read back in the
    /// SAME local calendar. The previous implementation read UTC day-components of
    /// that local-midnight instant, which rolled the stored day BACK one calendar
    /// day for users east of UTC (Berlin/UTC+2: 10 Jul local-midnight = 09 Jul
    /// 22:00 UTC → "2026-07-09"), storing course `startsOn`/`endsOn` and cyclic
    /// anchors a day early (dropped final-day doses, cyclic on/off weeks inverted).
    /// The old UTC-first `comps.year ?? local.year` fallback was dead code —
    /// `dateComponents` never returns nil for a valid date — so the intended
    /// local-wall-clock path never ran.
    ///
    /// The emitted bare date string carries no time zone; the server's `@db.Date`
    /// stores exactly this calendar day. Mirrors the noon-UTC day anchoring in
    /// ``RecordsDateFormat/onsetInstant(forDay:)``.
    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2000
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Internal helpers

    private static func value(
        _ kind: CadenceKind,
        rrule: String? = nil,
        rollingIntervalDays: Int? = nil,
        oneShot: Bool = false,
        asNeeded: Bool = false,
        cyclicOnWeeks: Int? = nil,
        cyclicOffWeeks: Int? = nil
    ) -> CadenceValue {
        CadenceValue(
            kind: kind,
            rrule: rrule,
            rollingIntervalDays: rollingIntervalDays,
            oneShot: oneShot,
            asNeeded: asNeeded,
            cyclicOnWeeks: cyclicOnWeeks,
            cyclicOffWeeks: cyclicOffWeeks
        )
    }

    /// Encode a weekday set into a BYDAY token list, Mon→Sun (the wizard's
    /// canonical ordering — matches `RRULE.encodeByDay`).
    private static func byDay(_ days: [Weekday]) -> String {
        let order: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
        let set = Set(days)
        return order
            .filter { set.contains($0) }
            .compactMap { RRULE.weekdayTokens[$0] }
            .joined(separator: ",")
    }

    private static func dateFrom(
        month: Int,
        day: Int,
        now: Date,
        calendar: Calendar
    ) -> Date {
        var comps = calendar.dateComponents([.year], from: now)
        comps.month = max(1, min(12, month))
        comps.day = max(1, min(31, day))
        return calendar.date(from: comps) ?? now
    }

    private static func clamp(_ n: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, n))
    }
}

// MARK: - Per-slot raw inventory dose (#219 / v1.37.19)

/// The raw / resolved per-slot dose helpers, in an extension so the enum body
/// stays inside the `type_body_length` budget instead of growing a baselined
/// warning. Behaviourally these are members of ``MedicationCadenceLogic``.
extension MedicationCadenceLogic {
    /// The user's RAW per-slot `unitsPerDose` intent, keyed by the `HH:mm` dose
    /// time — the shape an edit surface holds between prefill and save.
    ///
    /// The three cases are three different sentences and the middle one is the
    /// reason this is not a `Double?`:
    ///
    /// - `.unchanged` — the user never opened this slot. The rebuild has to
    ///   echo whatever the server sent, or the REPLACE deletes it.
    /// - `.clear` — the user chose inheritance. The rebuilt row carries no
    ///   `unitsPerDose`, which is how the accepted `MedicationScheduleInput`
    ///   spells "inherit `Medication.unitsPerDose`" ("Omitted / NULL means the
    ///   schedule inherits"). The published input type is a bare `number`, not
    ///   a nullable union, so an explicit JSON `null` is NOT the clear here —
    ///   omission is, and inside a REPLACE the two are the same server state
    ///   anyway because the row is created fresh.
    /// - `.set(v)` — an explicit per-slot override.
    ///
    /// ``RecordPatchField`` is reused rather than re-invented because it is
    /// already this codebase's tri-state; only its ``RecordPatchField/encode(into:forKey:)``
    /// helper is deliberately not used, for the omission-versus-null reason above.
    typealias SlotDoseIntents = [String: RecordPatchField<Double>]

    /// The RAW per-slot overrides the server sent, keyed by `HH:mm`. A slot the
    /// server left `null` is ABSENT from the map — inheritance is not zero and
    /// is not an override, and inventing an entry for it would promote it into
    /// one on the next save.
    static func rawSlotUnitsPerDose(from entries: [ScheduleEntry]) -> [String: Double] {
        var map: [String: Double] = [:]
        for entry in entries {
            guard let raw = entry.unitsPerDose else { continue }
            for time in entry.effectiveTimes {
                map[MedicationFormLogic.formatTime(time)] = raw
            }
        }
        return map
    }

    /// The server-EFFECTIVE per-slot dose (`ScheduleEntry.resolvedUnitsPerDose`),
    /// keyed by `HH:mm`, read verbatim. This is display truth for the edit
    /// surface: it answers "what does this slot consume today" without the
    /// client re-deriving `schedule.unitsPerDose ?? medication.unitsPerDose`,
    /// and it never crosses a write — `MedicationScheduleDTO.encode(to:)` does
    /// not name the key.
    static func serverEffectiveUnitsPerDose(from entries: [ScheduleEntry]) -> [String: Double] {
        var map: [String: Double] = [:]
        for entry in entries {
            guard let resolved = entry.resolvedUnitsPerDose else { continue }
            for time in entry.effectiveTimes {
                map[MedicationFormLogic.formatTime(time)] = resolved
            }
        }
        return map
    }

    /// Apply the form's tri-state intents onto the decoded raw values. An
    /// untouched slot keeps what the server sent; a cleared slot drops out of
    /// the map (and therefore out of the wire body); a set slot takes its value.
    static func resolveSlotUnitsPerDose(
        existing: [String: Double],
        intents: SlotDoseIntents
    ) -> [String: Double] {
        var resolved = existing
        for (time, intent) in intents {
            switch intent {
            case .unchanged:
                continue
            case .clear:
                resolved[time] = nil
            case let .set(value):
                resolved[time] = value
            }
        }
        return resolved
    }

    /// Group the surviving dose times into the schedule rows a rebuild has to
    /// emit so that no per-slot raw dose is lost.
    ///
    /// iOS models a cadence as ONE row carrying every dose time, while the
    /// server stores one row per slot — which is why `unitsPerDose` is per row.
    /// As long as every surviving slot agrees on its raw dose (the ordinary
    /// case, and the only case before #219) the single combined row still says
    /// everything there is to say, and that shape is kept byte for byte. When
    /// the slots DISAGREE the combined row cannot express them, so the rebuild
    /// adopts the server's own one-row-per-slot shape rather than silently
    /// picking one value for all of them.
    static func slotGroups(
        _ times: [String],
        slotUnitsPerDose: [String: Double]
    ) -> [(times: [String], unitsPerDose: Double?)] {
        guard let first = times.first else { return [(times: [], unitsPerDose: nil)] }
        let shared = slotUnitsPerDose[first]
        if times.allSatisfy({ slotUnitsPerDose[$0] == shared }) {
            return [(times: times, unitsPerDose: shared)]
        }
        return times.map { (times: [$0], unitsPerDose: slotUnitsPerDose[$0]) }
    }
}
