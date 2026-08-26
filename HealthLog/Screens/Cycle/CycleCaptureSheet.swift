import SwiftUI

/// **v0.14.8 Phase C4 — cycle day-log capture under "Erfassen".**
///
/// A clean, monochrome form to log one cycle day per the v1.15 LOCKED contract.
/// Reachable only via the gated `.cycle` row in `CapturePickerSheet` (women-only
/// resolution + explicit opt-in, hard-gated behind `FeatureFlag.cycleTracking`),
/// so an ineligible / opted-out user can never reach it.
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
/// The calendar / prediction surface (C5) + the phase-aware explainer land in
/// the next wave; this sheet only needs to LOG correctly with a minimal
/// post-save confirmation.
struct CycleCaptureSheet: View {
    let store: CycleStore
    let healthKit: AnyHealthKitWriter?
    /// Optional initial day (C5 calendar day-tap seeds the editor to that date).
    var initialDate: Date?
    let onDismiss: () -> Void

    @State private var date: Date = .now
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
    /// **CU-25 (#72) — the reconciliation moment.** Flow logged on a day with no
    /// active period would be filed silently against the PREVIOUS cycle (the
    /// server attributes a day log to the latest span starting on or before that
    /// day, and only `POST /api/cycle/period` ever creates a span). That is what
    /// leaves the record holding one very long cycle with bleeding inside it and
    /// everything downstream reading "later than usual". So we ask — once, on the
    /// first bleeding day of a run, never on every entry
    /// (see ``CycleFlowReconciliation``).
    @State private var showPeriodStartPrompt = false
    /// QoL-1 (A360-4) — Save haptic drivers (see `AddMedicationSheet`). `saveTick`
    /// bumps on a committed capture, `saveErrorTick` on a failure.
    @State private var saveTick = 0
    @State private var saveErrorTick = 0

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("cycle.capture.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .overlay(alignment: .center) { savingOverlay }
            // QoL-1 — Save success/error haptic, mirroring the intake path.
            .sensoryFeedback(.success, trigger: saveTick)
            .sensoryFeedback(.error, trigger: saveErrorTick)
            .confirmationDialog(
                "cycle.capture.reconcile.title",
                isPresented: $showPeriodStartPrompt,
                titleVisibility: .visible
            ) {
                Button("cycle.capture.reconcile.confirm") {
                    periodAction = .start
                    Task { await commit() }
                }
                Button("cycle.capture.reconcile.decline") {
                    store.declineFlowReconciliation(for: Self.dayKey(date))
                    Task { await commit() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("cycle.capture.reconcile.message")
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            if let initialDate { date = initialDate }
        }
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
                    customEditor = nil
                },
                onDismiss: { customEditor = nil }
            )
            .hlSheetPresentation(.form)
        }
    }

    // MARK: - Sections

    private var periodSection: some View {
        Section {
            DatePicker("cycle.capture.date", selection: $date, displayedComponents: [.date])
            Picker("cycle.capture.period.header", selection: $periodAction) {
                Text("cycle.capture.period.none").tag(CyclePeriodAction?.none)
                Text("cycle.capture.period.start").tag(CyclePeriodAction?.some(.start))
                Text("cycle.capture.period.end").tag(CyclePeriodAction?.some(.end))
            }
            .pickerStyle(.segmented)
            .disabled(isSaving)
        } header: {
            Text("cycle.capture.period.header")
        } footer: {
            Text("cycle.capture.period.footer")
        }
    }

    private var flowSection: some View {
        Section("cycle.capture.flow.header") {
            Picker("cycle.capture.flow.header", selection: $flow) {
                ForEach(CycleFlowLevel.allCases, id: \.self) { level in
                    Text(Self.flowLabel(level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                Text(LocalizedStringKey(section.titleKey))
            }
        }
        Section {
            ForEach(store.customSymptoms) { symptom in
                customSymptomRow(symptom)
            }
            Button {
                customEditor = .create
            } label: {
                Label("cycle.custom.create.button", systemImage: "plus")
            }
            .disabled(store.customSymptoms.count >= 50)
            if store.customSymptoms.count >= 50 {
                Text("cycle.custom.limit")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            if let customError = store.customSymptomsError {
                HLFormErrorText(customError)
            }
        } header: {
            Text("cycle.capture.symptoms.category.custom")
        }
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
                label.font(.hlSubhead)
            }
            if isOn {
                Picker("cycle.capture.symptoms.severity", selection: Binding(
                    get: { symptomSeverity[key] ?? 0 },
                    set: { symptomSeverity[key] = $0 == 0 ? nil : $0 }
                )) {
                    Text("cycle.capture.symptoms.severity.none").tag(0)
                    ForEach(1 ... 4, id: \.self) { sev in
                        Text("\(sev)").tag(sev)
                    }
                }
                .pickerStyle(.segmented)
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
            Menu {
                Button("Edit") { customEditor = .edit(symptom) }
                Button("Delete", role: .destructive) {
                    selectedSymptoms.remove(symptom.key)
                    symptomSeverity[symptom.key] = nil
                    Task { _ = await store.softDeleteCustomSymptom(key: symptom.key) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("cycle.custom.actions"))
        }
    }

    private var fertilitySection: some View {
        Section("cycle.capture.fertility.header") {
            Toggle(isOn: $hasBBT) {
                Text("cycle.capture.bbt.label").font(.hlSubhead)
            }
            if hasBBT {
                Stepper(value: $bbt, in: 35.0 ... 39.0, step: 0.05) {
                    Text(Self.bbtFormatted(bbt))
                        .font(.hlSubhead.monospacedDigit())
                }
                Toggle(isOn: $temperatureExcluded) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("cycle.capture.bbt.excluded.label").font(.hlSubhead)
                        Text("cycle.capture.bbt.excluded.hint")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
            }
            Picker("cycle.capture.ovulation.label", selection: Binding(
                get: { ovulationTest },
                set: { ovulationTest = $0 }
            )) {
                Text("cycle.capture.option.notSet").tag(CycleOvulationTest?.none)
                ForEach(CycleOvulationTest.allCases, id: \.self) { test in
                    Text(Self.ovulationLabel(test)).tag(CycleOvulationTest?.some(test))
                }
            }
            Picker("cycle.capture.mucus.label", selection: Binding(
                get: { cervicalMucus },
                set: { cervicalMucus = $0 }
            )) {
                Text("cycle.capture.option.notSet").tag(CycleCervicalMucus?.none)
                ForEach(CycleCervicalMucus.allCases, id: \.self) { mucus in
                    Text(Self.mucusLabel(mucus)).tag(CycleCervicalMucus?.some(mucus))
                }
            }
        }
    }

    /// v1.16.15 — the cervix secondary-symptom observations (manual-only;
    /// HealthKit has no cervix category). Three optional pickers; an empty
    /// selection is simply omitted from the write body.
    private var cervixSection: some View {
        Section {
            Picker("cycle.capture.cervix.position.label", selection: Binding(
                get: { cervixPosition },
                set: { cervixPosition = $0 }
            )) {
                Text("cycle.capture.option.notSet").tag(CycleCervixPosition?.none)
                ForEach(CycleCervixPosition.allCases, id: \.self) { value in
                    Text(Self.cervixPositionLabel(value)).tag(CycleCervixPosition?.some(value))
                }
            }
            Picker("cycle.capture.cervix.firmness.label", selection: Binding(
                get: { cervixFirmness },
                set: { cervixFirmness = $0 }
            )) {
                Text("cycle.capture.option.notSet").tag(CycleCervixFirmness?.none)
                ForEach(CycleCervixFirmness.allCases, id: \.self) { value in
                    Text(Self.cervixFirmnessLabel(value)).tag(CycleCervixFirmness?.some(value))
                }
            }
            Picker("cycle.capture.cervix.opening.label", selection: Binding(
                get: { cervixOpening },
                set: { cervixOpening = $0 }
            )) {
                Text("cycle.capture.option.notSet").tag(CycleCervixOpening?.none)
                ForEach(CycleCervixOpening.allCases, id: \.self) { value in
                    Text(Self.cervixOpeningLabel(value)).tag(CycleCervixOpening?.some(value))
                }
            }
        } header: {
            Text("cycle.capture.cervix.header")
        } footer: {
            Text("cycle.capture.cervix.footer")
        }
    }

    private var intimacySection: some View {
        Section("cycle.capture.intimacy.header") {
            Toggle(isOn: $sexualActivity) {
                Text("cycle.capture.intimacy.active").font(.hlSubhead)
            }
            if sexualActivity {
                Toggle(isOn: $protectedSex) {
                    Text("cycle.capture.intimacy.protected").font(.hlSubhead)
                }
            }
        }
    }

    private var testsAndContraceptionSection: some View {
        Section("cycle.capture.tests.header") {
            Toggle("cycle.capture.intermenstrualBleeding.label", isOn: $intermenstrualBleeding)
            Picker("cycle.capture.pregnancyTest.label", selection: $pregnancyTest) {
                Text("cycle.capture.option.notSet").tag(CycleTestResult?.none)
                ForEach(CycleTestResult.allCases, id: \.self) { result in
                    Text(Self.testResultLabel(result)).tag(CycleTestResult?.some(result))
                }
            }
            Picker("cycle.capture.progesteroneTest.label", selection: $progesteroneTest) {
                Text("cycle.capture.option.notSet").tag(CycleTestResult?.none)
                ForEach(CycleTestResult.allCases, id: \.self) { result in
                    Text(Self.testResultLabel(result)).tag(CycleTestResult?.some(result))
                }
            }
            Picker("cycle.capture.contraceptive.label", selection: $contraceptive) {
                Text("cycle.capture.option.notSet").tag(CycleContraceptiveKind?.none)
                ForEach(CycleContraceptiveKind.allCases, id: \.self) { value in
                    Text(Self.contraceptiveLabel(value)).tag(CycleContraceptiveKind?.some(value))
                }
            }
        }
    }

    private var noteSection: some View {
        Section("cycle.capture.note.header") {
            TextField("cycle.capture.note.placeholder", text: $note, axis: .vertical)
                .lineLimit(2 ... 4)
                .onChange(of: note) { _, newValue in
                    if newValue.count > 500 { note = String(newValue.prefix(500)) }
                }
        }
    }

    @ViewBuilder
    private var savingOverlay: some View {
        if isSaving {
            ProgressView()
                .controlSize(.large)
                .padding(HLSpace.lg)
                .hlGlassBackground(in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous), fallback: HLSurface.secondary)
        }
    }

    private func loadDay() async {
        let requestedKey = Self.dayKey(date)
        isLoadingDay = true
        defer { isLoadingDay = false }
        let row = await store.dayLog(date: requestedKey)
        guard requestedKey == Self.dayKey(date) else { return }
        resetForm()
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

    private func resetForm() {
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

    // MARK: - Save

    /// Save — asks the reconciliation question first when this is flow on a day
    /// no period covers, then commits. The prompt's own buttons call
    /// ``commit()`` directly, so the question can never be asked twice for one
    /// Save.
    private func save() async {
        if CycleFlowReconciliation.shouldAskPeriodStarted(
            flow: flow,
            periodAction: periodAction,
            date: Self.dayKey(date),
            days: store.calendar?.days ?? [],
            declined: store.flowReconciliationDeclined
        ) {
            showPeriodStartPrompt = true
            return
        }
        await commit()
    }

    /// Commit create/edit and the optional period boundary through one Save.
    private func commit() async {
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
            onDismiss()
        } else {
            error = store.lastError ?? String(localized: "cycle.capture.error.generic")
            saveErrorTick &+= 1
        }
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
