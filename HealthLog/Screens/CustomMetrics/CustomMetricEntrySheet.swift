import SwiftUI

/// Log or edit a value for one custom metric: value, timestamp, note.
///
/// The timestamp is a backdating `DatePicker` bounded `in: ...now`, matching the
/// measurement sheet (Build 1 / item 1.4b) — same bound, same hint footer copy
/// pattern. The server enforces the same ceiling plus a 50-year floor
/// (`ENTRY_MAX_AGE_MS`), so a value the picker allows is a value the server
/// accepts.
///
/// The unit is NOT editable here: the server snapshots the metric's current unit
/// onto the row at write time (historical truth). The sheet shows it read-only
/// so the user knows what they are typing in.
struct CustomMetricEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: CustomMetricsStore
    let metric: CustomMetricDTO
    /// `nil` → log a new value; non-nil → edit that value.
    let existing: CustomMetricEntryDTO?

    @State private var valueText: String
    @State private var measuredAt: Date
    @State private var note: String
    @State private var isSaving = false
    @State private var inlineError: String?
    @State private var showDiscardConfirm = false
    @FocusState private var focusedField: Field?

    /// Future bound for the picker, frozen when the sheet opens so the range
    /// cannot shift under the user mid-edit. Mirrors `MeasureSheetView`.
    private let measuredAtBound: Date

    private enum Field: Hashable {
        case value, note
    }

    init(store: CustomMetricsStore, metric: CustomMetricDTO, existing: CustomMetricEntryDTO? = nil) {
        self.store = store
        self.metric = metric
        self.existing = existing
        let now = Date.now
        measuredAtBound = now
        _valueText = State(initialValue: Self.initialValueText(existing, decimals: metric.decimals))
        _measuredAt = State(initialValue: existing.flatMap { LabsDateFormat.parse($0.measuredAt) } ?? now)
        _note = State(initialValue: existing?.note ?? "")
    }

    /// Seed the value field. An existing entry renders through the metric's own
    /// `decimals` preference so what the user sees in the list is what they see
    /// in the editor — no silent precision change on a round-trip.
    private static func initialValueText(_ entry: CustomMetricEntryDTO?, decimals: Int?) -> String {
        guard let value = entry?.value else { return "" }
        return CustomMetricFormat.number(value, decimals: decimals)
    }

    private var isEditing: Bool {
        existing != nil
    }

    private var parsedValue: Double? {
        LocaleDecimalParser.parse(valueText)
    }

    private var canSave: Bool {
        parsedValue != nil
    }

    private var isDirty: Bool {
        valueText != Self.initialValueText(existing, decimals: metric.decimals)
            || note != (existing?.note ?? "")
            || !Calendar.current.isDate(
                measuredAt,
                equalTo: existing.flatMap { LabsDateFormat.parse($0.measuredAt) } ?? measuredAtBound,
                toGranularity: .minute
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("customMetric.entry.value", text: $valueText)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focusedField, equals: .value)
                            .accessibilityIdentifier("customMetric.entry.value")
                        if !unitForDisplay.isEmpty {
                            Text(verbatim: unitForDisplay)
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                } header: {
                    Text("customMetric.entry.value.section")
                } footer: {
                    if let band = metric.targetBandDescription {
                        Text("customMetric.entry.target.hint \(band)")
                    }
                }

                // Backdating. Bounded to "not in the future", matching the
                // measurement sheet; the footer is the same hint copy pattern,
                // which exists because users kept missing that the field is
                // adjustable at all.
                Section {
                    DatePicker(
                        "customMetric.entry.measuredAt.label",
                        selection: $measuredAt,
                        in: ...measuredAtBound,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("customMetric.entry.measuredAt.picker")
                } header: {
                    Text("customMetric.entry.measuredAt.section")
                } footer: {
                    Text("customMetric.entry.backdateHint")
                }

                Section("customMetric.entry.note.section") {
                    TextField("customMetric.entry.note", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .note)
                }

                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                }
            }
            .navigationTitle(Text(isEditing ? "customMetric.entry.edit.title" : "customMetric.entry.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("customMetric.action.cancel") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("customMetric.action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .value
            }
        }
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    /// Unit to show beside the field. An EXISTING entry shows its own snapshotted
    /// unit (that is what the stored number means); a NEW one shows the metric's
    /// current unit (what the server is about to stamp).
    private var unitForDisplay: String {
        existing?.unit ?? metric.unit
    }

    private func save() async {
        guard let value = parsedValue else { return }
        isSaving = true
        inlineError = nil
        defer { isSaving = false }

        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let resolvedNote: String? = trimmedNote.isEmpty ? nil : trimmedNote
        if trimmedNote.count > CustomMetricValidation.noteMaxLength {
            inlineError = String(localized: "customMetric.validation.noteTooLong")
            return
        }
        let iso = ISO8601DateFormatter.fractional.string(from: measuredAt)

        let ok: Bool = if let existing {
            await store.updateEntry(
                metricID: metric.id,
                entryID: existing.id,
                CustomMetricEntryPatch.fullEdit(value: value, measuredAt: iso, note: resolvedNote)
            )
        } else {
            await store.createEntry(
                metricID: metric.id,
                CustomMetricEntryCreate(value: value, measuredAt: iso, note: resolvedNote)
            )
        }

        if ok {
            dismiss()
        } else {
            inlineError = store.lastError ?? String(localized: "customMetric.save.failed")
        }
    }
}
