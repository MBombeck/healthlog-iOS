import SwiftUI

/// Explicit, transactional editor for every visible cycle preference except
/// `enabled`, which remains owned by the later opt-in build.
struct CycleAdvancedSettingsSheet: View {
    let store: CycleStore
    let onDismiss: () -> Void

    @State private var goal: CycleGoal = .generalHealth
    @State private var predictionEnabled = true
    @State private var rawChartMode = false
    @State private var typicalCycleLength = ""
    @State private var typicalPeriodLength = ""
    @State private var lutealPhaseLength = ""
    @State private var secondarySymptom: CycleSecondarySymptom = .mucus
    @State private var sensitiveCategoryEncryption = false
    @State private var discreetNotifications = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("cycle.settings.goal.header") {
                    Picker("cycle.settings.goal.label", selection: $goal) {
                        ForEach(CycleGoal.allCases, id: \.self) { value in
                            Text(goalLabel(value)).tag(value)
                        }
                    }
                    Toggle("cycle.settings.prediction.label", isOn: $predictionEnabled)
                    Toggle("cycle.settings.rawMode.label", isOn: $rawChartMode)
                }

                Section {
                    numberField(
                        "cycle.settings.typicalCycleLength.label",
                        text: $typicalCycleLength,
                        range: 15 ... 60
                    )
                    numberField(
                        "cycle.settings.typicalPeriodLength.label",
                        text: $typicalPeriodLength,
                        range: 1 ... 15
                    )
                    numberField(
                        "cycle.settings.lutealPhaseLength.label",
                        text: $lutealPhaseLength,
                        range: 10 ... 16
                    )
                } header: {
                    Text("cycle.settings.priors.header")
                } footer: {
                    Text("cycle.settings.priors.footer")
                }

                Section {
                    Picker("cycle.settings.secondarySymptom.label", selection: $secondarySymptom) {
                        Text("cycle.settings.secondarySymptom.mucus").tag(CycleSecondarySymptom.mucus)
                        Text("cycle.settings.secondarySymptom.cervix").tag(CycleSecondarySymptom.cervix)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("cycle.settings.secondarySymptom.header")
                } footer: {
                    Text("cycle.settings.secondarySymptom.footer")
                }

                Section("cycle.settings.privacy.header") {
                    Toggle("cycle.settings.sensitiveEncryption.label", isOn: $sensitiveCategoryEncryption)
                    Toggle("cycle.settings.discreetNotifications.label", isOn: $discreetNotifications)
                }

                if let error {
                    Section { HLFormErrorText(error) }
                }
            }
            .disabled(isSaving)
            .navigationTitle("cycle.settings.title")
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
            .onAppear(perform: loadProfile)
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func numberField(
        _ key: LocalizedStringKey,
        text: Binding<String>,
        range: ClosedRange<Int>
    ) -> some View {
        TextField(key, text: text)
            .keyboardType(.numberPad)
            .onChange(of: text.wrappedValue) { _, value in
                let digits = value.filter(\.isNumber)
                if digits != value { text.wrappedValue = digits }
            }
            .accessibilityHint(Text(
                String(format: String(localized: "cycle.settings.range.hint"), range.lowerBound, range.upperBound)
            ))
    }

    private func loadProfile() {
        guard let profile = store.profile else { return }
        goal = profile.goalValue ?? .generalHealth
        predictionEnabled = profile.predictionEnabled
        rawChartMode = profile.rawChartMode
        typicalCycleLength = profile.typicalCycleLength.map(String.init) ?? ""
        typicalPeriodLength = profile.typicalPeriodLength.map(String.init) ?? ""
        lutealPhaseLength = profile.lutealPhaseLength.map(String.init) ?? ""
        secondarySymptom = profile.secondarySymptomValue
        sensitiveCategoryEncryption = profile.sensitiveCategoryEncryption
        discreetNotifications = profile.discreetNotifications
    }

    private func save() async {
        guard let cycle = patchField(typicalCycleLength, range: 15 ... 60),
              let period = patchField(typicalPeriodLength, range: 1 ... 15),
              let luteal = patchField(lutealPhaseLength, range: 10 ... 16) else
        {
            error = String(localized: "cycle.settings.validation.error")
            return
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let patch = CyclePrefsPatch(
            goal: goal,
            rawChartMode: rawChartMode,
            typicalCycleLength: cycle,
            typicalPeriodLength: period,
            lutealPhaseLength: luteal,
            predictionEnabled: predictionEnabled,
            discreetNotifications: discreetNotifications,
            sensitiveCategoryEncryption: sensitiveCategoryEncryption,
            secondarySymptom: secondarySymptom
        )
        if await store.updatePreferences(patch) {
            onDismiss()
        } else {
            error = store.lastError ?? String(localized: "cycle.settings.save.error")
        }
    }

    private func patchField(_ text: String, range: ClosedRange<Int>) -> RecordPatchField<Int>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .clear }
        guard let value = Int(trimmed), range.contains(value) else { return nil }
        return .set(value)
    }

    private func goalLabel(_ value: CycleGoal) -> LocalizedStringKey {
        switch value {
        case .generalHealth: "cycle.settings.goal.generalHealth"
        case .avoidPregnancy: "cycle.settings.goal.avoidPregnancy"
        case .tryingToConceive: "cycle.settings.goal.tryingToConceive"
        case .perimenopause: "cycle.settings.goal.perimenopause"
        case .off: "cycle.settings.goal.off"
        }
    }
}
