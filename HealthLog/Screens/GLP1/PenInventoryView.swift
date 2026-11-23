import SwiftUI

/// Renders the pen-inventory section: active pen card, unopened count,
/// finished-pen history, plus an "add pen" sheet.
///
/// **MDR boundary:** journal-only copy. No predictive "you will run out
/// on X" language — the unopened-count + finished-history are quantitative
/// state read-outs only.
public struct PenInventoryView: View {
    @State private var store: PenInventoryStore
    /// Opens the add sheet. The sheet lives on `GLP1DetailStack`, which stays
    /// on screen when this section swaps between its add row and its full form.
    private let onAdd: () -> Void

    /// Pre-fill seed for the manufacturer field when the catalog
    /// drug is resolved. `nil` when the user is logging a generic.
    public let catalogPrefill: PenInventoryPrefill?

    /// With no pen logged the section is one row in the GLP-1
    /// stack's shared "add" card (``GLP1DetailStack``).
    private let showsAddRowOnly: Bool

    public init(
        store: PenInventoryStore,
        catalogPrefill: PenInventoryPrefill? = nil,
        showsAddRowOnly: Bool = false,
        onAdd: @escaping () -> Void
    ) {
        _store = State(initialValue: store)
        self.onAdd = onAdd
        self.catalogPrefill = catalogPrefill
        self.showsAddRowOnly = showsAddRowOnly
    }

    public var body: some View {
        Group {
            if showsAddRowOnly {
                GLP1AddRow(title: "Add pen", systemImage: "tray", identifier: "glp1.add.pen") { onAdd() }
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
        HLSectionHeader("Pen stock", rank: .area)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            if let active = store.activePen {
                activePenCard(active)
            }
            stockSummary
            penListCard
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
                            .hlText(.footnote)
                        // A server row may carry only one of the two detail
                        // fields; render what exists instead of an empty line.
                        if !pen.manufacturer.isEmpty {
                            Text(pen.manufacturer)
                                .hlText(.objectName)
                        }
                        if !pen.doseStrength.isEmpty {
                            Text(pen.doseStrength)
                                .hlText(.factLabel)
                        }
                    }
                    Spacer()
                }
                if let firstUsed = pen.firstUsedAt {
                    Text(String(
                        format: String(localized: "Started on %@"),
                        HLDateFormat.date(firstUsed, style: .abbreviated)
                    ))
                    .hlText(.footnote)
                }
                HLLinkButton("Mark as used up", systemImage: "checkmark.circle", alignment: .leading) {
                    Task { await store.markFinished(id: pen.id) }
                }
                .accessibilityHint(Text(String(localized: "Marks the active pen as used up.")))
            }
        }
    }

    /// The counts as label and value; "In stock" is what the rows below call
    /// an unopened pen.
    private var stockSummary: some View {
        HLCard {
            HLFactGroup {
                HLFactRow(label: Text("In stock"), value: Text(store.unopenedCount, format: .number))
                HLFactRow(label: Text("Used up"), value: Text(store.finishedPens.count, format: .number))
            }
        }
    }

    /// The further pens, when there are any (no row saying there are none),
    /// and the row that adds one, with the plus in front (Z18).
    private var penListCard: some View {
        let nonActive = store.pens.filter { !$0.isActive }
        return HLCard(layout: .rows) {
            ForEach(nonActive, id: \.id) { pen in
                PenRow(pen: pen) {
                    Task { await store.markFinished(id: pen.id) }
                } delete: {
                    // A pen has no undo, so deleting it asks first.
                    .confirmed(title: "glp1.pen.delete.confirm.title", message: "glp1.pen.delete.confirm.message") {
                        await store.delete(id: pen.id)
                    }
                }
            }
            HLSettingsActionRow(title: "Add pen", presents: .create) { onAdd() }
                .accessibilityIdentifier("glp1.pen.add")
        }
    }

    /// Title and detail line of a pen row. The brand names the pen; without
    /// one the strength takes its place, so the title is never empty.
    static func rowLines(
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        notes: String?
    ) -> (title: String, detail: String?) {
        let received = String(
            format: String(localized: "Received %@"),
            HLDateFormat.date(dispensedAt, style: .abbreviated)
        )
        // The detail is one line; a note's line breaks would cut it short.
        let note = notes?.replacingOccurrences(of: "\n", with: " ")
        if manufacturer.isEmpty {
            return (doseStrength, HLRowDetail.joined([received, note]))
        }
        return (manufacturer, HLRowDetail.joined([doseStrength, received, note]))
    }
}

// MARK: - Row

private struct PenRow: View {
    let pen: PenInventoryEntrySnapshot
    let onMarkFinished: () -> Void
    let delete: () -> HLDeleteAction

    var body: some View {
        let lines = PenInventoryView.rowLines(
            manufacturer: pen.manufacturer,
            doseStrength: pen.doseStrength,
            dispensedAt: pen.dispensedAt,
            notes: pen.notes
        )
        HLRow(title: Text(verbatim: lines.title), detail: lines.detail.map { Text(verbatim: $0) }, status: status)
            .glp1RowActions(
                markUsedUp: (pen.isFinished || pen.isActive) ? nil : onMarkFinished,
                delete: delete()
            )
    }

    private var status: HLRowStatus {
        pen.isFinished
            ? HLRowStatus(String(localized: "Used up"), tone: .neutral)
            : HLRowStatus(String(localized: "In stock"), tone: .info)
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
    /// Saves the pen; `nil` means saved, otherwise the sheet stays open and
    /// shows the failure.
    let onSave: (String, String, Date, Date?, String?) async -> HLError?

    @State private var manufacturer: String
    @State private var doseStrength: String
    @State private var dispensedAt: Date
    @State private var markActiveNow: Bool = false
    @State private var notes: String = ""
    @State private var saveGate = FormSaveGate()
    private let openedAt: Date

    init(prefill: PenInventoryPrefill?, onSave: @escaping (String, String, Date, Date?, String?) async -> HLError?) {
        self.prefill = prefill
        self.onSave = onSave
        let now = Date.now
        openedAt = now
        _dispensedAt = State(initialValue: now)
        _manufacturer = State(initialValue: prefill?.manufacturer ?? "")
        _doseStrength = State(initialValue: prefill?.doseStrength ?? "")
    }

    private var isDirty: Bool {
        manufacturer != (prefill?.manufacturer ?? "")
            || doseStrength != (prefill?.doseStrength ?? "")
            || !Calendar.current.isDate(dispensedAt, inSameDayAs: openedAt)
            || markActiveNow
            || !notes.isEmpty
    }

    var body: some View {
        HLSheetScaffold(
            "Log pen",
            action: .add(isEnabled: isValid) { await save() },
            isDirty: isDirty,
            confirmIdentifier: "glp1.sheet.save"
        ) {
            Form {
                Section {
                    TextField(String(localized: "Manufacturer / brand"), text: $manufacturer)
                    TextField(String(localized: "Dose strength"), text: $doseStrength)
                } header: {
                    HLSectionHeader("med.inventory.container.pen")
                }
                .hlFormRowSurface()
                Section {
                    DatePicker(
                        selection: $dispensedAt,
                        displayedComponents: [.date]
                    ) {
                        HLRowTitle("Date")
                    }
                    Toggle(isOn: $markActiveNow) {
                        HLRowTitle("Get started now")
                    }
                } header: {
                    HLSectionHeader("Procured")
                }
                .hlFormRowSurface()
                Section {
                    TextField(String(localized: "Optional"), text: $notes, axis: .vertical)
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

    private var isValid: Bool {
        !manufacturer.trimmingCharacters(in: .whitespaces).isEmpty
            && !doseStrength.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `true` once the entry went out and the sheet may close.
    private func save() async -> Bool {
        let mfg = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let dose = doseStrength.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstUsedAt: Date? = markActiveNow ? .now : nil
        return await saveGate.submit {
            await onSave(mfg, dose, dispensedAt, firstUsedAt, cleanedNotes.isEmpty ? nil : cleanedNotes)
        }
    }
}
