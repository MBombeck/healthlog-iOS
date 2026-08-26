import SwiftUI

/// Capture a new lab result. The user either links a catalog biomarker (then
/// analyte / unit / reference range are server-resolved + shown read-only) OR
/// enters a free-text analyte / unit / range. Value + date are always required.
struct AddLabResultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: LabsStore

    @State private var selectedBiomarkerID: String?
    @State private var analyte = ""
    @State private var unit = ""
    @State private var valueText = ""
    /// Item 1.5 — numeric vs. qualitative result mode, mirroring the web form
    /// (`lab-form.tsx:111-113`). Qualitative mode enters a result TEXT
    /// ("negativ" / "positiv" / "grenzwertig" / free text) and posts `valueText`
    /// instead of `value`.
    @State private var resultType: LabResultType = .numeric
    /// The qualitative result text. Separate from ``valueText`` (the numeric
    /// field's string) so switching modes never smuggles "72,4" in as a result.
    @State private var qualitativeText = ""
    @State private var referenceLowText = ""
    @State private var referenceHighText = ""
    @State private var panel = ""
    @State private var note = ""
    @State private var takenAt = Date.now
    /// Upper bound for the `takenAt` picker — a blood draw cannot happen in the
    /// future (web: `lab-form.tsx` `max={defaultTakenAtValue()}`). Held in state
    /// rather than recomputed per render so the picker's range doesn't churn on
    /// every layout pass; refreshed when the sheet settles.
    @State private var backdateBound = Date.now
    @State private var isSaving = false
    @State private var saveError: String?
    /// Build 3 / item 3.2 — how many values this sheet session has saved via
    /// "Save & next value". Drives the confirmation footer; without it a
    /// successful save is invisible, because the sheet looks the same after it.
    @State private var savedCount = 0
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-2 (Audit v0162) — initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    /// FORM-2 — the focusable text fields, ordered analyte → unit → panel for the
    /// `.submitLabel(.next)` chain (the decimal-pad value/range fields have no
    /// Return key, so they're focus targets only).
    private enum Field: Hashable {
        case analyte, unit, panel, referenceLow, referenceHigh, value, qualitative, note
    }

    private var linkedMarker: BiomarkerDTO? {
        guard let selectedBiomarkerID else { return nil }
        return store.biomarkers.first { $0.id == selectedBiomarkerID }
    }

    private var isLinked: Bool {
        linkedMarker != nil
    }

    /// FORM-1 — the form holds unsaved edits (any content field filled or a
    /// biomarker linked). A swipe-down while dirty triggers the discard guard.
    private var isDirty: Bool {
        selectedBiomarkerID != nil
            || !analyte.trimmingCharacters(in: .whitespaces).isEmpty
            || !unit.trimmingCharacters(in: .whitespaces).isEmpty
            || !valueText.isEmpty
            || !trimmedQualitative.isEmpty
            || !referenceLowText.isEmpty
            || !referenceHighText.isEmpty
            || !panel.trimmingCharacters(in: .whitespaces).isEmpty
            || !note.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        // Item 1.5 — a qualitative row is complete with a non-empty result text
        // and no number at all; the numeric row still needs a parseable value.
        switch resultType {
        case .numeric:
            guard parsedValue != nil else { return false }
        case .qualitative:
            guard !trimmedQualitative.isEmpty else { return false }
        }
        // A free-text row needs an analyte; a linked row resolves it server-side.
        return isLinked || !analyte.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var parsedValue: Double? {
        LocaleDecimalParser.parse(valueText)
    }

    private var trimmedQualitative: String {
        qualitativeText.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                biomarkerSection
                if !isLinked {
                    freeTextSection
                }
                valueSection
                noteSection
                saveAndNextSection
                if let saveError {
                    Section { HLFormErrorText(saveError) }
                }
            }
            .navigationTitle(Text("labs.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("labs.action.cancel") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("labs.action.save") {
                        Task { await save(keepOpen: false) }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            // FORM-2 — seed focus onto the first manual-entry field once the
            // sheet settles (analyte for a free-text row, value for a linked one).
            .task {
                backdateBound = .now
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = isLinked ? .value : .analyte
            }
        }
        // FORM-1 — block the accidental swipe-down that would silently discard a
        // filled lab form; keep the existing in-flight save lock.
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    private var biomarkerSection: some View {
        Section {
            Picker(selection: $selectedBiomarkerID) {
                Text("labs.add.biomarker.none").tag(String?.none)
                // Build 3 / item 3.2 — hidden markers are dropped from the
                // picker (web parity, `lab-form.tsx:137`). Their historical
                // results still render everywhere; only NEW entry stops
                // offering them.
                ForEach(store.biomarkers.selectable) { marker in
                    Text(marker.name).tag(String?.some(marker.id))
                }
            } label: {
                Text("labs.add.biomarker.label")
            }
            if let marker = linkedMarker {
                LabeledContent("labs.add.unit", value: marker.unit)
                if let lower = marker.lowerBound {
                    LabeledContent("labs.add.referenceLow", value: lower.formatted())
                }
                if let upper = marker.upperBound {
                    LabeledContent("labs.add.referenceHigh", value: upper.formatted())
                }
            }
        } header: {
            Text("labs.add.biomarker.section")
        } footer: {
            Text(isLinked ? "labs.add.biomarker.linkedFooter" : "labs.add.biomarker.freeFooter")
        }
    }

    private var freeTextSection: some View {
        Section {
            TextField("labs.add.analyte", text: $analyte)
                .focused($focusedField, equals: .analyte)
                .submitLabel(.next)
                .onSubmit { focusedField = .unit }
            TextField("labs.add.unit", text: $unit)
                .focused($focusedField, equals: .unit)
                .submitLabel(.next)
                .onSubmit { focusedField = .panel }
            TextField("labs.add.panel", text: $panel)
                .focused($focusedField, equals: .panel)
                .submitLabel(.next)
                .onSubmit { focusedField = .value }
            TextField("labs.add.referenceLow", text: $referenceLowText)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .referenceLow)
            TextField("labs.add.referenceHigh", text: $referenceHighText)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .referenceHigh)
        } header: {
            Text("labs.add.freeText.section")
        }
    }

    private var valueSection: some View {
        Section("labs.add.value.section") {
            LabResultTypePicker(resultType: $resultType)
            switch resultType {
            case .numeric:
                HStack {
                    TextField("labs.add.value", text: $valueText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .value)
                    if isLinked, let marker = linkedMarker, !marker.unit.isEmpty {
                        Text(marker.unit).foregroundStyle(HLText.secondary)
                    } else if !unit.isEmpty {
                        Text(unit).foregroundStyle(HLText.secondary)
                    }
                }
            case .qualitative:
                TextField("labs.form.qualitativePlaceholder", text: $qualitativeText)
                    .focused($focusedField, equals: .qualitative)
                    .accessibilityIdentifier("labs.form.qualitative.field")
                LabQualitativeSuggestionChips(text: $qualitativeText)
            }
            DatePicker(
                "labs.add.takenAt",
                selection: $takenAt,
                in: ...backdateBound,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }

    /// Build 3 / item 3.2 — "Save & next value". A real lab report is ten to
    /// twenty analytes sharing ONE blood-draw date; without this each of them
    /// costs a fresh sheet and a fresh date pick. Web parity:
    /// `lab-form.tsx:202-224`.
    ///
    /// What survives a save-and-next, and why:
    ///   - **`takenAt` stays.** This is the whole point. One report, one draw
    ///     date; re-picking it twenty times is the friction being removed.
    ///   - the biomarker selection RESETS — the next row is the next analyte.
    ///   - value / qualitative text / note reset; they belong to the row just
    ///     saved.
    ///   - the free-text analyte/unit/panel/bounds reset with the biomarker,
    ///     for the same reason.
    ///
    /// The counter is not decoration: after four taps the sheet looks identical
    /// to how it looked after one, so without it the operator has no way to
    /// tell a save landed.
    private var saveAndNextSection: some View {
        Section {
            Button {
                Task { await save(keepOpen: true) }
            } label: {
                Label("labs.add.saveAndNext", systemImage: "plus.circle")
            }
            .disabled(!canSave || isSaving)
            .accessibilityIdentifier("labs.add.saveAndNext")
        } footer: {
            if savedCount > 0 {
                Text("labs.add.saveAndNext.saved \(savedCount)")
            } else {
                Text("labs.add.saveAndNext.footer")
            }
        }
    }

    private var noteSection: some View {
        Section("labs.add.note.section") {
            TextField("labs.add.note", text: $note, axis: .vertical)
                .lineLimit(2 ... 4)
                .focused($focusedField, equals: .note)
        }
    }

    /// - Parameter keepOpen: `true` for "Save & next value" — the sheet stays
    ///   mounted and only the row-specific fields reset. `false` dismisses.
    private func save(keepOpen: Bool) async {
        // Item 1.5 — exactly one of value / valueText goes on the wire, matching
        // `lab-form.tsx:173-199`. Never both, never a fabricated 0.
        let numericValue: Double?
        let qualitativeValue: String?
        switch resultType {
        case .numeric:
            guard let parsed = parsedValue else { return }
            numericValue = parsed
            qualitativeValue = nil
        case .qualitative:
            guard !trimmedQualitative.isEmpty else { return }
            numericValue = nil
            qualitativeValue = trimmedQualitative
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let iso = ISO8601DateFormatter()
        let trimmedPanel = panel.trimmingCharacters(in: .whitespaces)
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let body = if isLinked {
            LabResultCreate(
                biomarkerId: selectedBiomarkerID,
                value: numericValue,
                valueText: qualitativeValue,
                takenAt: iso.string(from: takenAt),
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        } else {
            LabResultCreate(
                panel: trimmedPanel.isEmpty ? nil : trimmedPanel,
                analyte: analyte.trimmingCharacters(in: .whitespaces),
                value: numericValue,
                valueText: qualitativeValue,
                unit: unit.trimmingCharacters(in: .whitespaces).isEmpty ? nil : unit.trimmingCharacters(in: .whitespaces),
                referenceLow: LocaleDecimalParser.parse(referenceLowText),
                referenceHigh: LocaleDecimalParser.parse(referenceHighText),
                takenAt: iso.string(from: takenAt),
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        }

        guard await store.createLab(body) else {
            saveError = store.lastError ?? String(localized: "labs.save.failed")
            return
        }
        if keepOpen {
            savedCount += 1
            resetForNextValue()
        } else {
            dismiss()
        }
    }

    /// Clear the row-specific fields, **deliberately keeping `takenAt`.**
    ///
    /// The POLICY — which fields survive and which are cleared — lives in
    /// ``LabEntryDraft/resetForNextValue()`` so it is unit-testable; `@State`
    /// is not reachable from a test. This function is only the plumbing that
    /// reads the current fields into a draft and writes the reset draft back.
    /// Do not re-implement the rule here.
    private func resetForNextValue() {
        let next = currentDraft.resetForNextValue()
        selectedBiomarkerID = next.selectedBiomarkerID
        analyte = next.analyte
        unit = next.unit
        valueText = next.valueText
        qualitativeText = next.qualitativeText
        referenceLowText = next.referenceLowText
        referenceHighText = next.referenceHighText
        panel = next.panel
        note = next.note
        takenAt = next.takenAt
        resultType = next.resultType
        saveError = nil
        // Focus returns to the top of the form so the next analyte can be
        // picked without a scroll.
        focusedField = .analyte
    }

    /// The form's current contents as a plain value, for the reset policy.
    private var currentDraft: LabEntryDraft {
        LabEntryDraft(
            selectedBiomarkerID: selectedBiomarkerID,
            analyte: analyte,
            unit: unit,
            valueText: valueText,
            qualitativeText: qualitativeText,
            referenceLowText: referenceLowText,
            referenceHighText: referenceHighText,
            panel: panel,
            note: note,
            takenAt: takenAt,
            resultType: resultType
        )
    }
}
