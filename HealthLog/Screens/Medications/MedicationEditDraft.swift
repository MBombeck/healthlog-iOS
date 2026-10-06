import Foundation

/// **R1 — what the medication editor sends, as a value.**
///
/// The edit sheet's `save()` used to assemble its `MedicationPatch` inline from
/// two dozen `@State` values, so the one question that matters for a server
/// write — which keys does an edit name? — could not be asked without a view
/// host. The sheet now copies its state into this draft and the draft builds
/// the patch; a test can open a draft on a served medication, change one field
/// and read the exact body.
///
/// Read-modify-write rules carried over unchanged: `schedules` (and the course
/// fields) only when the schedule was touched, `unitsPerDose` only when it
/// changed, `trackIntake` per ``MedicationTrackIntakeWrite``.
///
/// **New (server v1.39.4 #1041, still open on v1.39.6):** `category` and
/// `treatmentClass` are named only when the person changed that row. The old
/// editor always sent `category`, and opened any category it had no row for on
/// "Other" — so editing the dose time of a diabetes, antibiotic or mental
/// health medication stored OTHER. Whatever a later server adds is now kept the
/// same way: an unknown category opens as itself (`category == nil`) and is
/// never written back as something else.
struct MedicationEditDraft: Equatable {
    var name: String
    var dose: String
    var times: [TimeOfDay]
    /// `nil` = the stored category is one this build has no row for.
    var category: MedicationCategoryOption?
    var categoryBaseline: MedicationCategoryOption?
    var treatmentClass: MedicationTreatmentClassOption
    var treatmentClassBaseline: MedicationTreatmentClassOption
    var dosesPerUnitText: String
    var unitsPerDose: MedicationUnitsPerDose
    var unitsPerDoseBaseline: MedicationUnitsPerDose
    var notificationsEnabled: Bool
    var deliveryForm: MedicationDeliveryFormOption
    var trackInjectionSites: Bool
    var allowedInjectionSites: Set<InjectionSite>
    var cadenceKind: CadenceKind
    var cadenceSub: CadenceSubControls
    var startsOn: Date?
    var endsOn: Date?
    var isOneShot: Bool
    /// `nil` when the grace switch is off.
    var graceMinutes: Int?
    /// The resolved raw per-slot doses (baseline merged with the edits).
    var slotUnitsPerDose: [String: Double]
    var intake: MedicationTrackIntakeFormValue
    var scheduleBaseline: MedicationCadenceLogic.ScheduleSnapshot?
    /// The delivery booleans the PUT carries (`nil` = leave the server value).
    var liveActivityEnabled: Bool?
    var criticalAlarmEnabled: Bool?

    /// A draft exactly as the editor opens on `state`: every baseline equals
    /// its value, so an untouched save names nothing it does not have to.
    init(prefill state: EditMedicationFormState) {
        name = state.name
        dose = state.dose
        times = state.times
        category = state.category
        categoryBaseline = state.category
        treatmentClass = state.treatmentClass
        treatmentClassBaseline = state.treatmentClass
        dosesPerUnitText = state.dosesPerUnitText
        unitsPerDose = state.unitsPerDose
        unitsPerDoseBaseline = state.unitsPerDose
        notificationsEnabled = state.notificationsEnabled
        deliveryForm = state.deliveryForm
        trackInjectionSites = state.trackInjectionSites
        allowedInjectionSites = state.allowedInjectionSites
        cadenceKind = state.cadenceKind
        cadenceSub = state.cadenceSub
        startsOn = state.startsOn
        endsOn = state.endsOn
        isOneShot = state.isOneShot
        graceMinutes = state.graceMinutes
        slotUnitsPerDose = state.slotUnitsPerDose
        intake = MedicationTrackIntakeFormValue(tracked: state.trackIntake, server: state.serverTrackIntake)
        scheduleBaseline = Self.snapshot(of: state)
        liveActivityEnabled = nil
        criticalAlarmEnabled = nil
    }

    static func snapshot(of state: EditMedicationFormState) -> MedicationCadenceLogic.ScheduleSnapshot {
        MedicationCadenceLogic.ScheduleSnapshot(
            cadenceKind: state.cadenceKind,
            cadenceSub: state.cadenceSub,
            times: state.times,
            startsOn: state.startsOn,
            endsOn: state.endsOn,
            isOneShot: state.isOneShot,
            graceMinutes: state.graceMinutes,
            slotUnitsPerDose: state.slotUnitsPerDose
        )
    }

    private var scheduleTimes: [TimeOfDay] {
        cadenceKind == .asNeeded ? [] : times
    }

    /// Did the person touch any schedule-shaping field since prefill? When
    /// false the PUT omits `schedules`, so the server keeps its decoded
    /// rrule/rolling/asNeeded/cyclic untouched (RMW-safety, R1 risk 5).
    var scheduleDidChange: Bool {
        MedicationCadenceLogic.scheduleDidChange(
            baseline: scheduleBaseline,
            current: MedicationCadenceLogic.ScheduleSnapshot(
                cadenceKind: cadenceKind,
                cadenceSub: cadenceSub,
                times: times,
                startsOn: startsOn,
                endsOn: endsOn,
                isOneShot: isOneShot,
                graceMinutes: graceMinutes,
                slotUnitsPerDose: slotUnitsPerDose
            )
        )
    }

    /// The `PUT /api/medications/{id}` body for this draft.
    func patch(for medication: Medication) -> MedicationsRepository.MedicationPatch {
        let value = MedicationCadenceLogic.encode(cadenceKind, cadenceSub)
        let scheduleChanged = scheduleDidChange
        // A rebuild echoes the decoded per-dose windows and raw per-slot doses
        // for every surviving dose time (a `schedules` REPLACE resets omitted
        // ones), and carries `asNeeded` with `schedules` as one value (the
        // route 422s either half without the other).
        let write = scheduleChanged
            ? MedicationCadenceLogic.scheduleWrite(
                value: value,
                times: scheduleTimes,
                graceMinutes: graceMinutes,
                existingDoseWindows: medication.displaySchedule.entries.compactMap(\.doseWindows).flatMap { $0 },
                slotUnitsPerDose: slotUnitsPerDose
            )
            : nil
        return MedicationsRepository.MedicationPatch(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dose: dose.trimmingCharacters(in: .whitespacesAndNewlines),
            treatmentClass: treatmentClass != treatmentClassBaseline ? treatmentClass.wireValue : nil,
            dosesPerUnit: MedicationFormLogic.parseDosesPerUnit(dosesPerUnitText),
            unitsPerDose: unitsPerDose != unitsPerDoseBaseline ? unitsPerDose.decimalValue : nil,
            category: category != categoryBaseline ? category?.wireValue : nil,
            active: medication.active,
            notificationsEnabled: notificationsEnabled,
            schedules: write?.schedules,
            oneShot: scheduleChanged ? value.oneShot : nil,
            startsOn: scheduleChanged ? startsOn.map { MedicationCadenceLogic.courseDay($0) } : nil,
            endsOn: scheduleChanged && !value.oneShot ? endsOn.map { MedicationCadenceLogic.courseDay($0) } : nil,
            deliveryForm: deliveryForm.wireValue,
            liveActivityEnabled: liveActivityEnabled,
            criticalAlarmEnabled: criticalAlarmEnabled,
            // Injection-site fields only for an INJECTION med (RMW-safe otherwise).
            trackInjectionSites: deliveryForm == .injection ? trackInjectionSites : nil,
            allowedInjectionSites: deliveryForm == .injection && trackInjectionSites
                ? allowedInjectionSites.compactMap(\.serverRawValue).sorted()
                : nil,
            // A real boolean whenever the schedule was rebuilt, never nil: an
            // omitted key would leave a once-PRN medication PRN forever.
            asNeeded: write?.asNeeded,
            trackIntake: MedicationTrackIntakeWrite.value(intake, scheduleChanged: scheduleChanged)
        )
    }
}
