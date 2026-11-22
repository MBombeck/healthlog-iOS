import SwiftUI

/// Edit an existing lab result. When the row is linked to a catalog biomarker
/// (`biomarkerId != nil`) the analyte / unit / reference range are
/// server-resolved and shown READ-ONLY (editing them would drift from the
/// catalog); only value / date / note are editable. A free-text row keeps all
/// fields editable.
struct EditLabResultSheet: View {
    let store: LabsStore
    let result: LabResultDTO

    @State private var analyte: String
    @State private var unit: String
    /// "No unit" on a free-text row (the unity `"1"`). ``unit``
    /// keeps what was typed for the way back.
    @State private var noUnit: Bool
    /// Whether the "No unit" switch is offered (server 1.46.6, or a row that
    /// already has no unit).
    private let offersNoUnit: Bool
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
    @State private var saveError: String?
    /// Drives the discard-confirmation dialog.
    /// The note loads async; capture its loaded value so a note edit is
    /// detectable and an untouched note never reads as dirty.
    @State private var initialNote = ""
    /// Initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    private let initialTakenAt: Date
    /// The prefilled numeric text — the dirty check compares against THIS rather
    /// than re-deriving it, so a qualitative row (no number) has a stable "".
    private let initialValueText: String
    private let initialQualitative: String

    /// The row's result type is a FACT about the row, not a choice
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
        let storedWithoutUnit = LabUnit.isUnity(result.unit)
        _unit = State(initialValue: storedWithoutUnit ? "" : result.unit)
        _noUnit = State(initialValue: storedWithoutUnit)
        offersNoUnit = LabUnit.offersNoUnit(current: result.unit)
        // An absent / qualitative row prefills an EMPTY numeric field
        // instead of the old fabricated "0".
        let seededValueText = Self.editableValueText(result.value)
        _valueText = State(initialValue: seededValueText)
        initialValueText = seededValueText
        let seededQualitative = result.valueText ?? ""
        _qualitativeText = State(initialValue: seededQualitative)
        initialQualitative = seededQualitative
        _referenceLowText = State(initialValue: result.referenceLow.map { $0.formatted() } ?? "")
        _referenceHighText = State(initialValue: result.referenceHigh.map { $0.formatted() } ?? "")
        // The stored panel can be a key ("coagulation"); the field shows its label.
        _panel = State(initialValue: LabPanelName.display(result.panel) ?? "")
        let parsedTakenAt = LabsDateFormat.readingDate(result.takenAt) ?? .now
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

    /// Any field diverges from the prefilled value. Free-text-only
    /// fields are compared only when the row is unlinked (they're read-only when
    /// linked, so they can never drift).
    private var isDirty: Bool {
        if valueText != initialValueText { return true }
        if qualitativeText != initialQualitative { return true }
        if takenAt != initialTakenAt { return true }
        if note != initialNote { return true }
        if !isLinked {
            if analyte != result.analyte { return true }
            if (LabUnit.wire(typed: unit, noUnit: noUnit) ?? "") != result.unit { return true }
            if panel != (LabPanelName.display(result.panel) ?? "") { return true }
            if referenceLowText != (result.referenceLow.map { $0.formatted() } ?? "") { return true }
            if referenceHighText != (result.referenceHigh.map { $0.formatted() } ?? "") { return true }
        }
        return false
    }

    var body: some View {
        HLSheetScaffold(
            "labs.edit.title",
            action: .save(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Group {
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
                .hlFormRowSurface()
            }
            .hlPageMargins()
            .task { await loadNote() }
            // Seed focus onto the primary editable field once settled
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
    }

    private var linkedReadOnlySection: some View {
        Section {
            LabeledContent {
                Text(verbatim: result.analyte)
            } label: {
                HLRowTitle("labs.add.analyte")
            }
            LabeledContent {
                Text(verbatim: LabUnit.standalone(result.unit) ?? "")
            } label: {
                HLRowTitle("labs.add.unit")
            }
            if let lower = result.referenceLow {
                LabeledContent {
                    Text(verbatim: lower.formatted())
                } label: {
                    HLRowTitle("labs.add.referenceLow")
                }
            }
            if let upper = result.referenceHigh {
                LabeledContent {
                    Text(verbatim: upper.formatted())
                } label: {
                    HLRowTitle("labs.add.referenceHigh")
                }
            }
        } header: {
            // The header says these rows belong to the linked
            // marker; the footer that said they can't be edited is gone.
            Text("labs.edit.linked.section")
        }
    }

    /// Label above each field, like the marker editor.
    private var freeTextSection: some View {
        Section("labs.add.freeText.section") {
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
                    if let shown = LabUnit.suffix(result.unit) {
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
        } header: {
            // No standing footer about a switch nobody tried.
            Text("labs.add.value.section")
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
            // The loaded note is the dirty baseline, not "".
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

    /// The stored value as the field shows it: every digit the server holds,
    /// so a 0,0042 stays 0,0042 instead of reading as 0.
    nonisolated static func editableValueText(_ value: Double?, locale: Locale = .current) -> String {
        guard let value else { return "" }
        // An edit field needs every significant digit the server holds; the
        // display helpers round to a fixed number of fraction digits.
        // swiftlint:disable:next hl_number_via_helper
        return value.formatted(.number.precision(.significantDigits(1 ... 15)).grouping(.never).locale(locale))
    }

    /// The value the save sends: only one the person changed. An untouched
    /// field leaves the stored number alone, so editing the note or the date
    /// can never rewrite the result.
    nonisolated static func valueToSend(valueText: String, initialValueText: String, locale: Locale = .current) -> Double? {
        guard valueText != initialValueText else { return nil }
        return LocaleDecimalParser.parse(valueText, locale: locale)
    }

    /// Returns `true` when the sheet may close.
    private func save() async -> Bool {
        // Send exactly the arm the operator is editing in.
        let numericValue: Double?
        let qualitativeValue: String?
        switch resultType {
        case .numeric:
            guard parsedValue != nil else { return false }
            numericValue = Self.valueToSend(valueText: valueText, initialValueText: initialValueText)
            qualitativeValue = nil
        case .qualitative:
            guard !trimmedQualitative.isEmpty else { return false }
            numericValue = nil
            qualitativeValue = trimmedQualitative
        }
        saveError = nil

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
            // An untouched date keeps the stored value: a date-only reading
            // (noon or midnight UTC) stays date-only instead of becoming local noon.
            takenAt: takenAt == initialTakenAt ? result.takenAt : iso.string(from: takenAt),
            note: noteLoadFailed ? .unchanged : .fromEditor(trimmedNote)
        )
        if !isLinked {
            let trimmedAnalyte = analyte.trimmingCharacters(in: .whitespaces)
            patch.analyte = trimmedAnalyte.isEmpty ? nil : trimmedAnalyte
            patch.unit = LabUnit.wire(typed: unit, noUnit: noUnit)
            // Panel + both reference bounds are clearable too — same class of
            // bug, same fix. A cleared bound sends `null`, a typo'd bound sends
            // nothing (see `RecordPatchField.fromEditor`) so a slip of the
            // finger can never wipe a stored range.
            patch.panel = .fromEditor(LabPanelName.toSave(typed: panel, stored: result.panel))
            patch.referenceLow = .fromEditor(referenceLowText, parse: { LocaleDecimalParser.parse($0) })
            patch.referenceHigh = .fromEditor(referenceHighText, parse: { LocaleDecimalParser.parse($0) })
        }

        if await store.updateLab(id: result.id, patch) {
            return true
        }
        saveError = store.lastError ?? String(localized: "labs.save.failed")
        return false
    }
}
