import SwiftUI

/// Renders the pen-inventory section: active pen card, unopened count,
/// finished-pen history, plus an "add pen" sheet.
///
/// **MDR boundary:** journal-only copy. No predictive "you will run out
/// on X" language — the unopened-count + finished-history are quantitative
/// state read-outs only.
public struct PenInventoryView: View {
    @State private var store: PenInventoryStore
    @State private var showingAdd: Bool = false

    /// Pre-fill seed for the manufacturer field when the catalog
    /// drug is resolved. `nil` when the user is logging a generic.
    public let catalogPrefill: PenInventoryPrefill?

    public init(store: PenInventoryStore, catalogPrefill: PenInventoryPrefill? = nil) {
        _store = State(initialValue: store)
        self.catalogPrefill = catalogPrefill
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            header
            content
        }
        .sheet(isPresented: $showingAdd) {
            PenInventoryEditSheet(prefill: catalogPrefill) { manufacturer, dose, dispensedAt, firstUsedAt, notes in
                Task {
                    await store.add(
                        manufacturer: manufacturer,
                        doseStrength: dose,
                        dispensedAt: dispensedAt,
                        firstUsedAt: firstUsedAt,
                        notes: notes
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
            HLSectionLabel("Pen stock")
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label(
                    String(localized: "Add pen"),
                    systemImage: "plus.circle.fill"
                )
                .labelStyle(.iconOnly)
                .font(.hlTitle3)
                .foregroundStyle(.tint)
            }
            .accessibilityLabel(Text(String(localized: "Add pen")))
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.pens.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if let active = store.activePen {
                    activePenCard(active)
                }
                stockSummary
                penListCard
            }
        }
    }

    private var emptyState: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(
                    String(localized: "No pen logged yet"),
                    systemImage: "tray"
                )
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                Text(String(
                    localized: "Erfasse Pens, um Vorrat + Rezepte besser planen zu können."
                ))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // #52 — the "Hersteller + Dosisstärke werden lokal gespeichert"
                // footnote is GONE: since server v1.31.0 the inventory row carries
                // both fields, so nothing about a pen is device-local any more.
                // The caveat existed only because the back-fill was missing.
            }
        }
    }

    private func activePenCard(_ pen: PenInventoryEntrySnapshot) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "syringe.fill")
                        .font(.hlIcon(HLIconSize.lg))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(String(localized: "Currently in use"))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                        // #52 — a server row may carry only one of the two detail
                        // fields; render what exists instead of an empty line.
                        if !pen.manufacturer.isEmpty {
                            Text(pen.manufacturer)
                                .font(.hlHeadline)
                                .foregroundStyle(HLText.primary)
                        }
                        if !pen.doseStrength.isEmpty {
                            Text(pen.doseStrength)
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                    Spacer()
                }
                if let firstUsed = pen.firstUsedAt {
                    Text(String(
                        format: String(localized: "Started on %@"),
                        HLDateFormat.date(firstUsed, style: .abbreviated)
                    ))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                }
                Button {
                    Task { await store.markFinished(id: pen.id) }
                } label: {
                    Label(
                        String(localized: "Mark as used up"),
                        systemImage: "checkmark.circle"
                    )
                    .font(.hlSubhead)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(String(localized: "Marks the active pen as used up.")))
            }
        }
    }

    private var stockSummary: some View {
        HStack(spacing: HLSpace.md) {
            HLBadge(
                String(format: String(localized: "%d unread"), store.unopenedCount),
                icon: "tray.full",
                tone: store.unopenedCount == 0 ? .warning : .neutral
            )
            HLBadge(
                String(format: String(localized: "%d used up"), store.finishedPens.count),
                icon: "tray.full.fill",
                tone: .neutral
            )
            Spacer()
        }
    }

    private var penListCard: some View {
        HLCard {
            VStack(spacing: 0) {
                let nonActive = store.pens.filter { !$0.isActive }
                if nonActive.isEmpty {
                    Text(String(localized: "No further pens logged."))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                } else {
                    ForEach(Array(nonActive.enumerated()), id: \.element.id) { idx, pen in
                        PenRow(pen: pen) {
                            Task { await store.markFinished(id: pen.id) }
                        } onDelete: {
                            Task { await store.delete(id: pen.id) }
                        }
                        if idx < nonActive.count - 1 {
                            Divider().background(HLColor.separator)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct PenRow: View {
    let pen: PenInventoryEntrySnapshot
    let onMarkFinished: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(spacing: HLSpace.xs) {
                    if !pen.manufacturer.isEmpty {
                        Text(pen.manufacturer)
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                    }
                    statusBadge
                }
                if !pen.doseStrength.isEmpty {
                    Text(pen.doseStrength)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
                Text(String(
                    format: String(localized: "Received %@"),
                    HLDateFormat.date(pen.dispensedAt, style: .abbreviated)
                ))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                if let notes = pen.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Menu {
                if !pen.isFinished, !pen.isActive {
                    Button {
                        onMarkFinished()
                    } label: {
                        Label(
                            String(localized: "Mark as used up"),
                            systemImage: "checkmark.circle"
                        )
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(HLText.secondary)
            }
            .accessibilityLabel(Text(String(localized: "Pen actions")))
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if pen.isFinished {
            HLBadge(String(localized: "Used up"), tone: .neutral)
        } else {
            HLBadge(String(localized: "In stock"), tone: .info)
        }
    }
}

// MARK: - Prefill payload

/// Pre-fill values fed into `PenInventoryEditSheet` from the resolved
/// catalog drug.
public struct PenInventoryPrefill: Sendable {
    public let manufacturer: String?
    public let doseStrength: String?

    public init(manufacturer: String?, doseStrength: String?) {
        self.manufacturer = manufacturer
        self.doseStrength = doseStrength
    }
}

// MARK: - Edit sheet

struct PenInventoryEditSheet: View {
    let prefill: PenInventoryPrefill?
    let onSave: (String, String, Date, Date?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manufacturer: String
    @State private var doseStrength: String
    @State private var dispensedAt: Date = .now
    @State private var markActiveNow: Bool = false
    @State private var notes: String = ""

    init(prefill: PenInventoryPrefill?, onSave: @escaping (String, String, Date, Date?, String?) -> Void) {
        self.prefill = prefill
        self.onSave = onSave
        _manufacturer = State(initialValue: prefill?.manufacturer ?? "")
        _doseStrength = State(initialValue: prefill?.doseStrength ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "med.inventory.container.pen")) {
                    TextField(String(localized: "Manufacturer / brand"), text: $manufacturer)
                    TextField(String(localized: "Dose strength"), text: $doseStrength)
                }
                Section(String(localized: "Procured")) {
                    DatePicker(
                        String(localized: "Date"),
                        selection: $dispensedAt,
                        displayedComponents: [.date]
                    )
                    Toggle(String(localized: "Get started now"), isOn: $markActiveNow)
                }
                Section(String(localized: "Note")) {
                    TextField(String(localized: "Optional"), text: $notes, axis: .vertical)
                        .lineLimit(3 ... 6)
                }
            }
            .navigationTitle(String(localized: "Log pen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !manufacturer.trimmingCharacters(in: .whitespaces).isEmpty
            && !doseStrength.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let mfg = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let dose = doseStrength.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(
            mfg,
            dose,
            dispensedAt,
            markActiveNow ? .now : nil,
            cleanedNotes.isEmpty ? nil : cleanedNotes
        )
        dismiss()
    }
}
