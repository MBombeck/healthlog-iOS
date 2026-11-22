import SwiftUI

/// Renders the side-effects logbook section: a summary chip row, a
/// grouped per-day list, and a log-entry sheet.
///
/// **MDR boundary:** journal-only copy. No "if X then do Y", no severity
/// thresholds that trigger clinical action recommendations. The summary
/// chip is purely a quantitative read-out of what the user has logged.
public struct SideEffectsLogbookSection: View {
    @State private var store: SideEffectsLogbookStore
    /// Opens the add sheet. The sheet lives on `GLP1DetailStack`, which stays
    /// on screen when this section swaps between its add row and its full form.
    private let onAdd: () -> Void
    /// The entry waiting for the delete confirmation.
    /// With nothing logged the section is one row in the GLP-1
    /// stack's shared "add" card (``GLP1DetailStack``).
    private let showsAddRowOnly: Bool

    public init(store: SideEffectsLogbookStore, showsAddRowOnly: Bool = false, onAdd: @escaping () -> Void) {
        _store = State(initialValue: store)
        self.onAdd = onAdd
        self.showsAddRowOnly = showsAddRowOnly
    }

    public var body: some View {
        Group {
            if showsAddRowOnly {
                GLP1AddRow(title: "Log side effect", systemImage: "list.bullet.rectangle", identifier: "glp1.add.sideEffect") { onAdd() }
            } else {
                // The page's gap, so the header keeps its own room.
                VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                    header
                    content
                }
            }
        }
        // Each row's delete asks first; the question hangs here, not on the menu.
        .hlDeleteConfirmation()
    }

    private var header: some View {
        HLSectionHeader("Side effects", rank: .area)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            summaryChips
            // Logging comes first in the logbook, as a row with the plus in
            // front (Z18); the days follow.
            HLCard(layout: .rows) {
                HLSettingsActionRow(title: "Log side effect", presents: .create) { onAdd() }
                    .accessibilityIdentifier("glp1.sideEffect.add")
            }
            logbookList
        }
        // The day headers keep their room above and below in this stack.
        .hlContainerGap(HLSpace.md)
    }

    private var summaryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.sm) {
                ForEach(store.summaryByKind, id: \.kind) { row in
                    HLBadge(
                        String(
                            format: String(localized: "%@ · %dx"),
                            SideEffectsLogbookSection.kindLabel(row.kind),
                            row.count
                        ),
                        tone: SideEffectsLogbookSection.severityTone(weight: row.weight, count: row.count)
                    )
                }
            }
            .padding(.horizontal, HLSpace.hair)
        }
    }

    /// One header per day and the day's entries as rows of one card.
    private var logbookList: some View {
        ForEach(store.entriesByDay, id: \.day) { group in
            HLSectionHeader(verbatim: Self.dayLabel(group.day))
            HLCard(layout: .rows) {
                ForEach(group.rows, id: \.id) { row in
                    LogRow(row: row, delete: deleteAction(id: row.id))
                }
            }
        }
    }

    private func deleteAction(id: String) -> HLDeleteAction {
        .confirmed(title: "Delete entry?", message: "The history entry will be removed. This action cannot be undone.") {
            await store.delete(id: id)
        }
    }

    static func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) {
            return String(localized: "Today")
        }
        if Calendar.current.isDateInYesterday(day) {
            return String(localized: "Yesterday")
        }
        return HLDateFormat.date(day, style: .abbreviated)
    }

    static func kindLabel(_ kind: SideEffectKind) -> String {
        switch kind {
        case .nausea: String(localized: "Nausea")
        case .vomiting: String(localized: "Vomiting")
        case .constipation: String(localized: "Constipation")
        case .diarrhea: String(localized: "Diarrhea")
        case .fatigue: String(localized: "Fatigue")
        case .appetiteLoss: String(localized: "Appetite loss")
        case .injectionSiteReaction: String(localized: "Reaction at injection site")
        case .headache: String(localized: "Headache")
        case .unknown: String(localized: "glp1.sideEffect.kind.unknown")
        }
    }

    /// Tone for the summary chip. Quantitative-only ("more rows / higher
    /// weighted severity = redder"), no clinical interpretation.
    static func severityTone(weight: Int, count: Int) -> HLBadge.Tone {
        // weight is sum of severity-bucket (≥1 per row). Average ≥ 2.0
        // skews to warning, ≥ 2.5 to critical, else neutral.
        guard count > 0 else { return .neutral }
        let average = Double(weight) / Double(count)
        if average >= 2.5 { return .critical }
        if average >= 2.0 { return .warning }
        return .neutral
    }

    /// The severity as the row's status; an unknown grade shows none.
    static func severityStatus(_ severity: Int) -> HLRowStatus? {
        let tone: HLBadge.Tone
        switch severity {
        case 3: tone = .critical
        case 2: tone = .warning
        case 1: tone = .info
        default: return nil
        }
        return HLRowStatus(severityLabel(severity), tone: tone)
    }

    static func severityLabel(_ severity: Int) -> String {
        switch severity {
        case 1: String(localized: "Mild")
        case 2: String(localized: "Moderate")
        case 3: String(localized: "Severe")
        default: String(localized: "—")
        }
    }
}

// MARK: - Row

private struct LogRow: View {
    let row: SideEffectEntrySnapshot
    let delete: HLDeleteAction

    var body: some View {
        HLRow(
            title: Text(verbatim: label),
            detail: HLRowDetail.text([
                HLTimeFormat.time(row.loggedAt),
                row.note?.replacingOccurrences(of: "\n", with: " ")
            ]),
            status: SideEffectsLogbookSection.severityStatus(row.severity)
        )
        .glp1RowActions(delete: delete)
    }

    private var label: String {
        if let kind = row.kind {
            return SideEffectsLogbookSection.kindLabel(kind)
        }
        return String(localized: "Unknown")
    }
}

// MARK: - Log sheet

struct SideEffectLogSheet: View {
    /// Saves the entry; `nil` means saved, otherwise the sheet stays open and
    /// shows the failure.
    let onSave: (Date, SideEffectKind, Int, String?) async -> HLError?

    @State private var loggedAt: Date
    @State private var kind: SideEffectKind = .nausea
    @State private var severity: Double = 1
    @State private var note: String = ""
    @State private var saveGate = FormSaveGate()
    private let openedAt: Date

    init(onSave: @escaping (Date, SideEffectKind, Int, String?) async -> HLError?) {
        self.onSave = onSave
        let now = Date.now
        openedAt = now
        _loggedAt = State(initialValue: now)
    }

    private var isDirty: Bool {
        !Calendar.current.isDate(loggedAt, equalTo: openedAt, toGranularity: .minute)
            || kind != .nausea
            || Int(severity) != 1
            || !note.isEmpty
    }

    var body: some View {
        HLSheetScaffold(
            "glp1.sideEffect.sheet.title",
            action: .add { await save() },
            isDirty: isDirty,
            confirmIdentifier: "glp1.sheet.save"
        ) {
            Form {
                Section {
                    DatePicker(
                        selection: $loggedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        HLRowTitle("Date")
                    }
                } header: {
                    HLSectionHeader("When")
                }
                .hlFormRowSurface()
                Section {
                    Picker(selection: $kind) {
                        ForEach(SideEffectKind.pickerCases, id: \.self) { kind in
                            Text(SideEffectsLogbookSection.kindLabel(kind)).tag(kind)
                        }
                    } label: {
                        HLRowTitle("Type")
                    }
                } header: {
                    HLSectionHeader("What")
                }
                .hlFormRowSurface()
                Section {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        Slider(
                            value: $severity,
                            in: 1 ... 3,
                            step: 1
                        )
                        Text(SideEffectsLogbookSection.severityLabel(Int(severity)))
                            .hlText(.rowSubtitle)
                    }
                } header: {
                    HLSectionHeader("Severity")
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
            // Its own key: between "Abbrechen" and "Speichern" the
            // German "Nebenwirkung erfassen" was cut.
        }
    }

    /// `true` once the entry went out and the sheet may close.
    private func save() async -> Bool {
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return await saveGate.submit {
            await onSave(loggedAt, kind, Int(severity), cleaned.isEmpty ? nil : cleaned)
        }
    }
}
