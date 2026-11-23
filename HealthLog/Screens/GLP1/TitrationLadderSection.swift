import SwiftUI

/// Renders the user's recorded dose-change history plus the label's standard
/// schedule up to the dose they have reached. Embedded as a child section of
/// `MedicationDetailScreen` behind an `isGLP1` gate.
///
/// **App Review 1.4.2 boundary:** nothing here projects a dose the user has
/// not recorded (no "usual next step" mg figure, no forward ladder); every
/// visible string is journal / informational and defers to the prescribing
/// physician.
public struct TitrationLadderSection: View {
    @State private var store: TitrationLadderStore
    @State private var editorEntry: TitrationLadderEntry?
    /// Opens the add sheet. The sheet lives on `GLP1DetailStack`, which stays
    /// on screen when this section swaps between its add row and its full form.
    private let onAdd: () -> Void
    /// The step waiting for the delete confirmation.
    /// With nothing recorded the section is one row in the GLP-1
    /// stack's shared "add" card (``GLP1DetailStack``) instead of a label over
    /// an empty card.
    private let showsAddRowOnly: Bool

    public init(store: TitrationLadderStore, showsAddRowOnly: Bool = false, onAdd: @escaping () -> Void) {
        _store = State(initialValue: store)
        self.onAdd = onAdd
        self.showsAddRowOnly = showsAddRowOnly
    }

    public var body: some View {
        Group {
            if showsAddRowOnly {
                GLP1AddRow(title: "Add titration step", systemImage: "stairs", identifier: "glp1.add.titrationStep") { onAdd() }
            } else {
                // The page's gap, so the header keeps its own room.
                VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                    header
                    content
                }
            }
        }
        .sheet(item: $editorEntry) { entry in
            TitrationStepEditSheet(
                mode: .edit(entry),
                onSave: { effective, doseMg, note in
                    await store.update(
                        id: entry.id,
                        effectiveFrom: effective,
                        doseMg: doseMg,
                        note: note
                    )
                }
            )
        }
        // Each row's delete asks first; the question hangs here, not on the menu.
        .hlDeleteConfirmation()
    }

    private var header: some View {
        HLSectionHeader("glp1.titration.section.label", rank: .area)
    }

    /// Without a recorded dose change there is nothing to anchor the label's
    /// schedule to, and the stack shows the add row instead of this content —
    /// no ladder is drawn from a dose guessed out of the medication's name.
    /// The label's schedule is free content; the recorded steps are rows of
    /// their own card.
    private var content: some View {
        let catalogSteps = store.catalogTimelineSteps
        return VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            if let drugID = store.catalogDrug?.id, !catalogSteps.isEmpty {
                HLCard {
                    TitrationCatalogTimelineView(steps: catalogSteps, drugID: drugID)
                }
            }
            timeline
        }
    }

    private var timeline: some View {
        HLCard(layout: .rows) {
            ForEach(store.mergedTimeline, id: \.id) { entry in
                TitrationRow(entry: entry, isEditable: entry.source == .local || store.canEditServerSteps) {
                    editorEntry = entry
                } delete: {
                    .confirmed(title: "Delete entry?", message: "The history entry will be removed. This action cannot be undone.") {
                        await store.delete(id: entry.id)
                    }
                }
            }
            // Adding is the card's last row with the plus in front, as
            // everywhere something is created (Z18).
            HLSettingsActionRow(title: "Add titration step", presents: .create) { onAdd() }
                .accessibilityIdentifier("glp1.titration.add")
        }
    }

    static func formatDose(_ mg: Double) -> String {
        HLValueFormat.string(mg, unit: .milligrams, fractionDigits: 0 ... 2)
    }
}

// MARK: - Row

/// One recorded step: the date it took effect, the note, the dose as the
/// value. Since #169 a step the server holds is edited and removed like a
/// local one; only without a server seam (previews) is it read-only.
private struct TitrationRow: View {
    let entry: TitrationLadderEntry
    let isEditable: Bool
    let onEdit: () -> Void
    let delete: () -> HLDeleteAction

    var body: some View {
        HLHistoryRow(
            date: Text(verbatim: HLDateFormat.date(entry.effectiveFrom, style: .abbreviated)),
            detail: entry.note.flatMap { note in
                HLRowDetail.text([note.replacingOccurrences(of: "\n", with: " ")])
            },
            value: Text(verbatim: TitrationLadderSection.formatDose(entry.doseMg)),
            status: isEditable ? nil : HLRowStatus(String(localized: "Server"))
        )
        .glp1RowActions(edit: isEditable ? onEdit : nil, delete: isEditable ? delete() : nil)
    }
}

// MARK: - Edit sheet

struct TitrationStepEditSheet: View {
    enum Mode {
        case add
        case edit(TitrationLadderEntry)
    }

    let mode: Mode
    /// Saves the step; `nil` means saved, otherwise the sheet stays open and
    /// shows the failure.
    let onSave: (Date, Double, String?) async -> HLError?

    @State private var effectiveFrom: Date
    @State private var doseString: String
    @State private var note: String
    @State private var saveGate = FormSaveGate()
    private let initialEffectiveFrom: Date
    private let initialDoseString: String
    private let initialNote: String

    init(mode: Mode, onSave: @escaping (Date, Double, String?) async -> HLError?) {
        self.mode = mode
        self.onSave = onSave
        let effective: Date
        let dose: String
        let note: String
        switch mode {
        case .add:
            effective = .now
            dose = ""
            note = ""
        case let .edit(entry):
            effective = entry.effectiveFrom
            dose = TitrationStepEditSheet.formatInputDose(entry.doseMg)
            note = entry.note ?? ""
        }
        initialEffectiveFrom = effective
        initialDoseString = dose
        initialNote = note
        _effectiveFrom = State(initialValue: effective)
        _doseString = State(initialValue: dose)
        _note = State(initialValue: note)
    }

    private var isDirty: Bool {
        !Calendar.current.isDate(effectiveFrom, inSameDayAs: initialEffectiveFrom)
            || doseString != initialDoseString
            || note != initialNote
    }

    var body: some View {
        HLSheetScaffold(
            titleKey,
            action: isAdding ? .add(isEnabled: parsedDose != nil) { await save() } : .save(isEnabled: parsedDose != nil) { await save() },
            isDirty: isDirty,
            confirmIdentifier: "glp1.sheet.save"
        ) {
            Form {
                Section {
                    DatePicker(
                        selection: $effectiveFrom,
                        displayedComponents: [.date]
                    ) {
                        HLRowTitle("glp1.titration.date.label")
                    }
                } header: {
                    HLSectionHeader("Effective from")
                }
                .hlFormRowSurface()
                Section {
                    TextField(String(localized: "glp1.titration.dose.placeholder"), text: $doseString)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("glp1.titration.dose")
                        .monospacedDigit()
                } header: {
                    HLSectionHeader("Dose (mg)")
                }
                .hlFormRowSurface()
                Section {
                    TextField(String(localized: "Optional"), text: $note, axis: .vertical)
                        .lineLimit(3 ... 6)
                } header: {
                    HLSectionHeader("Note")
                }
                .hlFormRowSurface()
                if let error = saveGate.error {
                    Section { HLFormErrorText(error.userFacingDescription) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
        }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    private var titleKey: LocalizedStringKey {
        isAdding ? "Titration step" : "Edit step"
    }

    private var parsedDose: Double? {
        guard let value = LocaleDecimalParser.parse(doseString), value > 0 else { return nil }
        return value
    }

    /// `true` once the entry went out and the sheet may close.
    private func save() async -> Bool {
        guard let dose = parsedDose else { return false }
        let cleanedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return await saveGate.submit {
            await onSave(effectiveFrom, dose, cleanedNote.isEmpty ? nil : cleanedNote)
        }
    }

    static func formatInputDose(_ mg: Double) -> String {
        // Locale-aware input format — up to 2 fraction digits, trailing zeros
        // trimmed so "5.0" → "5", "7.5" → "7,5" (de) / "7.5" (en), "0.05" →
        // "0,05". The `fractionLength(0...2)` range does the trim natively and
        // the running locale supplies the decimal separator, so the prefilled
        // value round-trips cleanly through `LocaleDecimalParser`. Grouping is
        // disabled — an input field must not carry thousands separators.
        HLValueFormat.number(mg, fractionDigits: 0 ... 2, grouping: .never)
    }
}
