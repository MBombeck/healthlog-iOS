import SwiftUI

/// **AUDITC (1.5.0, #132)** — the three AUDIT-C items, unfolded in the
/// alcohol section.
///
/// Stems and answers are rendered exactly as `auditC.instrument` delivered
/// them, tagged with the instrument's language so VoiceOver reads them in it.
/// When the account language has no validated translation the server sends
/// the WHO English original (`validatedLocale: false`) and the form says so
/// in one line; there is no translation of the app's own to switch to, so
/// the original is all there is. The standard drink and the WHO note stand
/// as the server sent them.
struct AuditCForm: View {
    let instrument: AuditCInstrument
    let store: LifeCircumstancesStore
    @Bindable var model: AuditCModel

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            if !instrument.validatedLocale {
                LifeDerivedLine(
                    text: String(localized: "life.auditC.notValidated"),
                    secondary: true,
                    identifier: "life.auditC.notValidated"
                )
            }
            if !instrument.standardDrink.isEmpty {
                Text(verbatim: instrument.standardDrink)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("life.auditC.standardDrink")
            }
            ForEach(Array(instrument.items.enumerated()), id: \.offset) { index, item in
                itemView(index, item)
            }
            if !instrument.attribution.isEmpty {
                Text(Self.spoken(instrument.attribution, language: "en"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("life.auditC.attribution")
            }
            submitRow
        }
    }

    private func itemView(_ index: Int, _ item: AuditCInstrument.Item) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(Self.spoken("\(index + 1). \(item.stem)", language: instrument.locale))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("life.auditC.item.\(index)")
            ForEach(item.options) { option in
                optionRow(option, item: index)
            }
        }
    }

    private func optionRow(_ option: AuditCInstrument.Option, item index: Int) -> some View {
        let isSelected = model.answer(index) == option.value
        return Button {
            model.select(option.value, item: index)
        } label: {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? HLAccent.userBrandTint : HLText.tertiary)
                    .accessibilityHidden(true)
                Text(Self.spoken(option.label, language: instrument.locale))
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
        .disabled(model.isSubmitting)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("life.auditC.item.\(index).option.\(option.value)")
    }

    private var submitRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if let error = model.submitError {
                HLFormErrorText(error)
                    .accessibilityIdentifier("life.auditC.error")
            }
            HLButton("life.auditC.submit", variant: .primary, isLoading: model.isSubmitting) {
                Task { await model.submit(instrument, store: store) }
            }
            .disabled(!model.isComplete || model.isSubmitting)
            .accessibilityIdentifier("life.auditC.submit")
            Button {
                withHLAnimation(.easeInOut(duration: 0.2)) { model.cancel() }
            } label: {
                Text("Cancel")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isSubmitting)
            .accessibilityIdentifier("life.auditC.cancel")
        }
    }

    /// Questionnaire text tagged with its language for speech.
    static func spoken(_ text: String, language: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.languageIdentifier = language
        return attributed
    }
}
