import SwiftUI

/// One-question-at-a-time check-in driven entirely by the instrument registry.
/// Answering advances between scored items, while submission always requires a
/// deliberate button tap. PHQ-9 alone has an optional, unscored final question.
///
/// Stems, items and answer labels are the server's wording in
/// the interface language (``MentalHealthStore/activeWording``), never catalogue
/// strings. Where that text is not a validated translation the header says so
/// in one line and a centred text link below switches to the English original
/// and back.
struct MentalWellbeingForm: View {
    @Bindable var store: MentalHealthStore

    @State private var step = 0

    private var instrument: MentalHealthInstrument {
        store.activeInstrument
    }

    private var scoredCount: Int {
        instrument.itemCount
    }

    private var hasFunctionalFollowUp: Bool {
        instrument.showsFunctionalFollowUp
    }

    private var totalSteps: Int {
        scoredCount + (hasFunctionalFollowUp ? 1 : 0)
    }

    private var isFunctionalStep: Bool {
        hasFunctionalFollowUp && step == scoredCount
    }

    /// "3 / 9" for a scored question, `nil` for the unscored follow-up.
    nonisolated static func progress(step: Int, scoredCount: Int) -> (current: Int, total: Int)? {
        guard step < scoredCount else { return nil }
        return (step + 1, scoredCount)
    }

    private var isLastStep: Bool {
        step == totalSteps - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLLayout.sectionGapBefore) {
            instrumentHeader
            if store.translationIsUnvalidated {
                wordingToggle
            }
            progressHeader

            Group {
                if isFunctionalStep {
                    functionalStep
                } else {
                    questionStep(step)
                }
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
    }

    private var instrumentHeader: some View {
        // The instrument's name is the page title while the check-in runs
        // (MentalWellbeingScreen), so the header starts with what it asks.
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(localizedKey("mentalHealth.instrumentDescription.\(instrument.keySegment)"))
                .hlText(.pageSubtitle)
                .fixedSize(horizontal: false, vertical: true)
            if store.translationIsUnvalidated {
                Text("mentalHealth.wording.unvalidatedNote")
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mentalHealth.wording.unvalidatedNote")
            } else {
                // The validated wording keeps its own form of address, which
                // is not the app's; one line says why.
                Text("mentalHealth.wording.originalNote")
                    .hlText(.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mentalHealth.wording.originalNote")
            }
            // 1.0.3 (1.4.1) — screening, not diagnosis: stated before the first
            // question, not just on the result.
            Text("mentalHealth.disclaimer")
                .hlText(.note)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mentalHealth.form.disclaimer")
        }
    }

    /// The switch between the reader's translation and the English original,
    /// a quiet centred text link under the header (the "Erweitert" pattern).
    private var wordingToggle: some View {
        HLLinkButton(Text(store.showsEnglishOriginal ? "mentalHealth.wording.showTranslation" : "mentalHealth.wording.showOriginal")) {
            withAnimation(.easeInOut(duration: 0.2)) { store.toggleEnglishOriginal() }
        }
        .disabled(store.isSubmitting)
        .accessibilityIdentifier("mentalHealth.wording.toggle")
    }

    /// Back and forth between the questions, around the counter. Forward
    /// only over an answered question; answering moves on by itself.
    private var progressHeader: some View {
        HLStepperHeader(
            title: progressTitle,
            canGoPrevious: step > 0,
            canGoNext: Self.canAdvance(step: step, answers: store.answers, totalSteps: totalSteps),
            identifier: "mentalHealth.step",
            previous: goBack,
            next: goForward
        )
    }

    /// The counter runs over the scored questions; PHQ-9's optional
    /// follow-up is not one of the nine and carries no number.
    private var progressTitle: Text {
        if let progress = Self.progress(step: step, scoredCount: scoredCount) {
            return Text("mentalHealth.progress \(progress.current) \(progress.total)")
        }
        return Text("questionnaire.step.followUp")
    }

    /// Forward is open while a later step exists and this one is answered.
    nonisolated static func canAdvance(step: Int, answers: [Int], totalSteps: Int) -> Bool {
        guard step < totalSteps - 1 else { return false }
        return answers.indices.contains(step) && answers[step] >= 0
    }

    private func questionStep(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            if let stem = wording?.stem(instrument.stemIDs[index]) {
                Text(spoken(stem))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(spoken(wording?.item(index) ?? ""))
                .hlText(.objectName)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mentalHealth.item.\(index).text")

            MentalHealthOptionPicker(
                labels: anchorLabels(forItem: index),
                language: store.activeWordingLanguage,
                values: instrument.optionOrder,
                selected: store.answers.indices.contains(index) ? store.answers[index] : -1,
                accessibilityPrefix: "mentalHealth.item.\(index)",
                onSelect: { answer(index, $0) }
            )
            .disabled(store.isSubmitting)

            if isLastStep {
                submitSection
            }
        }
    }

    private var functionalStep: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // "(optional)" rides on the question instead of a
            // sentence under it.
            Text(
                "\(Text(spoken(wording?.functional?.title ?? ""))) \(Text("mentalHealth.functionalOptional").foregroundStyle(HLText.secondary))"
            )
            .hlText(.objectName)
            .fixedSize(horizontal: false, vertical: true)

            MentalHealthOptionPicker(
                labels: Dictionary(uniqueKeysWithValues: (0 ... 3).map { ($0, wording?.functional?.anchor($0) ?? "") }),
                language: store.activeWordingLanguage,
                values: [0, 1, 2, 3],
                selected: store.functionalDifficulty ?? -1,
                accessibilityPrefix: "mentalHealth.functional",
                onSelect: { toggleFunctional($0) }
            )
            .disabled(store.isSubmitting)

            submitSection
        }
    }

    private var submitSection: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if store.lastError != nil {
                Text("mentalHealth.error")
                    .hlText(.emptyMessage, status: HLColor.statusBad)
                    .accessibilityIdentifier("mentalHealth.error")
            }
            HLButton(
                "mentalHealth.submit",
                variant: .primary,
                isLoading: store.isSubmitting
            ) {
                Task { await store.submit() }
            }
            .disabled(!store.isComplete || store.isSubmitting)
            .accessibilityIdentifier("mentalHealth.submit")
        }
    }

    private func answer(_ index: Int, _ value: Int) {
        store.setAnswer(value, at: index)
        guard !isLastStep else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            step = min(step + 1, totalSteps - 1)
        }
    }

    private func toggleFunctional(_ value: Int) {
        store.setFunctionalDifficulty(store.functionalDifficulty == value ? nil : value)
    }

    private func goBack() {
        withAnimation(.easeInOut(duration: 0.25)) {
            step = max(step - 1, 0)
        }
    }

    private func goForward() {
        guard Self.canAdvance(step: step, answers: store.answers, totalSteps: totalSteps) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            step = min(step + 1, totalSteps - 1)
        }
    }

    private var wording: QuestionnaireWording? {
        store.activeWording
    }

    private func anchorLabels(forItem index: Int) -> [Int: String] {
        let group = instrument.anchorGroup(forItem: index)
        return Dictionary(uniqueKeysWithValues: instrument.optionOrder.map {
            ($0, wording?.anchor(group: group, value: $0) ?? "")
        })
    }

    /// Questionnaire text tagged with its language, so VoiceOver reads the
    /// English original in English under a German or Dutch interface.
    private func spoken(_ text: String) -> AttributedString {
        MentalHealthOptionPicker.spoken(text, language: store.activeWordingLanguage)
    }

    private func localizedKey(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

/// Single-select rows used by both scored and optional questions, the
/// check mark at the trailing edge like every single choice in the app.
/// The labels are questionnaire text (server wording), not catalogue keys.
struct MentalHealthOptionPicker: View {
    let labels: [Int: String]
    let language: AppLanguage
    let values: [Int]
    let selected: Int
    let accessibilityPrefix: String
    let onSelect: (Int) -> Void

    var body: some View {
        HLCard(layout: .rows) {
            ForEach(values, id: \.self) { value in
                HLChoiceRow(
                    title: Text(Self.spoken(labels[value] ?? "", language: language)),
                    isSelected: selected == value
                ) {
                    onSelect(value)
                }
                .accessibilityIdentifier("\(accessibilityPrefix).option.\(value)")
            }
        }
    }

    /// `text` with its language attached for speech.
    static func spoken(_ text: String, language: AppLanguage) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.languageIdentifier = language.rawValue
        return attributed
    }
}
