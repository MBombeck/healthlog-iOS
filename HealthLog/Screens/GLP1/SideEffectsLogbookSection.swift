import SwiftUI

/// Renders the side-effects logbook section: a summary chip row, a
/// grouped per-day list, and a log-entry sheet.
///
/// **MDR boundary:** journal-only copy. No "if X then do Y", no severity
/// thresholds that trigger clinical action recommendations. The summary
/// chip is purely a quantitative read-out of what the user has logged.
public struct SideEffectsLogbookSection: View {
    @State private var store: SideEffectsLogbookStore
    @State private var showingAdd: Bool = false

    public init(store: SideEffectsLogbookStore) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            header
            content
        }
        .sheet(isPresented: $showingAdd) {
            SideEffectLogSheet { loggedAt, kind, severity, note in
                Task {
                    await store.log(
                        loggedAt: loggedAt,
                        kind: kind,
                        severity: severity,
                        note: note
                    )
                }
            }
            .hlSheetPresentation(.form)
        }
        .task {
            await store.load()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // T2-4: section label Withings rhythm.
            HLSectionLabel("Side effects")
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label(
                    String(localized: "Add entry"),
                    systemImage: "plus.circle.fill"
                )
                .labelStyle(.iconOnly)
                .font(.hlTitle3)
                .foregroundStyle(.tint)
            }
            .accessibilityLabel(Text(String(localized: "Log side effect")))
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                summaryChips
                logbookList
            }
        }
    }

    private var emptyState: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(
                    String(localized: "No entries yet"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                Text(String(
                    localized: "Erfasse beobachtete Nebenwirkungen, um Verträglichkeit über die Zeit zu dokumentieren."
                ))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    private var logbookList: some View {
        HLCard {
            VStack(spacing: 0) {
                let groups = store.entriesByDay
                ForEach(Array(groups.enumerated()), id: \.element.day) { _, group in
                    DayBlock(day: group.day, rows: group.rows) { id in
                        Task { await store.delete(id: id) }
                    }
                }
            }
        }
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

    static func severityLabel(_ severity: Int) -> String {
        switch severity {
        case 1: String(localized: "Mild")
        case 2: String(localized: "Moderate")
        case 3: String(localized: "Severe")
        default: String(localized: "—")
        }
    }
}

// MARK: - Day block

private struct DayBlock: View {
    let day: Date
    let rows: [SideEffectEntrySnapshot]
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(dayLabel)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .padding(.top, HLSpace.sm)
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                LogRow(row: row, onDelete: { onDelete(row.id) })
                if idx < rows.count - 1 {
                    Divider().background(HLColor.separator)
                }
            }
        }
    }

    private var dayLabel: String {
        // W-PERF-SWR (High) — dropped a per-access `RelativeDateTimeFormatter()`
        // allocation here: it was configured but never used (`dayLabel` returns
        // localized "Today"/"Yesterday" or an absolute `day.formatted(...)`), so
        // the alloc was dead weight on every row access. Output is unchanged.
        if Calendar.current.isDateInToday(day) {
            return String(localized: "Today")
        }
        if Calendar.current.isDateInYesterday(day) {
            return String(localized: "Yesterday")
        }
        return HLDateFormat.date(day, style: .abbreviated)
    }
}

private struct LogRow: View {
    let row: SideEffectEntrySnapshot
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(spacing: HLSpace.xs) {
                    Text(label)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    severityChip
                }
                if let note = row.note, !note.isEmpty {
                    Text(note)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(row.loggedAt.formatted(date: .omitted, time: .shortened))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            Menu {
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(HLText.secondary)
            }
            .accessibilityLabel(Text(String(localized: "Entry actions")))
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        if let kind = row.kind {
            return SideEffectsLogbookSection.kindLabel(kind)
        }
        return String(localized: "Unknown")
    }

    @ViewBuilder
    private var severityChip: some View {
        let tone: HLBadge.Tone = switch row.severity {
        case 3: .critical
        case 2: .warning
        case 1: .info
        default: .neutral
        }
        HLBadge(SideEffectsLogbookSection.severityLabel(row.severity), tone: tone)
    }
}

// MARK: - Log sheet

struct SideEffectLogSheet: View {
    let onSave: (Date, SideEffectKind, Int, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loggedAt: Date = .now
    @State private var kind: SideEffectKind = .nausea
    @State private var severity: Double = 1
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "When")) {
                    DatePicker(
                        String(localized: "Date"),
                        selection: $loggedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section(String(localized: "What")) {
                    Picker(String(localized: "Type"), selection: $kind) {
                        ForEach(SideEffectKind.allCases, id: \.self) { kind in
                            Text(SideEffectsLogbookSection.kindLabel(kind)).tag(kind)
                        }
                    }
                }
                Section(String(localized: "Severity")) {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        Slider(
                            value: $severity,
                            in: 1 ... 3,
                            step: 1
                        )
                        Text(SideEffectsLogbookSection.severityLabel(Int(severity)))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                Section(String(localized: "Note")) {
                    TextField(String(localized: "Optional"), text: $note, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
            }
            .navigationTitle(String(localized: "Log side effect"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(loggedAt, kind, Int(severity), cleaned.isEmpty ? nil : cleaned)
                        dismiss()
                    }
                }
            }
        }
    }
}
