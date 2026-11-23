import SwiftUI

// T-6 wiring (therapy-interim-merge, 2026-05-16): PhotoOfMedSheet is
// presented from a leading-toolbar `camera.viewfinder` button. The sheet
// hands back a `MedicationDraft` via an async callback; we prefill ONLY
// empty form fields from the draft, never overwriting user input. This
// closes the `// TODO(T-6-merge)` marker established by T-3.

/// Presented from `MedicationsScreen` "+" toolbar button. Renders a
/// progressive-disclosure form: required fields (name, dose) are
/// unconditionally visible; the v0.10 cadence picker drives the schedule
/// shape (daily / weekday / rolling / cyclic / PRN / one-shot / …); advanced
/// fields (category, treatment class, grace, delivery form) live in an opt-in
/// expandable section.
///
/// Save enqueues via `MedicationsRepository.create(...)`. On
/// `.success` / `.queued` the sheet dismisses; on `.failed` an inline
/// error banner is rendered above the toolbar.
struct AddMedicationSheet: View {
    let onSaved: () -> Void

    @Environment(MedicationsStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Required fields
    @State private var name: String = ""
    @State private var dose: String = ""
    @State private var times: [ScheduleTimeRow] = [ScheduleTimeRow(time: TimeOfDay(hour: 8, minute: 0))]

    // Cadence + course window
    @State private var cadenceKind: CadenceKind = .daily
    @State private var cadenceSub: CadenceSubControls = .makeDefault()
    @State private var startsOn: Date?
    @State private var endsOn: Date?
    @State private var isOneShot: Bool = false

    // Optional / progressive
    @State private var showAdvanced: Bool = false
    @State private var category: MedicationCategoryOption = .other
    @State private var treatmentClass: MedicationTreatmentClassOption = .generic
    @State private var dosesPerUnitText: String = ""
    /// **H1/H2** — units one dose consumes (whole / curated fraction).
    @State private var unitsPerDose: MedicationUnitsPerDose = .whole(1)
    @State private var notificationsEnabled: Bool = true
    @State private var deliveryForm: MedicationDeliveryFormOption = .unspecified
    @State private var graceEnabled: Bool = false
    @State private var graceMinutes: Int = 60
    // Injection-site tracking (only meaningful for INJECTION route).
    @State private var trackInjectionSites: Bool = false
    @State private var allowedInjectionSites: Set<InjectionSite> = []
    /// v1.39.1 — the intake-tracking switch, offered when the server knows it.
    @State private var trackIntake: Bool = true

    // UI state
    @State private var isSaving: Bool = false
    @State private var saveError: HLError?
    @State private var showPhotoOfMedSheet: Bool = false
    /// Save haptic drivers. The primary Save fired no haptic
    /// (the operator-flagged ship-criterion area). `saveTick` bumps on a
    /// successful/queued write, `saveErrorTick` on a failure, mirroring the
    /// `MedicationQuickIntakeSheet` `.success`/`.error` pattern exactly.
    @State private var saveTick: Int = 0
    @State private var saveErrorTick: Int = 0
    @State private var baseline: [AnyHashable]? // the form as it opened, for the discard guard
    /// Initial focus + name→dose submit chain.
    /// The SAME vocabulary the editor focuses through, not
    /// a second private copy of it. `MedicationEditorFocus` owns every decision
    /// that moves focus; the sheet keeps the only copy of where focus IS.
    @FocusState private var focusedField: MedicationEditorFocus.Field?

    var body: some View {
        HLSheetScaffold(
            "med.add.title",
            action: .add(isEnabled: isValid) { await save() },
            isDirty: isDirty
        ) {
            Form {
                photoOfMedSection
                requiredSection
                if Medication.serverKnowsTrackIntake(store.medications) { MedicationTrackIntakeSection(isOn: $trackIntake) }
                cadenceSection
                if cadenceKind != .asNeeded {
                    scheduleSection.simultaneousGesture(scheduleEngagement, including: .all)
                }
                courseWindowSection
                advancedSection
                if let saveError {
                    Section {
                        HLFormErrorText(saveError.userFacingDescription)
                            .font(.hlSubhead)
                    }
                    .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .hlScrollEdgeSoft()
            // A drag puts the keyboard away as it goes.
            .scrollDismissesKeyboard(.interactively)
            // Its own key: between "Abbrechen" and "Speichern" the
            // German "Medikament hinzufügen" was cut to "Medikament…".
            .sheet(isPresented: $showPhotoOfMedSheet) {
                PhotoOfMedSheet { draft in
                    await prefillFields(from: draft)
                    showPhotoOfMedSheet = false
                }
            }
            // Save success/error haptic, mirroring the intake path.
            .sensoryFeedback(.success, trigger: saveTick)
            .sensoryFeedback(.error, trigger: saveErrorTick)
            // Seed focus onto the name field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = MedicationEditorFocus.resolve(.sheetSettled, from: focusedField)
            }
        }
        .onAppear { if baseline == nil { baseline = formFingerprint } }
    }

    /// Every field the person can change; differs from `baseline` once edited.
    private var formFingerprint: [AnyHashable] {
        [
            name, dose, ScheduleTimeRow.times(times), cadenceKind, cadenceSub, startsOn, endsOn, isOneShot, category,
            treatmentClass, dosesPerUnitText, unitsPerDose, notificationsEnabled, deliveryForm, graceEnabled,
            graceMinutes, trackInjectionSites, allowedInjectionSites, trackIntake
        ]
    }

    private var isDirty: Bool {
        baseline.map { $0 != formFingerprint } ?? false
    }

    // MARK: - Sections

    /// Optional entry-point into the Photo-of-Med pipeline. Rendered
    /// above the required fields so users can quickly OCR-prefill the form
    /// from a medication-package photo before manual completion. No
    /// footer; the photo sheet states its on-device promise where the photo is
    /// taken.
    private var photoOfMedSection: some View {
        Section {
            HLSettingsActionRow(icon: "camera.viewfinder", title: "Analyse photo", presents: .sheet) {
                showPhotoOfMedSheet = true
            }
            .disabled(isSaving)
            .accessibilityIdentifier("add-medication-photo-button")
        }
        .hlFormRowSurface()
    }

    private var requiredSection: some View {
        Section {
            HLFormField("med.form.name.label") {
                TextField("med.form.name.placeholder", text: $name)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = MedicationEditorFocus.resolve(.submitted(.name), from: focusedField) }
            }
            HLFormField("med.form.dose.label") {
                TextField("med.form.dose.placeholder", text: $dose)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .dose)
                    .submitLabel(.done)
            }
        }
        .hlFormRowSurface()
    }

    private var cadenceSection: some View {
        Section {
            CadencePicker(kind: $cadenceKind, sub: $cadenceSub)
                .onChange(of: cadenceKind) { _, newKind in
                    enforceTimeConstraints(for: newKind)
                }
                .simultaneousGesture(scheduleEngagement, including: .all)
        } header: {
            HLSectionHeader("med.schedule.cadence.section")
        }
        .hlFormRowSurface()
    }

    /// The Zeitplan row became the interaction target, reported on
    /// the way DOWN so the picker's own tap handling stays untouched. Copied
    /// from `EditMedicationSheet`, not re-derived.
    private var scheduleEngagement: some Gesture {
        TapGesture().onEnded { focusedField = MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: focusedField) }
    }

    private var scheduleSection: some View {
        Section {
            ForEach(Array(times.enumerated()), id: \.element.id) { idx, row in
                HStack {
                    // The red minus stands first, as in the system's edit mode.
                    if times.count > 1 {
                        HLDeleteButton("Remove time", form: .remove, action: .undoable {
                            times.removeAll { $0.id == row.id }
                        })
                    }
                    DatePicker(
                        String(localized: "med.form.time.label \(idx + 1)"),
                        selection: bindingForTime(rowID: row.id),
                        displayedComponents: [.hourAndMinute]
                    )
                    .labelsHidden()
                    Spacer()
                    // The picker shows the time; the second "08:00"
                    // beside it repeated it in wire form.
                }
            }
            if times.count < MedicationCadenceLogic.maxTimes(for: cadenceKind) {
                HLSettingsActionRow(title: "med.schedule.times.add", presents: .create) {
                    times.append(ScheduleTimeRow(time: TimeOfDay(hour: 12, minute: 0)))
                }
            }
        } header: {
            HLSectionHeader("med.schedule.times.header")
        }
        .hlFormRowSurface()
    }

    private var courseWindowSection: some View {
        Section {
            CourseWindowRow(startsOn: $startsOn, endsOn: $endsOn, isOneShot: $isOneShot)
                .onChange(of: isOneShot) { _, oneShot in
                    if oneShot { enforceTimeConstraints(for: cadenceKind) }
                }
        } header: {
            HLSectionHeader("med.schedule.course.section")
        }
        .hlFormRowSurface()
    }

    /// The optional fields wait behind the centred „Erweitert" link under the
    /// card above and fold out in a card of their own beneath it.
    @ViewBuilder
    private var advancedSection: some View {
        Section {
            HLLinkButton("Advanced", isExpanded: showAdvanced) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { showAdvanced.toggle() }
            }
            .accessibilityIdentifier("med.add.advanced")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
        if showAdvanced {
            Section {
                advancedRows
            }
            .hlFormRowSurface()
        }
        // Delivery toggles (Live Activity / Kritischer Alarm) are
        // edit-only by design: their prefs are keyed by med-id, which doesn't
        // exist before the med is created. The footer that pointed at
        // the edit sheet is gone.
    }

    @ViewBuilder
    private var advancedRows: some View {
        // Form rows that stack at the accessibility sizes instead of cutting
        // their value in the middle.
        HLFormPicker("Category", selection: $category, options: MedicationCategoryOption.allCases) { option in
            Text(verbatim: option.displayName)
        }
        HLFormPicker("Class", selection: $treatmentClass, options: MedicationTreatmentClassOption.allCases) { option in
            Text(verbatim: option.displayName)
        }
        HLFormPicker(
            "med.schedule.advanced.deliveryForm.label",
            selection: $deliveryForm,
            options: MedicationDeliveryFormOption.allCases
        ) { option in
            Text(option.labelKey)
        }
        InjectionSiteTrackingSection(
            isInjection: .constant(deliveryForm == .injection),
            trackInjectionSites: $trackInjectionSites,
            allowedInjectionSites: $allowedInjectionSites
        )
        MedicationDosesPerUnitField(text: $dosesPerUnitText)
        UnitsPerDosePicker(selection: $unitsPerDose)
        Toggle(isOn: $notificationsEnabled) {
            HLRowTitle("Notifications")
        }
        if cadenceKind != .asNeeded {
            Toggle(isOn: $graceEnabled) {
                HLRowTitle("med.schedule.advanced.grace.toggle")
            }
            if graceEnabled {
                HLIntStepperRow(
                    titleKey: "med.schedule.advanced.grace.label",
                    value: $graceMinutes,
                    range: 1 ... 1440,
                    unitKey: nil
                )
            }
        }
    }

    // MARK: - Time constraints

    /// Clamp the reminder-time list to the cadence's allowance: rolling ≤ 1,
    /// PRN 0, everything else ≤ 8 (mirrors the server refine). PRN also disables
    /// the grace field. Called on every cadence-kind switch + one-shot toggle.
    private func enforceTimeConstraints(for kind: CadenceKind) {
        let maxTimes = MedicationCadenceLogic.maxTimes(for: kind)
        if times.count > maxTimes {
            times = Array(times.prefix(max(maxTimes, 0)))
        }
        if kind == .asNeeded {
            graceEnabled = false
        }
    }

    // MARK: - Photo-of-Med prefill

    /// Populates form fields from a `MedicationDraft` returned by
    /// `PhotoOfMedSheet`. Semantics: **only-empty-fields**, never overwrite
    /// user input.
    @MainActor
    func prefillFields(from draft: MedicationDraft) async {
        let prefill = MedicationFormLogic.applyPhotoOfMedPrefill(
            currentName: name,
            currentDose: dose,
            draft: draft
        )
        name = prefill.name
        dose = prefill.dose
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard MedicationFormLogic.isValidCore(name: name, dose: dose) else { return false }
        let value = MedicationCadenceLogic.encode(cadenceKind, cadenceSub)
        return MedicationCadenceLogic.isCadenceValid(
            value: value,
            times: cadenceKind == .asNeeded ? [] : ScheduleTimeRow.times(times),
            startsOn: startsOn,
            endsOn: endsOn,
            graceMinutes: graceEnabled ? graceMinutes : nil
        )
    }

    // MARK: - Save

    private func save() async -> Bool {
        guard !isSaving, isValid else { return false }
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        let value = MedicationCadenceLogic.encode(cadenceKind, cadenceSub)
        let effectiveTimes = cadenceKind == .asNeeded ? [] : ScheduleTimeRow.times(times)
        // `schedules` and the medication-level `asNeeded` flag are one
        // decision, and the route 422s either half without the other. They are
        // built together so they cannot drift.
        let write = MedicationCadenceLogic.scheduleWrite(
            value: value,
            times: effectiveTimes,
            graceMinutes: graceEnabled ? graceMinutes : nil
        )
        let body = MedicationsRepository.MedicationCreate(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dose: dose.trimmingCharacters(in: .whitespacesAndNewlines),
            treatmentClass: treatmentClass.wireValue,
            dosesPerUnit: parsedDosesPerUnit,
            unitsPerDose: unitsPerDose.decimalValue,
            category: category.wireValue,
            active: true,
            notificationsEnabled: notificationsEnabled,
            schedules: write.schedules,
            oneShot: value.oneShot ? true : nil,
            startsOn: startsOn.map { MedicationCadenceLogic.courseDay($0) },
            endsOn: value.oneShot ? nil : endsOn.map { MedicationCadenceLogic.courseDay($0) },
            deliveryForm: deliveryForm.wireValue,
            // Only send injection-site fields for an INJECTION med.
            trackInjectionSites: deliveryForm == .injection ? trackInjectionSites : nil,
            allowedInjectionSites: deliveryForm == .injection && trackInjectionSites
                ? allowedInjectionSites.compactMap(\.serverRawValue).sorted()
                : nil,
            asNeeded: write.asNeeded,
            trackIntake: MedicationTrackIntakeWrite.create(switchOn: trackIntake, served: store.medications)
        )

        let outcome = await store.create(body)
        switch outcome {
        case .success, .queued:
            saveTick &+= 1 // Success haptic before dismiss.
            onSaved()
            return true
        case let .failed(err):
            saveError = err
            saveErrorTick &+= 1 // Error haptic, sheet stays open.
        }
        return false
    }

    private var parsedDosesPerUnit: Int? {
        MedicationFormLogic.parseDosesPerUnit(dosesPerUnitText)
    }

    /// Binds a `DatePicker` to the time-row identified by `rowID`.
    /// Resolving by stable id — not array offset — means a remove that shifts
    /// indices can never re-point an open picker at a different row.
    private func bindingForTime(rowID: UUID) -> Binding<Date> {
        Binding(
            get: {
                let time = times.first(where: { $0.id == rowID })?.time ?? TimeOfDay(hour: 12, minute: 0)
                let calendar = Calendar.current
                let now = Date()
                return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) ?? now
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                guard let idx = times.firstIndex(where: { $0.id == rowID }) else { return }
                times[idx].time = TimeOfDay(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
            }
        )
    }
}

// MARK: - Schedule-time row identity

/// Stable-identity wrapper for an editable reminder time. The Add/Edit medication
/// sheets render the `times` list with `ForEach` — keying that on the array
/// **offset** (`id: \.offset`) meant SwiftUI re-used a row's view identity across
/// a `remove(at:)`, so after deleting a middle time the user's NEXT edit landed
/// on the WRONG time row (the schedule they thought they set was not persisted).
/// A per-row `UUID` gives each entry an identity that survives inserts/removes,
/// so the picker binding always tracks the row it belongs to. The wrapper is a
/// View-only concern; the persisted `[TimeOfDay]` the cadence logic consumes is
/// derived via ``ScheduleTimeRow/times(_:)``.
struct ScheduleTimeRow: Identifiable, Equatable {
    let id: UUID
    var time: TimeOfDay

    init(id: UUID = UUID(), time: TimeOfDay) {
        self.id = id
        self.time = time
    }

    /// Map a plain `[TimeOfDay]` (server / defaults) into fresh-identity rows.
    static func rows(_ times: [TimeOfDay]) -> [ScheduleTimeRow] {
        times.map { ScheduleTimeRow(time: $0) }
    }

    /// Strip the identity wrapper back to the `[TimeOfDay]` the cadence builders
    /// + validators consume.
    static func times(_ rows: [ScheduleTimeRow]) -> [TimeOfDay] {
        rows.map(\.time)
    }
}

// MARK: - Pure validators & builders (testable seam)

/// Pure helpers for `AddMedicationSheet` / `EditMedicationSheet`. Kept
/// `internal` + `Sendable`-friendly so unit tests can lean on them
/// without standing up a SwiftUI host or driving `@State` rules
/// through reflection.
enum MedicationFormLogic {
    /// Name + dose validity only (the cadence half is checked by
    /// `MedicationCadenceLogic.isCadenceValid`). Mirrors the server's
    /// `createMedicationSchema` name 1-100 / dose 1-50 bounds.
    static func isValidCore(name: String, dose: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDose = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && trimmedName.count <= 100
            && !trimmedDose.isEmpty
            && trimmedDose.count <= 50
    }

    /// Parse the `dosesPerUnit` text field into the server's `Int?`. Rejects
    /// values outside `1...100` per `createMedicationSchema`.
    static func parseDosesPerUnit(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), (1 ... 100).contains(value) else {
            return nil
        }
        return value
    }

    static func formatTime(_ time: TimeOfDay) -> String {
        // The server's "HH:mm" schedule key, never shown to anyone.
        // swiftlint:disable:next hl_date_via_helper
        String(format: "%02d:%02d", time.hour, time.minute)
    }

    /// Compute the (name, dose) pair the form should hold after a
    /// `PhotoOfMedSheet` confirmation. Only fills empty fields; never
    /// overwrites user input.
    static func applyPhotoOfMedPrefill(
        currentName: String,
        currentDose: String,
        draft: MedicationDraft
    ) -> (name: String, dose: String) {
        let trimmedName = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmedName.isEmpty ? draft.name : currentName
        let trimmedDose = currentDose.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDose: String = if trimmedDose.isEmpty, let draftDose = draft.doseStrength {
            draftDose
        } else {
            currentDose
        }
        return (name: newName, dose: newDose)
    }
}

// MARK: - Option enums

/// Picker-friendly enumeration of `MedicationCategory` server values.
/// `wireValue` returns the raw enum string the server expects (see
/// `src/lib/validations/medication.ts` `MEDICATION_CATEGORY_VALUES`).
enum MedicationCategoryOption: String, CaseIterable, Identifiable {
    case bloodPressure = "BLOOD_PRESSURE"
    case vitamin = "VITAMIN"
    case supplement = "SUPPLEMENT"
    case painRelief = "PAIN_RELIEF"
    case allergy = "ALLERGY"
    case digestive = "DIGESTIVE"
    case thyroid = "THYROID"
    case hormone = "HORMONE"
    case skin = "SKIN"
    case sleepAid = "SLEEP_AID"
    // Server v1.39.4 (#1041) — the three the picker lacked; editing such a
    // medication used to store OTHER.
    case diabetes = "DIABETES"
    case antibiotic = "ANTIBIOTIC"
    case mentalHealth = "MENTAL_HEALTH"
    case other = "OTHER"

    var id: String {
        rawValue
    }

    var wireValue: String {
        rawValue
    }

    /// The picker rendered these as plain `String`s, i.e. never
    /// through the catalog: an English build showed "Nahrungsergänzung", a
    /// German one "Blood pressure". The catalog already carries the
    /// `medications.category*` family (en + de); the picker now reads it.
    var displayName: String {
        switch self {
        case .bloodPressure: String(localized: "medications.categoryBloodPressure")
        case .vitamin: String(localized: "medications.categoryVitamin")
        case .supplement: String(localized: "medications.categorySupplement")
        case .painRelief: String(localized: "medications.categoryPainRelief")
        case .allergy: String(localized: "medications.categoryAllergy")
        case .digestive: String(localized: "medications.categoryDigestive")
        case .thyroid: String(localized: "medications.categoryThyroid")
        case .hormone: String(localized: "medications.categoryHormone")
        case .skin: String(localized: "medications.categorySkin")
        case .sleepAid: String(localized: "medications.categorySleepAid")
        case .diabetes: String(localized: "medications.categoryDiabetes")
        case .antibiotic: String(localized: "medications.categoryAntibiotic")
        case .mentalHealth: String(localized: "medications.categoryMentalHealth")
        case .other: String(localized: "medications.categoryOther")
        }
    }
}
