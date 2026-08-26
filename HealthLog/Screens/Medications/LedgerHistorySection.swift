import SwiftUI

// v0.14.8 W3-MEDCONTRACT — server-ledger Verlauf.
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
// ≤ v1.15.17 servers / standalone mode. Filter + collapse affordances
// mirror the legacy section so the swap is invisible in muscle memory.

/// Filter mirroring `VerlaufFilter` on the legacy section.
private enum LedgerFilter: Hashable {
    case alle
    case nichtGenommen
}

struct LedgerHistorySection: View {
    let rows: [MedicationDoseHistoryRow]
    /// **H6** — the medication's configured dose, used to decide whether a
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
    /// D9 parity — collapsed to the 7 most-recent entries by default.
    @State private var isExpanded = false

    private static let collapsedCount = 7

    private var visibleRows: [MedicationDoseHistoryRow] {
        let sorted = rows.sorted { $0.at > $1.at }
        let windowed = isExpanded ? sorted : Array(sorted.prefix(Self.collapsedCount))
        switch filter {
        case .alle:
            return windowed
        case .nichtGenommen:
            // Server-graded equivalents of the legacy "Nicht genommen"
            // read: deliberate skips + true misses. Upcoming rows are
            // dropped (they have not had a chance yet).
            return windowed.filter { $0.status == .missed || $0.status == .skipped }
        }
    }

    var body: some View {
        let shown = visibleRows
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                HLSectionLabel("History")
                Spacer()
                filterMenu
            }
            HLCard {
                if shown.isEmpty {
                    Text(emptyLabel)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { idx, row in
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
                            if idx < shown.count - 1 {
                                Divider().background(HLColor.separator)
                            }
                        }
                        expandToggle
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var expandToggle: some View {
        if filter == .alle, rows.count > Self.collapsedCount {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Spacer()
                    Text(isExpanded
                        ? String(localized: "med.verlauf.history.show_less")
                        : String(localized: "med.verlauf.history.show_more"))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                    Spacer()
                }
                .padding(.top, HLSpace.md)
            }
            .buttonStyle(.plain)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(
                selection: $filter,
                label: Text(String(localized: "Filter history"))
            ) {
                Text(String(localized: "All")).tag(LedgerFilter.alle)
                Text(String(localized: "Not taken")).tag(LedgerFilter.nichtGenommen)
            }
        } label: {
            HStack(spacing: HLSpace.xxs) {
                Text(filterLabel)
                    .font(.hlCaption.weight(.semibold))
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.hlIcon(HLIconSize.rowAction, weight: .regular))
            }
            .foregroundStyle(HLText.secondary)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(String(localized: "Filter history")))
            .accessibilityValue(Text(filterLabel))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private var filterLabel: String {
        switch filter {
        case .alle: String(localized: "All")
        case .nichtGenommen: String(localized: "Not taken")
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
    /// **H6** — the medication's configured dose for the deviation comparison.
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

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(timestamp)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .lineLimit(1)
                if let caption = contextCaption {
                    Text(caption)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(1)
                }
                if let site {
                    Text(siteLabel(site))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(1)
                }
                // H6 — quiet deviation badge: the dose actually taken when it
                // differs from the configured dose (e.g. a half tablet / a
                // titration step). Surfaced as a calm caption, not an alarm.
                if let deviation = doseDeviation {
                    Label {
                        Text(String(
                            format: String(localized: "med.ledger.dose_deviation"),
                            deviation
                        ))
                    } icon: {
                        Image(systemName: "pills")
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusWarn)
                    .lineLimit(1)
                    .accessibilityLabel(Text(String(
                        format: String(localized: "med.ledger.dose_deviation.a11y"),
                        deviation
                    )))
                }
                // Build 6.3 (#64) — provenance chip: renders ONLY when the
                // server stamps a `source` we can label (WEB / API / REMINDER /
                // IMPORT / APPLE_HEALTH). Since server v1.32.8 the ledger
                // stamps it on every new intake row (CU-18), so this chip is
                // live; a pre-migration row carries `null` and an unmodelled
                // future literal maps to nil — both render no chip rather than
                // a guess.
                if let provenance = row.provenance {
                    Label {
                        Text(provenance.labelResource)
                    } icon: {
                        Image(systemName: provenance.systemImage)
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .lineLimit(1)
                    .accessibilityLabel(Text(String(
                        format: String(localized: "med.ledger.provenance.a11y"),
                        String(localized: provenance.labelResource)
                    )))
                }
            }
            Spacer()
            if row.pinned == true, !row.isAdHoc {
                // "Zugeordnet" — slot served by a deliberate user pin.
                Text(String(localized: "med.ledger.pinned_badge"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            statusIcon
            if hasAnyAction {
                actionMenuButton
            }
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
        .contentShape(Rectangle())
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

    /// **H6** — the recorded actual dose iff it deviates from the medication's
    /// configured dose. `nil` when the row carries no `doseTaken`, or when it
    /// matches the configured dose (case/whitespace-insensitively — no badge
    /// for a take that merely re-documents the same dose). The string returned
    /// is the trimmed `doseTaken` for display.
    private var doseDeviation: String? {
        guard let raw = row.intake?.doseTaken else { return nil }
        let taken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taken.isEmpty else { return nil }
        let configured = scheduledDose.trimmingCharacters(in: .whitespacesAndNewlines)
        if taken.compare(configured, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return taken
    }

    private var actionMenuButton: some View {
        Menu {
            if canRetroMark {
                if !currentlyTaken {
                    Button {
                        onMarkTaken()
                    } label: {
                        Label(String(localized: "Mark as taken"), systemImage: "checkmark.circle")
                    }
                }
                if row.status != .skipped {
                    Button {
                        onMarkSkipped()
                    } label: {
                        Label(String(localized: "Mark as skipped"), systemImage: "xmark.circle")
                    }
                }
            }
            if canPin, let slot = row.nearestSlot {
                Button {
                    onPin()
                } label: {
                    Label(
                        String(localized: "med.ledger.action.pin"),
                        systemImage: "pin"
                    )
                }
                .accessibilityHint(Text(String(
                    format: String(localized: "med.ledger.due_context"),
                    slot.timeOfDay
                )))
            }
            if canUnpin {
                Button {
                    onUnpin()
                } label: {
                    Label(String(localized: "med.ledger.action.unpin"), systemImage: "pin.slash")
                }
            }
            if canDelete {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(String(localized: "Delete entry"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.hlIcon(HLIconSize.lg, weight: .regular))
                .foregroundStyle(HLText.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(String(localized: "Edit or delete entry")))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    // MARK: - Presentation

    private var timestamp: String {
        let date = row.intake?.takenAt ?? row.at
        // M3 — date part keeps the locale order; the clock part honours the
        // user's time-format preference via the central `HLTimeFormat` helper.
        let datePart = date.formatted(.dateTime.day().month(.abbreviated))
        return "\(datePart), \(HLTimeFormat.time(date))"
    }

    /// Second line: the slot context. A late take shows its planned slot;
    /// an ad-hoc take shows the nearest slot it could have served.
    private var contextCaption: String? {
        if row.status == .takenLate {
            let planned = row.timeOfDay
                ?? HLTimeFormat.time(row.at)
            return String(format: String(localized: "med.ledger.planned_time"), planned)
        }
        if row.isAdHoc {
            if let slot = row.nearestSlot {
                return String(format: String(localized: "med.ledger.due_context"), slot.timeOfDay)
            }
            return String(localized: "med.ledger.status.adhoc")
        }
        return nil
    }

    /// Server-graded status glyph. Same shape language as the legacy row
    /// (filled check = taken, x = skipped, hollow = missed, clock =
    /// upcoming) with the Verlauf track's green/yellow/red status tints so
    /// every compliance surface tells one story.
    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .takenOnTime, .adHoc:
            Image(systemName: "checkmark.circle.fill")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLColor.statusOK)
                .accessibilityLabel(String(localized: "med.ledger.status.on_time"))
        case .takenLate:
            Image(systemName: "checkmark.circle.fill")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLColor.statusWarn)
                .accessibilityLabel(String(localized: "med.ledger.status.late"))
        case .skipped:
            Image(systemName: "xmark.circle.fill")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.tertiary)
                .accessibilityLabel(String(localized: "med.ledger.status.skipped"))
        case .missed:
            Image(systemName: "circle")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLColor.statusBad)
                .accessibilityLabel(String(localized: "med.ledger.status.missed"))
        case .upcoming:
            Image(systemName: "clock")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .accessibilityLabel(String(localized: "med.ledger.status.upcoming"))
        case nil:
            // Unknown future status literal — inert neutral dot.
            Image(systemName: "circle.dotted")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.tertiary)
        }
    }

    private func siteLabel(_ site: String) -> String {
        let cleaned = site.replacingOccurrences(of: "_", with: " ")
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}
