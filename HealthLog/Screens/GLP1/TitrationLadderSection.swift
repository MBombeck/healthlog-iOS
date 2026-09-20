import SwiftUI

/// Renders the user's recorded dose-change history plus the label's standard
/// schedule up to the dose they have reached. Embedded as a child section of
/// `MedicationDetailScreen` behind an `isGLP1` gate.
///
/// **1.4.2 boundary (ruling R10):** the "Usual next step: X mg" line — a mg
/// figure computed from the user's own dose — was removed in 1.0.3, together
/// with the forward ladder it introduced. Nothing here projects a dose the
/// user has not recorded; every visible string is journal / informational and
/// defers to the prescribing physician.
public struct TitrationLadderSection: View {
    @State private var store: TitrationLadderStore
    @State private var editorEntry: TitrationLadderEntry?
    @State private var showingAdd: Bool = false

    public init(store: TitrationLadderStore) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            header
            content
        }
        .sheet(isPresented: $showingAdd) {
            TitrationStepEditSheet(
                mode: .add,
                onSave: { effective, doseMg, note in
                    Task { await store.add(effectiveFrom: effective, doseMg: doseMg, note: note) }
                }
            )
            .hlSheetPresentation(.form)
        }
        .sheet(item: $editorEntry) { entry in
            TitrationStepEditSheet(
                mode: .edit(entry),
                onSave: { effective, doseMg, note in
                    Task {
                        await store.update(
                            id: entry.id,
                            effectiveFrom: effective,
                            doseMg: doseMg,
                            note: note
                        )
                    }
                }
            )
            .hlSheetPresentation(.form)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // T2-4: section label Withings rhythm.
            HLSectionLabel("glp1.titration.section.label")
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label(String(localized: "medications.section.active.empty.cta"), systemImage: "plus.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.hlTitle3)
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel(Text(String(localized: "Add titration step")))
        }
    }

    @ViewBuilder
    private var content: some View {
        // Without a recorded dose change there is nothing to anchor the
        // label's schedule to, so the section is the empty state alone — no
        // ladder is drawn from a dose guessed out of the medication's name.
        if store.mergedTimeline.isEmpty {
            emptyState
        } else {
            let catalogSteps = store.catalogTimelineSteps
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if let drugID = store.catalogDrug?.id, !catalogSteps.isEmpty {
                        TitrationCatalogTimelineView(steps: catalogSteps, drugID: drugID)
                        Divider().background(HLColor.separator)
                    }
                    timeline
                }
            }
        }
    }

    private var emptyState: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(
                    String(localized: "No titration history yet"),
                    systemImage: "stairs"
                )
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                Text(String(
                    localized: "Log dose changes to keep a record of the course."
                ))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            let entries = store.mergedTimeline
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TitrationRow(entry: entry) {
                    if entry.source == .local {
                        editorEntry = entry
                    }
                } onDelete: {
                    Task { await store.delete(id: entry.id) }
                }
                if index < entries.count - 1 {
                    Divider().background(HLColor.separator)
                }
            }
        }
    }

    static func formatDose(_ mg: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale.current
        let raw = formatter.string(from: NSNumber(value: mg)) ?? String(format: "%.2f", mg)
        return "\(raw) mg"
    }
}

// MARK: - Row

private struct TitrationRow: View {
    let entry: TitrationLadderEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(spacing: HLSpace.xs) {
                    Text(TitrationLadderSection.formatDose(entry.doseMg))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                    if entry.source == .server {
                        HLBadge(String(localized: "Server"), tone: .neutral)
                    }
                }
                Text(HLDateFormat.date(entry.effectiveFrom, style: .abbreviated))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if entry.source == .local {
                Menu {
                    Button {
                        onEdit()
                    } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(HLText.secondary)
                }
                .accessibilityLabel(Text(String(localized: "Titration step actions")))
            }
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Edit sheet

struct TitrationStepEditSheet: View {
    enum Mode {
        case add
        case edit(TitrationLadderEntry)
    }

    let mode: Mode
    let onSave: (Date, Double, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var effectiveFrom: Date
    @State private var doseString: String
    @State private var note: String

    init(mode: Mode, onSave: @escaping (Date, Double, String?) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add:
            _effectiveFrom = State(initialValue: .now)
            _doseString = State(initialValue: "")
            _note = State(initialValue: "")
        case let .edit(entry):
            _effectiveFrom = State(initialValue: entry.effectiveFrom)
            _doseString = State(initialValue: TitrationStepEditSheet.formatInputDose(entry.doseMg))
            _note = State(initialValue: entry.note ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Effective from")) {
                    DatePicker(
                        String(localized: "glp1.titration.date.label"),
                        selection: $effectiveFrom,
                        displayedComponents: [.date]
                    )
                }
                Section(String(localized: "Dose (mg)")) {
                    TextField(String(localized: "glp1.titration.dose.placeholder"), text: $doseString)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                }
                Section(String(localized: "Note")) {
                    TextField(String(localized: "Optional"), text: $note, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(parsedDose == nil)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .add: String(localized: "Titration step")
        case .edit: String(localized: "Edit step")
        }
    }

    private var parsedDose: Double? {
        guard let value = LocaleDecimalParser.parse(doseString), value > 0 else { return nil }
        return value
    }

    private func save() {
        guard let dose = parsedDose else { return }
        let cleanedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(effectiveFrom, dose, cleanedNote.isEmpty ? nil : cleanedNote)
        dismiss()
    }

    static func formatInputDose(_ mg: Double) -> String {
        // Locale-aware input format — up to 2 fraction digits, trailing zeros
        // trimmed so "5.0" → "5", "7.5" → "7,5" (de) / "7.5" (en), "0.05" →
        // "0,05". The `fractionLength(0...2)` range does the trim natively and
        // the running locale supplies the decimal separator, so the prefilled
        // value round-trips cleanly through `LocaleDecimalParser`. Grouping is
        // disabled — an input field must not carry thousands separators.
        mg.formatted(.number.precision(.fractionLength(0 ... 2)).grouping(.never))
    }
}
