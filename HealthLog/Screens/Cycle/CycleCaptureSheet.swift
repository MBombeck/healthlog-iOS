import SwiftUI

/// **v0.14.8 Phase C4 — cycle day-log capture under "Erfassen".**
///
/// A clean, monochrome form to log one cycle day per the v1.15 LOCKED contract.
/// Reachable only via the gated `.cycle` row in `CapturePickerSheet` (women-only
/// resolution + explicit opt-in), so an ineligible / opted-out user can never reach it.
///
/// Saves go through the EXISTING write path — `CycleStore.commitCapture` →
/// `CycleRepository.logDayLog` (+ optional `period`) (optimistic POST → Outbox
/// on a retriable failure, idempotency-keyed) — plus a best-effort Apple-Health
/// mirror (C2 writer). No new networking layer. The "Period start/end" control
/// is a SELECTABLE PENDING choice (Start / End / none) committed TOGETHER with
/// the day-log on "Save" — it no longer fires `POST /api/cycle/period` on tap.
///
/// **Privacy:** cycle data is highly sensitive — this view never logs field
/// values; the store + repo log counts/states only.
///
/// The calendar / prediction surface + the phase-aware explainer land in
/// the next wave; this sheet only needs to LOG correctly with a minimal
/// post-save confirmation.
struct CycleCaptureSheet: View {
    let store: CycleStore
    let healthKit: AnyHealthKitWriter?
    /// Optional initial day (C5 calendar day-tap seeds the editor to that date).
    var initialDate: Date?
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = .now
    /// The basal temperature reads in the account's unit; the stepper
    /// still steps and stores canonical °C.
    @Environment(\.unitPreferences) private var units
    /// Pending period start/end choice — committed together with the day-log on
    /// "Save", NOT fired on tap. `nil` means "no period change today".
    @State private var periodAction: CyclePeriodAction?
    @State private var flow: CycleFlowLevel = .none
    @State private var selectedSymptoms: Set<String> = []
    @State private var existingID: String?
    @State private var isLoadingDay = false
    @State private var symptomSeverity: [String: Int] = [:]
    @State private var hasBBT = false
    @State private var bbt: Double = 36.5
    /// What the temperature field holds; saving waits for a valid reading.
    @State private var bbtEntry: HLNumberEntry.State = .empty
    /// v1.16.15 — mark a disturbed (fever / late) reading excluded from the
    /// temperature evaluation. Only offered while a BBT reading is present.
    @State private var temperatureExcluded = false
    @State private var ovulationTest: CycleOvulationTest?
    @State private var cervicalMucus: CycleCervicalMucus?
    /// v1.16.15 — cervix secondary-symptom observations (manual-only).
    @State private var cervixPosition: CycleCervixPosition?
    @State private var cervixFirmness: CycleCervixFirmness?
    @State private var cervixOpening: CycleCervixOpening?
    @State private var sexualActivity = false
    @State private var protectedSex = false
    @State private var intermenstrualBleeding = false
    @State private var pregnancyTest: CycleTestResult?
    @State private var progesteroneTest: CycleTestResult?
    @State private var contraceptive: CycleContraceptiveKind?
    @State private var customEditor: CycleCustomEditorTarget?
    @State private var note: String = ""

    @State private var isSaving = false
    @State private var error: String?
    /// **The reconciliation moment.** Flow logged on a day with no
    /// active period would be filed silently against the PREVIOUS cycle (the
    /// server attributes a day log to the latest span starting on or before that
    /// day, and only `POST /api/cycle/period` ever creates a span). That is what
    /// leaves the record holding one very long cycle with bleeding inside it and
    /// everything downstream reading "later than usual". So we ask — once, on the
    /// first bleeding day of a run, never on every entry
    /// (see ``CycleFlowReconciliation``).
    @State private var showPeriodStartPrompt = false
    /// Save haptic drivers (see `AddMedicationSheet`). `saveTick`
    /// bumps on a committed capture, `saveErrorTick` on a failure.
    @State private var saveTick = 0
    @State private var saveErrorTick = 0
    /// The day as loaded, for the discard guard. Re-taken on every day load,
    /// since picking another day replaces the form with that day's entry.
    @State private var baseline: [AnyHashable]?

    var body: some View {
        HLSheetScaffold(
            "cycle.capture.title",
            action: .save(isEnabled: !isSaving && (!hasBBT || bbtEntry.value != nil)) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Group {
                    periodSection
                    flowSection
                    symptomsSection
                    fertilitySection
                    cervixSection
                    intimacySection
                    testsAndContraceptionSection
                    noteSection
                    if let error {
                        Section { HLFormErrorText(error) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
            // Save success/error haptic, mirroring the intake path.
            .sensoryFeedback(.success, trigger: saveTick)
            .sensoryFeedback(.error, trigger: saveErrorTick)
            .confirmationDialog(
                "cycle.capture.reconcile.title",
                isPresented: $showPeriodStartPrompt,
                titleVisibility: .visible
            ) {
                Button("cycle.capture.reconcile.confirm") {
                    periodAction = .start
                    Task { await commitFromPrompt() }
                }
                Button("cycle.capture.reconcile.decline") {
                    store.declineFlowReconciliation(for: Self.dayKey(date))
                    Task { await commitFromPrompt() }
                }
                Button(HLControlWord.cancel.key, role: .cancel) {}
            } message: {
                Text("cycle.capture.reconcile.message")
            }
        }
        // The date picker shows days in the ACCOUNT zone, the zone
        // `dayKey` cuts the server key in, so the day picked is the day sent.
        .environment(\.timeZone, ProfileDay.timeZone)
        .onAppear { if let initialDate { date = initialDate } }
        .task(id: Self.dayKey(date)) {
            await loadDay()
            await store.loadCustomSymptoms()
        }
        .sheet(item: $customEditor) { target in
            CycleCustomSymptomEditor(
                target: target,
                store: store,
                onSaved: { key in
                    selectedSymptoms.insert(key)
                }
            )
        }
    }

    // MARK: - Sections

    private var periodSection: some View {
        CycleCapturePeriodSection(store: store, date: $date, periodAction: $periodAction, isSaving: isSaving)
    }

    private var flowSection: some View {
        Section {
            // „Schmier…" was cut even on the large device; a menu shows
            // the whole word when the five segments cannot, and then carries
            // its row title, so "Keine" never stands alone.
            HLAdaptiveSegmentedPicker("cycle.capture.flow.header", selection: $flow, labels: Self.flowLabels) {
                ForEach(CycleFlowLevel.allCases, id: \.self) { level in
                    Text(Self.flowLabel(level)).tag(level)
                }
            }
        } header: {
            HLSectionHeader("cycle.capture.flow.header", rank: .group)
        }
    }

    @ViewBuilder
    private var symptomsSection: some View {
        ForEach(CycleSymptomCatalog.seedSections) { section in
            Section {
                ForEach(section.items) { item in
                    symptomRow(key: item.key, label: Text(LocalizedStringKey(item.labelKey)))
                }
            } header: {
                HLSectionHeader(LocalizedStringKey(section.titleKey), rank: .group)
            }
        }
        Section {
            ForEach(store.customSymptoms) { symptom in
                customSymptomRow(symptom)
            }
            HLSettingsActionRow(title: "cycle.custom.create.button", presents: .create) {
                customEditor = .create
            }
            .disabled(store.customSymptoms.count >= 50)
            if store.customSymptoms.count >= 50 {
                Text("cycle.custom.limit")
                    .hlText(.rowSubtitle)
            }
            if let customError = store.customSymptomsError {
                HLFormErrorText(customError)
            }
        } header: {
            HLSectionHeader("cycle.capture.symptoms.category.custom", rank: .group)
        }
    }

    /// The basal temperature reads and is typed in the account's unit and
    /// stays canonical °C underneath.
    private var bbtInAccountUnit: Binding<Double?> {
        let transform = units.transform(for: .bodyTemperature)
        return Binding(
            get: { (transform.display(bbt) * 100).rounded() / 100 },
            set: { typed in
                if let typed { bbt = transform.canonical(fromDisplayed: typed) }
            }
        )
    }

    private var bbtUnit: HLUnit {
        units.transform(for: .bodyTemperature).rescales ? .fahrenheit : .celsius
    }

    /// 35 to 39 °C, in the account's unit.
    private var bbtRange: ClosedRange<Double> {
        let transform = units.transform(for: .bodyTemperature)
        func rounded(_ value: Double) -> Double {
            (value * 100).rounded() / 100
        }
        return rounded(transform.display(35)) ... rounded(transform.display(39))
    }

    @ViewBuilder
    private func symptomRow(key: String, label: Text) -> some View {
        let isOn = selectedSymptoms.contains(key)
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue { selectedSymptoms.insert(key) } else {
                        selectedSymptoms.remove(key)
                        symptomSeverity[key] = nil
                    }
                }
            )) {
                HLRowTitle(label)
            }
            if isOn {
                HLAdaptiveSegmentedPicker(
                    "cycle.capture.symptoms.severity",
                    selection: Binding(
                        get: { symptomSeverity[key] ?? 0 },
                        set: { symptomSeverity[key] = $0 == 0 ? nil : $0 }
                    ),
                    labels: ["cycle.capture.symptoms.severity.none", "1", "2", "3", "4"]
                ) {
                    Text("cycle.capture.symptoms.severity.none").tag(0)
                    ForEach(1 ... 4, id: \.self) { sev in
                        Text("\(sev)").tag(sev)
                    }
                }
            }
        }
    }

    private func customSymptomRow(_ symptom: CycleCustomSymptomDTO) -> some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: symptom.safeSystemImage)
                .foregroundStyle(HLText.secondary)
            symptomRow(
                key: symptom.key,
                label: Text(verbatim: symptom.displayLabel ?? String(localized: "cycle.custom.unnamed"))
            )
            HLIconButton(systemImage: "ellipsis", label: "cycle.custom.actions", menu: {
                Button(HLControlWord.edit.key) { customEditor = .edit(symptom) }
                // The store has no way back for a custom symptom: asked first.
                HLDeleteMenuItem(.confirmed(title: "cycle.custom.delete.title") {
                    selectedSymptoms.remove(symptom.key)
                    symptomSeverity[symptom.key] = nil
                    _ = await store.softDeleteCustomSymptom(key: symptom.key)
                })
            })
        }
        .hlDeleteConfirmation()
    }

    private var fertilitySection: some View {
        Section {
            Toggle(isOn: $hasBBT) {
                HLRowTitle("cycle.capture.bbt.label")
            }
            if hasBBT {
                HLNumberField(
                    "cycle.bbt.axis.temperature",
                    value: bbtInAccountUnit,
                    state: $bbtEntry,
                    unit: bbtUnit,
                    range: bbtRange,
                    fractionDigits: 2 ... 2
                )
                Toggle(isOn: $temperatureExcluded) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        HLRowTitle("cycle.capture.bbt.excluded.label")
                        Text("cycle.capture.bbt.excluded.hint")
                            .hlText(.footnote)
                    }
                }
            }
            HLFormPicker(
                "cycle.capture.ovulation.label",
                selection: $ovulationTest,
                options: [CycleOvulationTest?.none] + CycleOvulationTest.allCases.map { CycleOvulationTest?.some($0) }
            ) { value in
                value.map { Text(Self.ovulationLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
            HLFormPicker(
                "cycle.capture.mucus.label",
                selection: $cervicalMucus,
                options: [CycleCervicalMucus?.none] + CycleCervicalMucus.allCases.map { CycleCervicalMucus?.some($0) }
            ) { value in
                value.map { Text(Self.mucusLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
        } header: {
            HLSectionHeader("cycle.capture.fertility.header", rank: .group)
        }
    }

    /// v1.16.15 — the cervix secondary-symptom observations (manual-only;
    /// HealthKit has no cervix category). Three optional pickers; an empty
    /// selection is simply omitted from the write body.
    private var cervixSection: some View {
        Section {
            HLFormPicker(
                "cycle.capture.cervix.position.label",
                selection: $cervixPosition,
                options: [CycleCervixPosition?.none] + CycleCervixPosition.allCases.map { CycleCervixPosition?.some($0) }
            ) { value in
                value.map { Text(Self.cervixPositionLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
            HLFormPicker(
                "cycle.capture.cervix.firmness.label",
                selection: $cervixFirmness,
                options: [CycleCervixFirmness?.none] + CycleCervixFirmness.allCases.map { CycleCervixFirmness?.some($0) }
            ) { value in
                value.map { Text(Self.cervixFirmnessLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
            HLFormPicker(
                "cycle.capture.cervix.opening.label",
                selection: $cervixOpening,
                options: [CycleCervixOpening?.none] + CycleCervixOpening.allCases.map { CycleCervixOpening?.some($0) }
            ) { value in
                value.map { Text(Self.cervixOpeningLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
        } header: {
            HLSectionHeader("cycle.capture.cervix.header", rank: .group)
        }
    }

    private var intimacySection: some View {
        Section {
            Toggle(isOn: $sexualActivity) {
                HLRowTitle("cycle.capture.intimacy.active")
            }
            if sexualActivity {
                Toggle(isOn: $protectedSex) {
                    HLRowTitle("cycle.capture.intimacy.protected")
                }
            }
        } header: {
            HLSectionHeader("cycle.capture.intimacy.header", rank: .group)
        }
    }

    private var testsAndContraceptionSection: some View {
        Section {
            Toggle(isOn: $intermenstrualBleeding) {
                HLRowTitle("cycle.capture.intermenstrualBleeding.label")
            }
            HLFormPicker(
                "cycle.capture.pregnancyTest.label",
                selection: $pregnancyTest,
                options: [CycleTestResult?.none] + CycleTestResult.allCases.map { CycleTestResult?.some($0) }
            ) { value in
                value.map { Text(Self.testResultLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
            HLFormPicker(
                "cycle.capture.progesteroneTest.label",
                selection: $progesteroneTest,
                options: [CycleTestResult?.none] + CycleTestResult.allCases.map { CycleTestResult?.some($0) }
            ) { value in
                value.map { Text(Self.testResultLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
            HLFormPicker(
                "cycle.capture.contraceptive.label",
                selection: $contraceptive,
                options: [CycleContraceptiveKind?.none] + CycleContraceptiveKind.allCases.map { CycleContraceptiveKind?.some($0) }
            ) { value in
                value.map { Text(Self.contraceptiveLabel($0)) } ?? Text("cycle.capture.option.notSet")
            }
        } header: {
            HLSectionHeader("cycle.capture.tests.header", rank: .group)
        }
    }

    private var noteSection: some View {
        Section {
            TextField("cycle.capture.note.placeholder", text: $note, axis: .vertical)
                .lineLimit(2 ... 4)
                .onChange(of: note) { _, newValue in
                    if newValue.count > 500 { note = String(newValue.prefix(500)) }
                }
        } header: {
            HLSectionHeader("cycle.capture.note.header", rank: .group)
        }
    }

    private func loadDay() async {
        let requestedKey = Self.dayKey(date)
        isLoadingDay = true
        defer { isLoadingDay = false }
        let row = await store.dayLog(date: requestedKey)
        guard requestedKey == Self.dayKey(date) else { return }
        resetForm()
        defer { baseline = formFingerprint }
        guard let row else { return }
        existingID = row.id
        flow = row.flowLevel ?? .none
        intermenstrualBleeding = row.intermenstrualBleeding
        selectedSymptoms = Set(row.symptoms.map(\.key))
        symptomSeverity = Dictionary(
            uniqueKeysWithValues: row.symptoms.compactMap { symptom in
                symptom.severity.map { (symptom.key, $0) }
            }
        )
        if let value = row.basalBodyTempC {
            hasBBT = true
            bbt = value
        }
        temperatureExcluded = row.temperatureExcluded
        ovulationTest = row.ovulationTestValue
        cervicalMucus = row.cervicalMucusValue
        cervixPosition = row.cervixPositionValue
        cervixFirmness = row.cervixFirmnessValue
        cervixOpening = row.cervixOpeningValue
        sexualActivity = row.sexualActivity
        protectedSex = row.protectedSex ?? false
        pregnancyTest = row.pregnancyTest.flatMap(CycleTestResult.init)
        progesteroneTest = row.progesteroneTest.flatMap(CycleTestResult.init)
        contraceptive = row.contraceptiveKind
        note = row.note ?? ""
    }

    // MARK: - Save

    /// Save — asks the reconciliation question first when this is flow on a day
    /// no period covers, then commits. The prompt's own buttons commit
    /// directly, so the question can never be asked twice for one Save.
    /// `true` when the sheet may close.
    private func save() async -> Bool {
        if CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: flow,
            periodAction: periodAction,
            date: Self.dayKey(date),
            days: store.calendar?.days ?? [],
            declined: store.flowReconciliationDeclined
        ) {
            showPeriodStartPrompt = true
            return false
        }
        return await commit()
    }

    /// The prompt's answer commits and closes the sheet itself, since the
    /// save that asked has already returned.
    private func commitFromPrompt() async {
        if await commit() { dismiss() }
    }

    /// Commit create/edit and the optional period boundary through one Save.
    private func commit() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        error = nil
        let write = buildWrite()
        let ok = await store.commitCapture(
            dayLog: write,
            period: Self.buildPeriodRequest(action: periodAction, date: date),
            existingID: existingID,
            patch: existingID == nil ? nil : buildPatch()
        )
        if ok {
            saveTick &+= 1
            store.clearSaveConfirmation()
        } else {
            error = store.lastError ?? String(localized: "cycle.capture.error.generic")
            saveErrorTick &+= 1
        }
        return ok
    }
}

extension CycleCaptureSheet {
    /// Build the contract `CyclePeriodRequest` for a pending period choice, or
    /// `nil` when the user picked no period change. Pure + unit-testable.
    /// `externalId` is the stable per-day-per-action UPSERT key.
    static func buildPeriodRequest(action: CyclePeriodAction?, date: Date) -> CyclePeriodRequest? {
        guard let action else { return nil }
        let key = dayKey(date)
        return CyclePeriodRequest(
            action: action,
            date: key,
            loggedAt: iso(date),
            externalId: "cycle-period:\(action.rawValue):\(key)"
        )
    }

    /// Build the contract `CycleDayLogWrite` from the current form state.
    func buildWrite() -> CycleDayLogWrite {
        Self.buildWrite(
            date: date,
            flow: flow,
            selectedSymptoms: selectedSymptoms,
            symptomSeverity: symptomSeverity,
            hasBBT: hasBBT,
            bbt: bbt,
            temperatureExcluded: temperatureExcluded,
            ovulationTest: ovulationTest,
            cervicalMucus: cervicalMucus,
            cervixPosition: cervixPosition,
            cervixFirmness: cervixFirmness,
            cervixOpening: cervixOpening,
            intermenstrualBleeding: intermenstrualBleeding,
            pregnancyTest: pregnancyTest,
            progesteroneTest: progesteroneTest,
            contraceptive: contraceptive,
            sexualActivity: sexualActivity,
            protectedSex: protectedSex,
            note: note
        )
    }

    func buildPatch() -> CycleDayLogPatch {
        let symptoms = selectedSymptoms.sorted().map {
            CycleSymptomDTO(key: $0, severity: symptomSeverity[$0])
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return CycleDayLogPatch(
            flow: .set(flow),
            intermenstrualBleeding: intermenstrualBleeding,
            basalBodyTempC: hasBBT ? .set((bbt * 100).rounded() / 100) : .clear,
            temperatureExcluded: hasBBT && temperatureExcluded,
            ovulationTest: patchField(ovulationTest),
            cervicalMucus: patchField(cervicalMucus),
            cervixPosition: patchField(cervixPosition),
            cervixFirmness: patchField(cervixFirmness),
            cervixOpening: patchField(cervixOpening),
            sexualActivity: sexualActivity,
            protectedSex: sexualActivity ? .set(protectedSex) : .clear,
            pregnancyTest: patchField(pregnancyTest),
            progesteroneTest: patchField(progesteroneTest),
            contraceptive: patchField(contraceptive),
            symptoms: .set(symptoms),
            note: trimmedNote.isEmpty ? .clear : .set(trimmedNote),
            loggedAt: Self.iso(date)
        )
    }

    private func patchField<Value>(_ value: Value?) -> RecordPatchField<Value> {
        value.map(RecordPatchField.set) ?? .clear
    }
}

// MARK: - Form state

private extension CycleCaptureSheet {
    /// Every field of the day the person can change, in one comparable value.
    var formFingerprint: [AnyHashable] {
        [
            periodAction, flow, selectedSymptoms, symptomSeverity, hasBBT, bbt, temperatureExcluded,
            ovulationTest, cervicalMucus, cervixPosition, cervixFirmness, cervixOpening, sexualActivity,
            protectedSex, intermenstrualBleeding, pregnancyTest, progesteroneTest, contraceptive, note
        ]
    }

    var isDirty: Bool {
        guard let baseline else { return false }
        return baseline != formFingerprint
    }

    func resetForm() {
        existingID = nil
        periodAction = nil
        flow = .none
        intermenstrualBleeding = false
        selectedSymptoms = []
        symptomSeverity = [:]
        hasBBT = false
        bbt = 36.5
        temperatureExcluded = false
        ovulationTest = nil
        cervicalMucus = nil
        cervixPosition = nil
        cervixFirmness = nil
        cervixOpening = nil
        sexualActivity = false
        protectedSex = false
        pregnancyTest = nil
        progesteroneTest = nil
        contraceptive = nil
        note = ""
    }
}
