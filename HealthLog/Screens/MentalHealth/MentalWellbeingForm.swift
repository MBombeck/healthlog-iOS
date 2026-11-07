import SwiftUI

/// One-question-at-a-time check-in driven entirely by the instrument registry.
/// Answering advances between scored items, while submission always requires a
/// deliberate button tap. PHQ-9 alone has an optional, unscored final question.
///
/// 1.5.0 (L10N-MH): stems, items and answer labels are the server's wording in
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

    private var isLastStep: Bool {
        step == totalSteps - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xl) {
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
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(localizedKey("mentalHealth.instrument.\(instrument.keySegment)"))
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
            Text(localizedKey("mentalHealth.instrumentDescription.\(instrument.keySegment)"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.translationIsUnvalidated {
                Text("mentalHealth.wording.unvalidatedNote")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mentalHealth.wording.unvalidatedNote")
            }
            // 1.0.3 (1.4.1) — screening, not diagnosis: stated before the first
            // question, not just on the result.
            Text("mentalHealth.disclaimer")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mentalHealth.form.disclaimer")
        }
    }

    /// The switch between the reader's translation and the English original,
    /// a quiet centred text link under the header (the "Erweitert" pattern).
    private var wordingToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { store.toggleEnglishOriginal() }
        } label: {
            Text(store.showsEnglishOriginal ? "mentalHealth.wording.showTranslation" : "mentalHealth.wording.showOriginal")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isSubmitting)
        .accessibilityIdentifier("mentalHealth.wording.toggle")
    }

    private var progressHeader: some View {
        HStack(spacing: HLSpace.sm) {
            if step > 0 {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLAccent.userBrandTint)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("mentalHealth.back"))
                .accessibilityIdentifier("mentalHealth.back")
            }

            Text("mentalHealth.progress \(step + 1) \(totalSteps)")
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
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
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
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
            // 1.4 B2 — "(optional)" rides on the question instead of a
            // sentence under it.
            (Text(spoken(wording?.functional?.title ?? "")) + Text(verbatim: " ")
                + Text("mentalHealth.functionalOptional").foregroundStyle(HLText.secondary))
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
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
                    .font(.hlSubhead)
                    .foregroundStyle(HLColor.statusBad)
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

/// Vertical single-select rows used by both scored and optional questions.
/// The labels are questionnaire text (server wording), not catalogue keys.
struct MentalHealthOptionPicker: View {
    let labels: [Int: String]
    let language: AppLanguage
    let values: [Int]
    let selected: Int
    let accessibilityPrefix: String
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: HLSpace.xs) {
            ForEach(values, id: \.self) { value in
                optionRow(value)
            }
        }
    }

    private func optionRow(_ value: Int) -> some View {
        let isSelected = selected == value
        return Button {
            onSelect(value)
        } label: {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? HLAccent.userBrandTint : HLText.tertiary)
                Text(Self.spoken(labels[value] ?? "", language: language))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, HLSpace.xs)
            .padding(.horizontal, HLSpace.sm)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous)
                    .fill(isSelected ? HLAccent.userBrandTint.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityPrefix).option.\(value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `text` with its language attached for speech.
    static func spoken(_ text: String, language: AppLanguage) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.languageIdentifier = language.rawValue
        return attributed
    }
}
