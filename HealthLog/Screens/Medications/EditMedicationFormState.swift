import Foundation

/// Pure mapping helper — given a `Medication`, produce the form-state the
/// `EditMedicationSheet`'s `@State` variables get pre-filled with. Extracted as
/// `internal` for testability; the view itself calls this implicitly via
/// `prefillOnce`. Lives in its own file (08-21) so the sheet stays under the
/// file-length budget after the per-slot dose fields below.
struct EditMedicationFormState: Equatable {
    var name: String
    var dose: String
    var times: [TimeOfDay]
    var category: MedicationCategoryOption
    var treatmentClass: MedicationTreatmentClassOption
    var dosesPerUnitText: String
    var unitsPerDose: MedicationUnitsPerDose
    /// **#219 — the RAW per-slot inventory-units overrides, keyed by `HH:mm`.**
    /// A slot the server left `null` is ABSENT here: inheritance is a choice in
    /// its own right and rebuilding it from the resolved figure below would
    /// promote it into an explicit override the user never made.
    var slotUnitsPerDose: [String: Double]
    /// **v1.37.19 — the server-EFFECTIVE per-slot dose, keyed by `HH:mm`.**
    /// Read-only truth: what the server says each slot consumes today, resolved
    /// by the same resolver the intake consumption path uses. The edit surface
    /// displays it and never writes it (`MedicationScheduleDTO.encode(to:)`
    /// drops the wire key), and nothing here derives it from the raw map.
    var serverEffectiveUnitsPerDose: [String: Double]
    var notificationsEnabled: Bool
    var deliveryForm: MedicationDeliveryFormOption
    var trackInjectionSites: Bool
    var allowedInjectionSites: Set<InjectionSite>
    var cadenceKind: CadenceKind
    var cadenceSub: CadenceSubControls
    var startsOn: Date?
    var endsOn: Date?
    var isOneShot: Bool
    var graceMinutes: Int?

    init(from medication: Medication) {
        name = medication.name
        dose = medication.dose
        // PRN carries no schedule times; otherwise pre-fill from the schedule.
        //
        // **Every entry's times, not the first row's.** The server stores one
        // schedule row per slot (a two-dose medication is two rows, each with a
        // single `timesOfDay`), and `schedules` is a REPLACE — so a form that
        // only ever saw row 0 would delete every other row, with its label, its
        // grace and its raw `unitsPerDose`, on the next schedule save.
        // `MedicationSchedule.times` is the flattened, sorted union of every
        // entry's effective times and is identical to the old read for the
        // single-row case. Falls back to a single 08:00 default for an empty
        // list.
        let unionTimes = Self.uniqueSorted(medication.schedule.times)
        times = unionTimes.isEmpty ? [TimeOfDay(hour: 8, minute: 0)] : unionTimes
        slotUnitsPerDose = MedicationCadenceLogic.rawSlotUnitsPerDose(from: medication.schedule.entries)
        serverEffectiveUnitsPerDose = MedicationCadenceLogic
            .serverEffectiveUnitsPerDose(from: medication.schedule.entries)
        if let raw = medication.category, let opt = MedicationCategoryOption(rawValue: raw) {
            category = opt
        } else {
            category = .other
        }
        if let raw = medication.treatmentClass, let opt = MedicationTreatmentClassOption(rawValue: raw) {
            treatmentClass = opt
        } else {
            treatmentClass = .generic
        }
        dosesPerUnitText = medication.dosesPerUnit.map(String.init) ?? ""
        unitsPerDose = MedicationUnitsPerDose.from(decimal: medication.unitsPerDose ?? 1)
        notificationsEnabled = medication.notificationsEnabled
        deliveryForm = MedicationDeliveryFormOption.from(wire: medication.deliveryForm)
        trackInjectionSites = medication.trackInjectionSites
        allowedInjectionSites = Set(medication.allowedInjectionSites)

        // Cadence inference (mirror inferCadenceFromLegacy + v1.5/v1.7 cases).
        let inferred = MedicationCadenceLogic.infer(from: medication)
        cadenceKind = inferred.kind
        cadenceSub = inferred.sub
        startsOn = medication.startsOn
        endsOn = medication.endsOn
        isOneShot = medication.oneShot
        graceMinutes = medication.schedule.entries.first?.reminderGraceMinutes
    }

    /// De-duplicate the flattened union while keeping it sorted. Two server rows
    /// may legitimately share a dose time (different labels); the form shows one
    /// row per time, and a duplicated time would otherwise render twice and be
    /// written twice into one `timesOfDay` array (a server refine 422).
    private static func uniqueSorted(_ times: [TimeOfDay]) -> [TimeOfDay] {
        var seen: Set<TimeOfDay> = []
        return times.filter { seen.insert($0).inserted }.sorted()
    }
}

/// **15-02 (B3) — where the medication editor's keyboard belongs.**
///
/// The editor drives an `@FocusState`, which no test can read and no reader can
/// reason about outside a view host. But every decision that MOVES that focus
/// is pure — the sheet settled, return was pressed, the Zeitplan row became the
/// interaction target — so the decisions live here as one transition function
/// and the view keeps the single copy of the truth.
///
/// `sheetSettled` and `submitted` reproduce the FORM-2 conveniences (initial
/// focus on the name field, name → dose submit chain) exactly as
/// `EditMedicationSheet` performed them before.
enum MedicationEditorFocus {
    /// The editor's two text fields. Was `EditMedicationSheet.Field`.
    enum Field: Hashable {
        case name, dose
    }

    /// What the editor can report. One case per real interaction — nothing here
    /// is synthesised.
    enum Event: Equatable {
        /// The sheet finished presenting (`.task` + `HLSheet.focusDelay`).
        case sheetSettled
        /// Return was pressed in `Field`.
        case submitted(Field)
        /// The Zeitplan section became the interaction target: the cadence
        /// picker, one of its sub-controls, or the dose-times list was touched.
        case scheduleEditorEngaged
    }

    /// Where focus belongs after `event`, given where it is now.
    static func resolve(_ event: Event, from current: Field?) -> Field? {
        switch event {
        case .sheetSettled:
            .name
        case let .submitted(origin):
            // FORM-2 submit chain: name → dose, dose → done.
            origin == .name ? .dose : nil
        case .scheduleEditorEngaged:
            // B3 — the schedule options are the interaction target now, and a
            // keyboard over the control being operated is a dead end. Nowhere,
            // not "the previous field": the editor only ever regains focus by
            // the user choosing a field, so this cannot fight anyone for it.
            nil
        }
    }
}

/// The per-slot dose choice the edit sheet's picker offers for one dose time:
/// inherit the medication-level `unitsPerDose`, or override it with one of the
/// curated units. Distinct from ``MedicationUnitsPerDose`` because "inherit" is
/// not a number — it is the absence of one, and the whole point of #219's raw
/// field is that the two can be told apart.
enum SlotDoseSelection: Hashable {
    case inherit
    case override(MedicationUnitsPerDose)
}
