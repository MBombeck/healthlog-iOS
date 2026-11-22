import SwiftUI

// Server-ledger Verlauf.
//
// Renders the medication-detail history from the server's unified
// dose-history ledger (`GET …/dose-history`) instead of the raw intake
// pages: every expected slot with its server-graded status (on-time /
// late / skipped / missed / upcoming) plus off-schedule takes tagged
// ad-hoc. The ledger is the SAME read-model the compliance % consumes
// and it is era-aware (v1.16.3), so this list, the KPI tile and the web
// Verlauf can never contradict each other — including after a schedule
// edit, which a client-side projection from the current schedule cannot
// get right.
//
// Mounted by `MedicationDetailScreen` only when the ledger loaded; the
// legacy `IntakeHistorySection` stays as the verbatim fallback for
// ≤ v1.15.17 servers. Filter + collapse affordances
// mirror the legacy section so the swap is invisible in muscle memory.

/// Filter mirroring `VerlaufFilter` on the legacy section.
private enum LedgerFilter: Hashable {
    case alle
    case nichtGenommen
}

struct LedgerHistorySection: View {
    let rows: [MedicationDoseHistoryRow]
    /// The medication's configured dose, used to decide whether a
    /// row's recorded `doseTaken` is a deviation worth surfacing as a quiet
    /// badge. Empty / nil = no configured dose to compare against.
    var scheduledDose: String = ""
    /// "Now" reference for the retro-mark gate (b162 dose-safety: future /
    /// upcoming rows are never markable as taken). Injectable for previews.
    var now: Date = .now
    /// Injection-site lookup by intake-event id — the ledger rows don't
    /// carry the site, the already-loaded intake pages do.
    let siteFor: (String) -> String?
    let onMarkTaken: (MedicationDoseHistoryRow) -> Void
    let onMarkSkipped: (MedicationDoseHistoryRow) -> Void
    let onDelete: (MedicationDoseHistoryRow) -> Void
    /// "Diesem Slot zuordnen" — pin an ad-hoc take onto its nearest
    /// unserved slot (`forceSlotInstant`).
    let onPin: (MedicationDoseHistoryRow) -> Void
    /// "Zuordnung lösen" — release a user pin (`forceSlotInstant: null`).
    let onUnpin: (MedicationDoseHistoryRow) -> Void

    @State private var filter: LedgerFilter = .alle
    /// On the detail page the history shows its newest entries and a row
    /// to the full list; the full list is its own page with the filter.
    var mode: Mode = .preview

    enum Mode {
        case preview
        case full
    }

    /// Entries the detail page shows before the row to the full list.
    static let previewCount = 5

    /// The newest entries the detail page shows inline.
    nonisolated static func previewRows(_ rows: [MedicationDoseHistoryRow]) -> [MedicationDoseHistoryRow] {
        Array(rows.sorted { $0.at > $1.at }.prefix(previewCount))
    }

    /// Whether the detail page shows the row to the full list: whenever there
    /// is a history at all, like every detail page's history (Z16 §8).
    nonisolated static func showsFullListRow(_ rows: [MedicationDoseHistoryRow]) -> Bool {
        !rows.isEmpty
    }

    private var visibleRows: [MedicationDoseHistoryRow] {
        let sorted = rows.sorted { $0.at > $1.at }
        switch mode {
        case .preview:
            return Self.previewRows(rows)
        case .full:
            switch filter {
            case .alle:
                return sorted
            case .nichtGenommen:
                // Server-graded equivalents of the legacy "Nicht genommen"
                // read: deliberate skips + true misses. Upcoming rows are
                // dropped (they have not had a chance yet).
                return sorted.filter { $0.status == .missed || $0.status == .skipped }
            }
        }
    }

    var body: some View {
        let shown = visibleRows
        Group {
            HLSectionHeader("History", rank: .area)
            if shown.isEmpty {
                HLCard { HLEmptyNote(Text(emptyLabel)) }
            } else {
                HLCard(layout: .rows) {
                    ForEach(shown) { row in
                        LedgerHistoryRow(
                            row: row,
                            scheduledDose: scheduledDose,
                            now: now,
                            site: row.intake?.id.flatMap(siteFor),
                            onMarkTaken: { onMarkTaken(row) },
                            onMarkSkipped: { onMarkSkipped(row) },
                            onDelete: { onDelete(row) },
                            onPin: { onPin(row) },
                            onUnpin: { onUnpin(row) }
                        )
                    }
                    if mode == .preview, Self.showsFullListRow(rows) {
                        HLDrillRow("med.history.show_all", count: rows.count)
                            .hlRowLink { fullPage }
                            .accessibilityIdentifier("med.history.showAll")
                    }
                }
            }
        }
        // The filter belongs to the full list's bar, not to its content.
        .hlPageActions(mode == .full ? HLTabHeaderActions([filterAction]) : .none)
    }

    /// The whole history on a page of its own, with the filter.
    private var fullPage: some View {
        var full = self
        full.mode = .full
        return HLPage { full }
            .navigationTitle(Text("History"))
            .navigationBarTitleDisplayMode(.inline)
            .hlDeleteConfirmation()
    }

    private var filterAction: HLTabHeaderAction {
        .filter(label: "Filter history", isSelected: filter != .alle) {
            Picker(
                selection: $filter,
                label: Text(String(localized: "Filter history"))
            ) {
                Text(String(localized: "All")).tag(LedgerFilter.alle)
                Text(String(localized: "Not taken")).tag(LedgerFilter.nichtGenommen)
            }
        }
    }

    private var emptyLabel: String {
        switch filter {
        case .alle:
            String(localized: "No intakes logged yet.")
        case .nichtGenommen:
            String(localized: "No missed intakes in your history.")
        }
    }
}

/// One ledger row: timestamp + context caption + server-graded status
/// glyph + the trailing action menu. Mirrors `IntakeHistoryRow`'s layout
/// so the ledger swap reads as the same primitive.
struct LedgerHistoryRow: View {
    let row: MedicationDoseHistoryRow
    /// The medication's configured dose for the deviation comparison.
    var scheduledDose: String = ""
    var now: Date = .now
    /// Injection-site raw value resolved by the parent (ledger rows don't
    /// carry it).
    var site: String?
    let onMarkTaken: () -> Void
    let onMarkSkipped: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void

    /// One ledger entry as a history row (Z22): date and time as the title,
    /// the side facts (context, site, source, pin) joined on one detail line,
    /// the dose taken on the right with the server's grade as its status
    /// text. The actions live in the row's context menu (Z18, Z21).
    var body: some View {
        Group {
            if let dose = Self.shownDose(row: row, scheduledDose: scheduledDose) {
                HLHistoryRow(date: Text(timestamp), detail: detail, value: Text(verbatim: dose), status: status)
            } else {
                HLRow(title: Text(timestamp), detail: detail, status: status)
            }
        }
        .modifier(LedgerActionsMenu(isEnabled: hasAnyAction) { actionMenuItems })
    }

    private var detail: Text? {
        HLRowDetail.text([
            contextCaption,
            site.map(siteLabel),
            row.provenance.map { String(localized: $0.labelResource) },
            row.pinned == true && !row.isAdHoc ? String(localized: "med.ledger.pinned_badge") : nil
        ])
    }

    /// The dose a taken row reports: the one recorded for this take, else the
    /// medication's configured dose. A skip, a miss or a planned slot took
    /// nothing and shows no dose.
    nonisolated static func shownDose(row: MedicationDoseHistoryRow, scheduledDose: String) -> String? {
        switch row.status {
        case .takenOnTime, .takenLate, .adHoc:
            let recorded = row.intake?.doseTaken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let configured = scheduledDose.trimmingCharacters(in: .whitespacesAndNewlines)
            let dose = recorded.isEmpty ? configured : recorded
            return dose.isEmpty ? nil : dose
        default:
            return nil
        }
    }

    /// The server's grade as text under the value. Only what asks for a
    /// look carries a colour: a late take, a missed dose.
    /// Words follow the term list (#191): Genommen, Verspätet genommen,
    /// Übersprungen, Verpasst, Ausstehend.
    nonisolated static func statusLine(_ status: MedicationDoseHistoryStatus?) -> HLRowStatus? {
        switch status {
        case .takenOnTime: HLRowStatus(MedicationDosePhase.taken.title)
        case .adHoc: HLRowStatus(String(localized: "med.ledger.status.adhoc"))
        case .takenLate: HLRowStatus(MedicationDosePhase.takenLate.title, tone: .warning)
        case .skipped: HLRowStatus(MedicationDosePhase.skipped.title)
        case .missed: HLRowStatus(MedicationDosePhase.missed.title, tone: .critical)
        case .upcoming: HLRowStatus(MedicationDosePhase.pending.title)
        case nil: nil
        }
    }

    private var status: HLRowStatus? {
        Self.statusLine(row: row)
    }

    /// #191 — the row's resolved `state` (with `takenLate`) when the server
    /// sent one, so the ledger says "Overdue" or "Due" for today's open
    /// slots instead of a flat "Pending"; otherwise the older `status`.
    nonisolated static func statusLine(row: MedicationDoseHistoryRow) -> HLRowStatus? {
        guard !row.isAdHoc,
              let phase = MedicationDosePhase(wire: row.stateRaw, takenLate: row.takenLate == true) else
        {
            return statusLine(row.status)
        }
        let look = MedicationDoseLook(phase: phase)
        switch look.tone {
        case .warning, .late: return HLRowStatus(look.title, tone: .warning)
        case .critical: return HLRowStatus(look.title, tone: .critical)
        case .quiet, .due, .success, .muted: return HLRowStatus(look.title)
        }
    }

    // MARK: - Action gating

    /// Retro-mark only on past/due rows with a real intake event behind
    /// them. The ledger never grades a future slot as taken (b162 server
    /// mirror) and a projected slot without a DB row has nothing to PUT.
    private var canRetroMark: Bool {
        row.intake?.id != nil && row.at <= now && row.status != .upcoming
    }

    private var canDelete: Bool {
        row.intake?.id != nil
    }

    /// Pin offer: an ad-hoc take whose nearest slot is still unserved.
    private var canPin: Bool {
        row.isAdHoc && row.intake?.id != nil
            && row.nearestSlot.map { !$0.filled } == true
    }

    /// Unpin offer: a slot row served by a user pin.
    private var canUnpin: Bool {
        !row.isAdHoc && row.pinned == true && row.intake?.id != nil
    }

    private var hasAnyAction: Bool {
        canRetroMark || canDelete || canPin || canUnpin
    }

    private var currentlyTaken: Bool {
        row.status == .takenOnTime || row.status == .takenLate || row.status == .adHoc
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        if canRetroMark {
            if !currentlyTaken {
                Button("Mark as taken", systemImage: "checkmark.circle", action: onMarkTaken)
            }
            if row.status != .skipped {
                Button("Mark as skipped", systemImage: "forward.end", action: onMarkSkipped)
            }
        }
        if canPin, let slot = row.nearestSlot {
            Button("med.ledger.action.pin", systemImage: "pin", action: onPin)
                .accessibilityHint(Text(String(
                    format: String(localized: "med.ledger.due_context"),
                    ClockTimeText.wire(slot.timeOfDay)
                )))
        }
        if canUnpin {
            Button("med.ledger.action.unpin", systemImage: "pin.slash", action: onUnpin)
        }
        if canDelete {
            Divider()
            // #188 (7): deleted at once, undone from the toast.
            HLDeleteMenuItem(.undoable {
                onDelete()
            })
        }
    }

    // MARK: - Presentation

    private var timestamp: String {
        let date = row.intake?.takenAt ?? row.at
        // Date part keeps the locale order; the clock part honours the
        // user's time-format preference via the central `HLTimeFormat` helper.
        let datePart = HLDateFormat.dayMonth(date)
        return "\(datePart), \(HLTimeFormat.time(date))"
    }

    /// Second line: the slot context. A late take shows its planned slot;
    /// an ad-hoc take shows the nearest slot it could have served.
    private var contextCaption: String? {
        if row.intake?.isAutoRecordedTake == true {
            return String(localized: "med.history.auto_recorded")
        }
        if row.status == .takenLate {
            // #191: "Geplant" is gone; the late take names its dose, in the
            // person's hour cycle.
            let planned = row.timeOfDay.map { ClockTimeText.wire($0) }
                ?? HLTimeFormat.time(row.at)
            return String(format: String(localized: "med.ledger.for_dose", defaultValue: "For the %@ dose"), planned)
        }
        // An ad-hoc take says so in its status; the detail names the slot
        // it could have served.
        if row.isAdHoc, let slot = row.nearestSlot {
            return String(format: String(localized: "med.ledger.due_context"), ClockTimeText.wire(slot.timeOfDay))
        }
        return nil
    }

    private func siteLabel(_ site: String) -> String {
        IntakeHistoryRow.injectionSiteLabel(site)
    }
}

/// The ledger row's actions as its context menu; a row without any action
/// gets no menu, so a long press does not open an empty one.
private struct LedgerActionsMenu<Items: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu { items() }
        } else {
            content
        }
    }
}
