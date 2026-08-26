import SwiftUI

/// Edit an existing lab result. When the row is linked to a catalog biomarker
/// (`biomarkerId != nil`) the analyte / unit / reference range are
/// server-resolved and shown READ-ONLY (editing them would drift from the
/// catalog); only value / date / note are editable. A free-text row keeps all
/// fields editable.
struct EditLabResultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: LabsStore
    let result: LabResultDTO

    @State private var analyte: String
    @State private var unit: String
    @State private var valueText: String
    @State private var qualitativeText: String
    @State private var backdateBound = Date.now
    @State private var referenceLowText: String
    @State private var referenceHighText: String
    @State private var panel: String
    @State private var takenAt: Date
    @State private var note: String
    @State private var loadedNote = false
    /// Build 3 / item 3.2 — the row has a note but the detail GET that carries
    /// its decrypted body failed. The field is empty for the WRONG reason, so a
    /// save must leave the note untouched rather than clear it.
    @State private var noteLoadFailed = false
    @State private var isSaving = false
    @State private var saveError: String?
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-1 — the note loads async; capture its loaded value so a note edit is
    /// detectable and an untouched note never reads as dirty.
    @State private var initialNote = ""
    /// FORM-2 (Audit v0162) — initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    private let initialTakenAt: Date
    /// The prefilled numeric text — the dirty check compares against THIS rather
    /// than re-deriving it, so a qualitative row (no number) has a stable "".
    private let initialValueText: String
    private let initialQualitative: String

    /// Item 1.5 — the row's result type is a FACT about the row, not a choice
    /// the editor offers (the server refuses type switches on `PUT`).
    private var resultType: LabResultType {
        result.isQualitative ? .qualitative : .numeric
    }

    private enum Field: Hashable {
        case analyte, unit, panel, referenceLow, referenceHigh, value, qualitative, note
    }

    init(store: LabsStore, result: LabResultDTO) {
        self.store = store
        self.result = result
        _analyte = State(initialValue: result.analyte)
        _unit = State(initialValue: result.unit)
        // Item 1.5 — an absent / qualitative row prefills an EMPTY numeric field
        // instead of the old fabricated "0".
        let seededValueText = result.value.map { $0.formatted(.number.precision(.fractionLength(0 ... 2))) } ?? ""
        _valueText = State(initialValue: seededValueText)
        initialValueText = seededValueText
        let seededQualitative = result.valueText ?? ""
        _qualitativeText = State(initialValue: seededQualitative)
        initialQualitative = seededQualitative
        _referenceLowText = State(initialValue: result.referenceLow.map { $0.formatted() } ?? "")
        _referenceHighText = State(initialValue: result.referenceHigh.map { $0.formatted() } ?? "")
        _panel = State(initialValue: result.panel ?? "")
        let parsedTakenAt = LabsDateFormat.parse(result.takenAt) ?? .now
        _takenAt = State(initialValue: parsedTakenAt)
        initialTakenAt = parsedTakenAt
        _note = State(initialValue: "")
    }

    private var isLinked: Bool {
        result.isLinked
    }

    private var parsedValue: Double? {
        LocaleDecimalParser.parse(valueText)
    }

    private var trimmedQualitative: String {
        qualitativeText.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        let hasResult = switch resultType {
        case .numeric: parsedValue != nil
        case .qualitative: !trimmedQualitative.isEmpty
        }
        return hasResult && (isLinked || !analyte.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// FORM-1 — any field diverges from the prefilled value. Free-text-only
    /// fields are compared only when the row is unlinked (they're read-only when
    /// linked, so they can never drift).
    private var isDirty: Bool {
        if valueText != initialValueText { return true }
        if qualitativeText != initialQualitative { return true }
        if takenAt != initialTakenAt { return true }
        if note != initialNote { return true }
        if !isLinked {
            if analyte != result.analyte { return true }
            if unit != result.unit { return true }
            if panel != (result.panel ?? "") { return true }
            if referenceLowText != (result.referenceLow.map { $0.formatted() } ?? "") { return true }
            if referenceHighText != (result.referenceHigh.map { $0.formatted() } ?? "") { return true }
        }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLinked {
                    linkedReadOnlySection
                } else {
                    freeTextSection
                }
                valueSection
                noteSection
                if let saveError {
                    Section { HLFormErrorText(saveError) }
                }
            }
            .navigationTitle(Text("labs.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("labs.action.cancel") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("labs.action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .task { await loadNote() }
            // FORM-2 — seed focus onto the primary editable field once settled
            // (value for a linked row, analyte for a free-text one).
            .task {
                // A legacy row whose `takenAt` is already in the future must not
                // violate the picker's range, so the bound never sits below the
                // value it has to contain.
                backdateBound = max(.now, initialTakenAt)
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = if !isLinked {
                    .analyte
                } else if resultType == .qualitative {
                    .qualitative
                } else {
                    .value
                }
            }
        }
        // FORM-1 — guard against a swipe-down discarding unsaved edits.
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    private var linkedReadOnlySection: some View {
        Section {
            LabeledContent("labs.add.analyte", value: result.analyte)
            LabeledContent("labs.add.unit", value: result.unit)
            if let lower = result.referenceLow {
                LabeledContent("labs.add.referenceLow", value: lower.formatted())
            }
            if let upper = result.referenceHigh {
                LabeledContent("labs.add.referenceHigh", value: upper.formatted())
            }
        } header: {
            Text("labs.edit.linked.section")
        } footer: {
            Text("labs.edit.linked.footer")
        }
    }

    private var freeTextSection: some View {
        Section("labs.add.freeText.section") {
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
        }
    }

    /// The value editor. **No numeric/qualitative switch here, deliberately.**
    /// `updateLabResultSchema` (server `src/lib/validations/labs.ts:158-162`)
    /// documents that switching a row's type on `PUT` is not supported — "delete
    /// and re-add" — and an omitted key leaves the existing type. Offering a
    /// toggle would let the operator believe they converted a row while the
    /// server quietly kept the old one. So the row's type is shown, not chosen.
    private var valueSection: some View {
        Section {
            switch resultType {
            case .numeric:
                HStack {
                    TextField("labs.add.value", text: $valueText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .value)
                    if !result.unit.isEmpty {
                        Text(result.unit).foregroundStyle(HLText.secondary)
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
        } header: {
            Text("labs.add.value.section")
        } footer: {
            if resultType == .qualitative {
                Text("labs.edit.qualitative.footer")
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

    /// Pull the decrypted note so an edit preserves it (the list row only flags
    /// `hasNote`; the body lives behind the single-resource GET).
    private func loadNote() async {
        guard !loadedNote, result.hasNote else {
            loadedNote = true
            return
        }
        if let detail = try? await store.fetchDetail(id: result.id) {
            note = detail.note ?? ""
            // FORM-1 — the loaded note is the dirty baseline, not "".
            initialNote = note
        } else {
            // Build 3 / item 3.2 — the detail GET failed, so the field shows ""
            // for a row that DOES have a note. Now that an empty field means
            // "clear it", saving in this state would delete a note the operator
            // never even saw. Latch the failure and send `.unchanged` instead.
            noteLoadFailed = true
        }
        loadedNote = true
    }

    private func save() async {
        // Item 1.5 — send exactly the arm the operator is editing in.
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
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        // Build 3 / item 3.2 — the note is a CLEARABLE field. Emptying it now
        // sends an explicit `null`, which the server reads as "delete the
        // note". Before this it sent nothing at all (`encodeIfPresent` omits
        // the key), the server left the column untouched, and the note the
        // operator had just deleted reappeared on the next sync.
        var patch = LabResultPatch(
            value: numericValue,
            valueText: qualitativeValue,
            takenAt: iso.string(from: takenAt),
            note: noteLoadFailed ? .unchanged : .fromEditor(trimmedNote)
        )
        if !isLinked {
            let trimmedAnalyte = analyte.trimmingCharacters(in: .whitespaces)
            let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
            patch.analyte = trimmedAnalyte.isEmpty ? nil : trimmedAnalyte
            patch.unit = trimmedUnit.isEmpty ? nil : trimmedUnit
            // Panel + both reference bounds are clearable too — same class of
            // bug, same fix. A cleared bound sends `null`, a typo'd bound sends
            // nothing (see `RecordPatchField.fromEditor`) so a slip of the
            // finger can never wipe a stored range.
            patch.panel = .fromEditor(panel)
            patch.referenceLow = .fromEditor(referenceLowText, parse: { LocaleDecimalParser.parse($0) })
            patch.referenceHigh = .fromEditor(referenceHighText, parse: { LocaleDecimalParser.parse($0) })
        }

        if await store.updateLab(id: result.id, patch) {
            dismiss()
        } else {
            saveError = store.lastError ?? String(localized: "labs.save.failed")
        }
    }
}
