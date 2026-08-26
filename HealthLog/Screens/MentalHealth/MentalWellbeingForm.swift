import SwiftUI

/// One-question-at-a-time check-in driven entirely by the instrument registry.
/// Answering advances between scored items, while submission always requires a
/// deliberate button tap. PHQ-9 alone has an optional, unscored final question.
struct MentalWellbeingForm: View {
    @Bindable var store: MentalHealthStore

    @Environment(\.locale) private var locale
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
            if !instrument.hasValidatedItems(locale: locale.identifier) {
                Text("mentalHealth.validatedInEnglishNote")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mentalHealth.validatedInEnglishNote")
            }
        }
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
            if let stemKey = instrument.stemKey(forItem: index) {
                Text(LocalizedStringKey(stemKey))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(itemText(index))
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)

            MentalHealthOptionPicker(
                optionKeyPrefix: instrument.optionKeyPrefix(forItem: index),
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
            Text("mentalHealth.functionalTitle")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("mentalHealth.functionalOptionalHint")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)

            MentalHealthOptionPicker(
                optionKeyPrefix: "mentalHealth.functional",
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

    private func itemText(_ index: Int) -> LocalizedStringKey {
        localizedKey("mentalHealth.items.\(instrument.keySegment).\(index + 1)")
    }

    private func localizedKey(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

/// Vertical single-select rows used by both scored and optional questions.
struct MentalHealthOptionPicker: View {
    let optionKeyPrefix: String
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
        let optionKey = "\(optionKeyPrefix).\(value)"
        return Button {
            onSelect(value)
        } label: {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? HLAccent.userBrandTint : HLText.tertiary)
                Text(LocalizedStringKey(optionKey))
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
}
