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
    let store: CustomMetricsStore
    let metric: CustomMetricDTO
    /// `nil` → log a new value; non-nil → edit that value.
    let existing: CustomMetricEntryDTO?

    @State private var valueText: String
    @State private var measuredAt: Date
    @State private var note: String
    @State private var isSaving = false
    @State private var inlineError: String?
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
        HLSheetScaffold(
            isEditing ? "customMetric.entry.edit.title" : "customMetric.entry.add.title",
            action: isEditing ? .save(isEnabled: canSave) { await save() } : .add(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Section {
                    HStack {
                        TextField("customMetric.entry.value", text: $valueText)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focusedField, equals: .value)
                            .accessibilityIdentifier("customMetric.entry.value")
                        if !unitForDisplay.isEmpty {
                            Text(verbatim: unitForDisplay)
                                .hlText(.factLabel)
                        }
                    }
                } header: {
                    HLSectionHeader("customMetric.entry.value.section")
                } footer: {
                    if let band = metric.targetBandDescription {
                        Text("customMetric.entry.target.hint \(band)")
                    }
                }
                .hlFormRowSurface()

                // Backdating. Bounded to "not in the future", matching the
                // measurement sheet. The picker shows it can be
                // changed and refuses the future itself; no hint footer.
                Section {
                    DatePicker(
                        selection: $measuredAt,
                        in: ...measuredAtBound,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        HLRowTitle("customMetric.entry.measuredAt.label")
                    }
                    .accessibilityIdentifier("customMetric.entry.measuredAt.picker")
                } header: {
                    HLSectionHeader("customMetric.entry.measuredAt.section")
                }
                .hlFormRowSurface()

                Section {
                    TextField("customMetric.entry.note", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .note)
                } header: {
                    HLSectionHeader("customMetric.entry.note.section")
                }
                .hlFormRowSurface()

                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .value
            }
        }
    }

    /// Unit to show beside the field. An EXISTING entry shows its own snapshotted
    /// unit (that is what the stored number means); a NEW one shows the metric's
    /// current unit (what the server is about to stamp).
    private var unitForDisplay: String {
        existing?.unit ?? metric.unit
    }

    private func save() async -> Bool {
        guard let value = parsedValue else { return false }
        isSaving = true
        inlineError = nil
        defer { isSaving = false }

        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let resolvedNote: String? = trimmedNote.isEmpty ? nil : trimmedNote
        if trimmedNote.count > CustomMetricValidation.noteMaxLength {
            inlineError = String(localized: "customMetric.validation.noteTooLong")
            return false
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
            return true
        } else {
            inlineError = store.lastError ?? String(localized: "customMetric.save.failed")
        }
        return false
    }
}
