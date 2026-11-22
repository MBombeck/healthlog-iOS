import SwiftUI

/// Explicit, transactional editor for every visible cycle preference except
/// `enabled`, which remains owned by the later opt-in build.
struct CycleAdvancedSettingsSheet: View {
    let store: CycleStore

    @State private var goal: CycleGoal = .generalHealth
    @State private var predictionEnabled = true
    @State private var rawChartMode = false
    @State private var typicalCycleLength = ""
    @State private var typicalPeriodLength = ""
    @State private var lutealPhaseLength = ""
    @State private var secondarySymptom: CycleSecondarySymptom = .mucus
    @State private var sensitiveCategoryEncryption = false
    @State private var discreetNotifications = false
    @State private var error: String?

    var body: some View {
        HLSheetScaffold("cycle.settings.title", action: .save { await save() }) {
            Form {
                Group {
                    Section {
                        HLFormPicker(
                            "cycle.settings.goal.label",
                            selection: $goal,
                            options: CycleGoal.allCases
                        ) { Text(goalLabel($0)) }
                        Toggle(isOn: $predictionEnabled) {
                            HLRowTitle("cycle.settings.prediction.label")
                        }
                        Toggle(isOn: $rawChartMode) {
                            HLRowTitle("cycle.settings.rawMode.label")
                        }
                    } header: {
                        HLSectionHeader("cycle.settings.goal.header", rank: .group)
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
                        HLSectionHeader("cycle.settings.priors.header", rank: .group)
                    }

                    Section {
                        HLAdaptiveSegmentedPicker(
                            "cycle.settings.secondarySymptom.label",
                            selection: $secondarySymptom,
                            labels: ["cycle.settings.secondarySymptom.mucus", "cycle.settings.secondarySymptom.cervix"]
                        ) {
                            Text("cycle.settings.secondarySymptom.mucus").tag(CycleSecondarySymptom.mucus)
                            Text("cycle.settings.secondarySymptom.cervix").tag(CycleSecondarySymptom.cervix)
                        }
                    } header: {
                        HLSectionHeader("cycle.settings.secondarySymptom.header", rank: .group)
                    } footer: {
                        Text("cycle.settings.secondarySymptom.footer")
                    }

                    Section {
                        Toggle(isOn: $sensitiveCategoryEncryption) {
                            HLRowTitle("cycle.settings.sensitiveEncryption.label")
                        }
                        Toggle(isOn: $discreetNotifications) {
                            HLRowTitle("cycle.settings.discreetNotifications.label")
                        }
                    } header: {
                        HLSectionHeader("cycle.settings.privacy.header", rank: .group)
                    }

                    // The way to the Apple Health sync, which stood as a
                    // loose link under the last card of the cycle screen.
                    Section {
                        HLSettingsActionRow(icon: "heart.text.square", title: "Apple Health", presents: .push) {
                            AppleHealthIntegrationDetailScreen()
                        }
                        .accessibilityIdentifier("cycle.settings.appleHealth")
                    }

                    if let error {
                        Section { HLFormErrorText(error) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
            .onAppear(perform: loadProfile)
        }
    }

    /// Label left, value right; an empty field reads "Automatisch",
    /// which is what clearing a prior means (the footer that said so is gone).
    private func numberField(
        _ key: LocalizedStringKey,
        text: Binding<String>,
        range: ClosedRange<Int>
    ) -> some View {
        LabeledContent {
            TextField(text: text, prompt: Text("cycle.settings.priors.automatic").foregroundStyle(HLText.tertiary)) {
                Text(key)
            }
            .multilineTextAlignment(.trailing)
            // A value is two digits; the label keeps the rest of the row.
            .frame(maxWidth: 120)
            .keyboardType(.numberPad)
            .onChange(of: text.wrappedValue) { _, value in
                let digits = value.filter(\.isNumber)
                if digits != value { text.wrappedValue = digits }
            }
            .accessibilityHint(Text(
                String(format: String(localized: "cycle.settings.range.hint"), range.lowerBound, range.upperBound)
            ))
        } label: {
            HLRowTitle(key)
        }
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

    /// `true` when the sheet may close.
    private func save() async -> Bool {
        guard let cycle = patchField(typicalCycleLength, range: 15 ... 60),
              let period = patchField(typicalPeriodLength, range: 1 ... 15),
              let luteal = patchField(lutealPhaseLength, range: 10 ... 16) else
        {
            error = String(localized: "cycle.settings.validation.error")
            return false
        }
        error = nil
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
        if await store.updatePreferences(patch) { return true }
        error = store.lastError ?? String(localized: "cycle.settings.save.error")
        return false
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
