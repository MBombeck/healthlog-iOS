import SwiftUI

/// "Was eine Einheit enthält": the form that
/// sets a supplement's composition per tablet or capsule.
///
/// Pushed on the medication page's own navigation stack, not presented: the
/// frozen presentation census admits no new sheet. One row per nutrient
/// (nutrient from the server's catalogue, amount, unit from its input units),
/// up to 40. Save writes the whole composition (`PUT …/ingredients`); after
/// it the page re-reads the medication (`onSaved`), and the nutrient page
/// shows the new total on its next read, computed by the server.
struct MedicationCompositionEditor: View {
    @State private var model: MedicationCompositionEditorModel
    let offersLabelPhoto: Bool
    let onSaved: () async -> Void

    init(model: MedicationCompositionEditorModel, offersLabelPhoto: Bool, onSaved: @escaping () async -> Void) {
        _model = State(initialValue: model)
        self.offersLabelPhoto = offersLabelPhoto
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            switch model.catalogState {
            case .loading:
                Section {
                    // A real view, so the `.task` below has something to hang on.
                    HLInlineProgress()
                        .frame(maxWidth: .infinity, minHeight: HLHitTarget.minimum)
                        .accessibilityLabel(Text("medications.composition.edit.loading"))
                }
                .hlFormRowSurface()
            case let .disabled(reason):
                Section {
                    FeatureDisabledCard(variant: .inline, reason: reason)
                        .accessibilityIdentifier("medications.composition.edit.disabled")
                }
                .hlFormRowSurface()
            case .failed:
                Section {
                    Text("medications.composition.edit.catalogFailed")
                        .foregroundStyle(HLText.secondary)
                    Button(HLControlWord.retry.key) {
                        Task { await model.retryCatalog() }
                    }
                    .accessibilityIdentifier("medications.composition.edit.retry")
                }
                .hlFormRowSurface()
            case let .loaded(catalog):
                if offersLabelPhoto { SupplementLabelCapture(model: model) }
                if let proposal = model.proposal { proposalSection(proposal) }
                rowsSection(catalog)
            }
        }
        .hlPageMargins()
        .task { await model.loadCatalog() }
        .onDisappear { model.cancelRead() }
        .navigationTitle(Text("medications.composition.edit.title"))
        .navigationBarTitleDisplayMode(.inline)
        // A pushed edit page: the check mark in the bar of the stack it is in,
        // the page goes back once the composition is saved and re-read.
        .hlConfirmBar(
            .save(isEnabled: model.canSave) {
                guard await model.save() else { return false }
                await onSaved()
                return true
            },
            identifier: "medications.composition.edit.save"
        )
    }

    // MARK: - Proposal

    private func proposalSection(_ proposal: SupplementLabelProposal) -> some View {
        Section {
            Text("medications.composition.label.reviewNote")
                .font(.hlSubhead)
                .fixedSize(horizontal: false, vertical: true)
            if let note = proposal.servingNote {
                Text(String(localized: "medications.composition.label.servingNote \(note)"))
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !proposal.unmatched.isEmpty {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text("medications.composition.label.unmatched")
                        .hlText(.rowSubtitle)
                    ForEach(Array(proposal.unmatched.enumerated()), id: \.offset) { _, text in
                        Text(verbatim: text)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.primary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("medications.composition.label.unmatchedList")
            }
        }
        .hlFormRowSurface()
        .accessibilityIdentifier("medications.composition.label.proposal")
    }

    // MARK: - Rows

    private func rowsSection(_ catalog: NutrientServerCatalog) -> some View {
        Section {
            if model.rows.isEmpty {
                Text("medications.composition.edit.empty")
                    .foregroundStyle(HLText.secondary)
            }
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                MedicationCompositionRowEditor(model: model, row: row, catalog: catalog)
                    .accessibilityIdentifier("medications.composition.edit.row.\(index)")
            }
            HLSettingsActionRow(title: "medications.composition.edit.addRow", presents: .create) {
                model.addRow()
            }
            .disabled(!model.canAddRow)
            .accessibilityIdentifier("medications.composition.edit.addRow")
            if let error = model.saveError {
                HLFormErrorText(error)
                    .font(.hlCaption)
                    .accessibilityIdentifier("medications.composition.edit.error")
            }
        } header: {
            HLSectionHeader("medications.composition.edit.rowsHeader")
        } footer: {
            Text("medications.composition.edit.footer")
                .font(.hlCaption)
        }
        .hlFormRowSurface()
    }
}

/// One line of the composition: nutrient, amount and unit, and a way to
/// remove it. Stacks at very large text sizes.
struct MedicationCompositionRowEditor: View {
    let model: MedicationCompositionEditorModel
    let row: MedicationCompositionEditorModel.Row
    let catalog: NutrientServerCatalog

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if dynamicTypeSize.isAccessibilitySize {
                // Very large text: the name gets the whole width, the remove
                // action its own line with words.
                nutrientPicker
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // The red minus stands first, as in the system's edit mode,
                // so it never meets the picker's chevron.
                HStack(spacing: HLSpace.sm) {
                    removeButton(showsTitle: false)
                    nutrientPicker
                }
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
                : AnyLayout(HStackLayout(spacing: HLSpace.sm))
            layout {
                TextField(
                    "medications.composition.edit.amount",
                    text: Binding(get: { row.amountText }, set: { model.setAmount($0, for: row.id) })
                )
                .keyboardType(.decimalPad)
                .disabled(model.isBusy)
                .accessibilityLabel(Text(String(localized: "medications.composition.edit.amountOf \(name)")))
                unitPicker
            }
            // The amount line starts under the nutrient, past the minus.
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : HLHitTarget.minimum + HLSpace.sm)
            if dynamicTypeSize.isAccessibilitySize { removeButton(showsTitle: true) }
            if row.needsCheck {
                Text("medications.composition.label.lowConfidence")
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let allowed = row.allowedUnits {
                let units = allowed.map(NutrientDisplay.ingredientUnitGlyph).formatted(.list(type: .or))
                HLFormErrorText(String(localized: "medications.composition.edit.allowedUnits \(units)"))
                    .font(.hlCaption)
            }
        }
        .padding(.vertical, HLSpace.xxs)
    }

    /// Takes a line out of the unsaved draft; nothing stored is deleted
    /// until the page is saved, and leaving it keeps the stored lines.
    private func removeButton(showsTitle: Bool) -> some View {
        let remove = HLDeleteAction.undoable { model.remove(row.id) }
        return Group {
            if showsTitle {
                HLDeleteButton("medications.composition.edit.removeRow \(name)", form: .row, action: remove)
            } else {
                HLDeleteButton("medications.composition.edit.removeRow \(name)", form: .remove, action: remove)
            }
        }
        .disabled(model.isBusy)
    }

    private var entry: NutrientServerCatalogEntry? {
        catalog.entry(for: row.nutrient)
    }

    private var name: String {
        entry?.displayName ?? String(localized: "medications.composition.edit.nutrient")
    }

    private var nutrientPicker: some View {
        let taken = model.takenCodes(except: row.id)
        return Picker(selection: Binding(get: { row.nutrient }, set: { model.choose(nutrient: $0, for: row.id) })) {
            if row.nutrient.isEmpty {
                Text("medications.composition.edit.choose").tag("")
            }
            ForEach(catalog.ingredientEntries.filter { !taken.contains($0.code) }) { option in
                Text(verbatim: option.displayName).tag(option.code)
            }
        } label: {
            HLRowTitle("medications.composition.edit.nutrient")
        }
        .pickerStyle(.menu)
        .disabled(model.isBusy)
    }

    private var unitPicker: some View {
        Picker(selection: Binding(get: { row.unit }, set: { model.setUnit($0, for: row.id) })) {
            let units = entry?.offeredUnits ?? []
            if !units.contains(row.unit) {
                Text(verbatim: row.unit.isEmpty ? "" : NutrientDisplay.ingredientUnitGlyph(row.unit)).tag(row.unit)
            }
            ForEach(units, id: \.self) { unit in
                Text(verbatim: NutrientDisplay.ingredientUnitGlyph(unit)).tag(unit)
            }
        } label: {
            HLRowTitle("medications.composition.edit.unit")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(model.isBusy || entry == nil)
        .accessibilityLabel(Text(String(localized: "medications.composition.edit.unitOf \(name)")))
    }
}
