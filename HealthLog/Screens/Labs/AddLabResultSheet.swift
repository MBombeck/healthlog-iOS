import SwiftUI

/// Capture a new lab result. The user either links a catalog biomarker (then
/// analyte / unit / reference range are server-resolved + shown read-only) OR
/// enters a free-text analyte / unit / range. Value + date are always required.
struct AddLabResultSheet: View {
    let store: LabsStore

    @State private var selectedBiomarkerID: String?
    @State private var analyte = ""
    @State private var unit = ""
    /// "No unit" for a free-text ratio or index (the unity `"1"`).
    /// ``unit`` keeps what was typed for the way back.
    @State private var noUnit = false
    /// Read once per sheet: the switch is offered from server 1.46.6 on.
    @State private var offersNoUnit = LabUnit.offersNoUnit()
    /// #126 3.5 (v1.42.3) — a linked reading printed in another unit. The
    /// server converts it when it knows the pair, else refuses with a reason.
    @State private var printedUnit = ""
    @State private var valueText = ""
    /// Numeric vs. qualitative result mode, mirroring the web form
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
    /// Drives the discard-confirmation dialog.
    /// Initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    /// The focusable text fields, ordered analyte → unit → panel for the
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

    /// The form holds unsaved edits (any content field filled or a
    /// biomarker linked). A swipe-down while dirty triggers the discard guard.
    private var isDirty: Bool {
        selectedBiomarkerID != nil
            || !analyte.trimmingCharacters(in: .whitespaces).isEmpty
            || LabUnit.wire(typed: unit, noUnit: noUnit) != nil
            || !valueText.isEmpty
            || !trimmedQualitative.isEmpty
            || !referenceLowText.isEmpty
            || !referenceHighText.isEmpty
            || !panel.trimmingCharacters(in: .whitespaces).isEmpty
            || !note.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        // A qualitative row is complete with a non-empty result text
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
        HLSheetScaffold(
            "labs.add.sheetTitle",
            action: .add(isEnabled: canSave && !isSaving) { await save(keepOpen: false) },
            isDirty: isDirty
        ) {
            Form {
                Group {
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
                .hlFormRowSurface()
            }
            .hlPageMargins()
            // Seed focus onto the first manual-entry field once the
            // sheet settles (analyte for a free-text row, value for a linked one).
            .task {
                backdateBound = .now
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = isLinked ? .value : .analyte
            }
        }
    }

    private var biomarkerSection: some View {
        Section {
            // Build 3 / item 3.2 — hidden markers are dropped from the picker
            // (web parity, `lab-form.tsx:137`). Their historical results
            // still render everywhere; only NEW entry stops offering them.
            HLFormPicker(
                "labs.add.biomarker.label",
                selection: $selectedBiomarkerID,
                options: [String?.none] + store.biomarkers.selectable.map { String?.some($0.id) }
            ) { id in
                if let id, let marker = store.biomarkers.selectable.first(where: { $0.id == id }) {
                    Text(verbatim: marker.name)
                } else {
                    Text("labs.add.biomarker.none")
                }
            }
            if let marker = linkedMarker {
                LabeledContent {
                    Text(verbatim: LabUnit.standalone(marker.unit) ?? "")
                } label: {
                    HLRowTitle("labs.add.unit")
                }
                // A marker without a unit converts nothing, so
                // there is no printed unit to ask for.
                if !LabUnit.isUnity(marker.unit) {
                    TextField("labs.add.printedUnit", text: $printedUnit)
                        .accessibilityIdentifier("labs.add.printedUnit")
                }
                if let lower = marker.lowerBound {
                    LabeledContent {
                        Text(verbatim: lower.formatted())
                    } label: {
                        HLRowTitle("labs.add.referenceLow")
                    }
                }
                if let upper = marker.upperBound {
                    LabeledContent {
                        Text(verbatim: upper.formatted())
                    } label: {
                        HLRowTitle("labs.add.referenceHigh")
                    }
                }
            }
        } header: {
            // No footer: the rows above show where unit and range
            // come from, and the form says the rest itself.
            Text("labs.add.biomarker.section")
        }
    }

    /// Label above each field, like the marker editor: a filled field still
    /// says what it holds.
    private var freeTextSection: some View {
        Section {
            LabFormField("labs.add.analyte") {
                TextField("labs.add.analyte", text: $analyte)
                    .focused($focusedField, equals: .analyte)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .unit }
            }
            // "No unit" hides the field instead of leaving an empty one.
            if !noUnit {
                LabFormField("labs.add.unit") {
                    TextField("labs.unit.placeholder", text: LabUnit.fieldBinding(typed: $unit, noUnit: noUnit))
                        .focused($focusedField, equals: .unit)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .panel }
                }
            }
            if offersNoUnit {
                LabNoUnitToggle(isOn: $noUnit)
            }
            LabFormField("biomarker.editor.panel") {
                TextField("labs.add.panel", text: $panel)
                    .focused($focusedField, equals: .panel)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .value }
            }
            LabFormField("labs.add.referenceLow") {
                TextField("labs.add.referenceLow", text: $referenceLowText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .referenceLow)
            }
            LabFormField("labs.add.referenceHigh") {
                TextField("labs.add.referenceHigh", text: $referenceHighText)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .referenceHigh)
            }
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
                    if let shown = valueUnitSuffix {
                        Text(verbatim: shown).foregroundStyle(HLText.secondary)
                    }
                }
            case .qualitative:
                TextField("labs.form.qualitativePlaceholder", text: $qualitativeText)
                    .focused($focusedField, equals: .qualitative)
                    .accessibilityIdentifier("labs.form.qualitative.field")
                LabQualitativeSuggestionChips(text: $qualitativeText)
            }
            DatePicker(
                selection: $takenAt,
                in: ...backdateBound,
                displayedComponents: [.date, .hourAndMinute]
            ) {
                HLRowTitle("labs.add.takenAt")
            }
        }
    }

    /// The unit printed next to the value field: the printed unit of a linked
    /// reading, else the marker's or the typed unit. Nothing for "No unit".
    private var valueUnitSuffix: String? {
        if isLinked {
            if let marker = linkedMarker, LabUnit.isUnity(marker.unit) { return nil }
            return LabPrintedUnit.sent(printedUnit, markerUnit: linkedMarker?.unit)
                ?? LabUnit.suffix(linkedMarker?.unit)
        }
        return LabUnit.suffix(LabUnit.wire(typed: unit, noUnit: noUnit))
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
            // What the button keeps is its own second line; the
            // footer only counts what was saved.
            HLSettingsActionRow(
                icon: "plus",
                title: "labs.add.saveAndNext",
                subtitle: "labs.add.saveAndNext.footer",
                presents: .confirm
            ) {
                Task { await save(keepOpen: true) }
            }
            .disabled(!canSave || isSaving)
            .accessibilityIdentifier("labs.add.saveAndNext")
        } footer: {
            if savedCount > 0 {
                Text("labs.add.saveAndNext.saved \(savedCount)")
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
    /// Returns `true` when the sheet may close.
    @discardableResult
    private func save(keepOpen: Bool) async -> Bool {
        // Exactly one of value / valueText goes on the wire, matching
        // `lab-form.tsx:173-199`. Never both, never a fabricated 0.
        let numericValue: Double?
        let qualitativeValue: String?
        switch resultType {
        case .numeric:
            guard let parsed = parsedValue else { return false }
            numericValue = parsed
            qualitativeValue = nil
        case .qualitative:
            guard !trimmedQualitative.isEmpty else { return false }
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
                unit: numericValue == nil || LabUnit.isUnity(linkedMarker?.unit)
                    ? nil : LabPrintedUnit.sent(printedUnit, markerUnit: linkedMarker?.unit),
                takenAt: iso.string(from: takenAt),
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        } else {
            LabResultCreate(
                panel: trimmedPanel.isEmpty ? nil : trimmedPanel,
                analyte: analyte.trimmingCharacters(in: .whitespaces),
                value: numericValue,
                valueText: qualitativeValue,
                unit: LabUnit.wire(typed: unit, noUnit: noUnit),
                referenceLow: LocaleDecimalParser.parse(referenceLowText),
                referenceHigh: LocaleDecimalParser.parse(referenceHighText),
                takenAt: iso.string(from: takenAt),
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        }

        guard await store.createLab(body) else {
            saveError = store.lastError ?? String(localized: "labs.save.failed")
            return false
        }
        if keepOpen {
            savedCount += 1
            resetForNextValue()
            return false
        }
        return true
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
        noUnit = next.noUnit
        printedUnit = ""
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
            noUnit: noUnit,
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
