import SwiftUI

// Section views backing `MedicationDetailScreen` — moved verbatim out of
// `MedicationDetailScreen.swift` so the screen file stays under SwiftLint's
// `file_length` ceiling (pure code movement, no behavior change). The
// structs flip from `private` to internal so the screen (now a sibling
// file) can keep referencing them.

// MARK: - Queued banner

/// The detail page's offline hint is the quick-mark hint: one form for
/// "saved, waiting to sync" wherever a dose was marked.
typealias RetroMutateQueuedBanner = QuickMarkQueuedBanner

// MARK: - Hero

/// **S6 (AUDIT-PARITY-v11612) — unified detail hero.**
///
/// Operator wish: the two med cards (generic vs GLP-1) read 1:1. The hero now
/// renders the SAME structure regardless of med type — a route-appropriate
/// glyph (pill by default, syringe only for an injection), name + dose, a
/// category pill, the consistent "Letzte / Nächste Einnahme" two-row schedule
/// strip (mirroring the list card's label set), then the badge row. Only the
/// glyph and the values differ between an oral daily med and a weekly
/// injectable — the rows + order + labels are identical so the two never
/// look like different layouts (the prior hardcoded syringe + GLP-1-only
/// badges made an oral med's hero look wrong and inconsistent).
struct MedicationHeroSection: View {
    let medication: Medication
    let drug: GLP1DrugCatalog.DrugRecord?
    /// Server-profile timezone for the next-dose projection (threaded from the
    /// detail screen so the hero reads through the SAME recurrence engine the
    /// list card + reminders use). Defaults to `.current` for previews.
    var profileTimeZone: TimeZone = .current
    /// The newest take the history on the same page shows. The medication
    /// row's `lastTakenAt` can lag behind it; the hero never reads "—" above
    /// a history full of takes.
    var latestHistoryTake: Date?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The medallion grows with the title next to it.
    @ScaledMetric(relativeTo: .title2) private var medallionSide: CGFloat = 44

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // At the accessibility sizes the medallion stands over the
                // name, so the name keeps the card's width instead of a
                // column beside it ("Lisino-/pril").
                identityLayout {
                    // Route-appropriate glyph on a flat mono backplate
                    // (handbook §1.2): a syringe for an injection, a pill for
                    // everything else — an oral med no longer shows a syringe.
                    Image(systemName: medication.isInjection ? "syringe.fill" : "pills.fill")
                        .font(.hlIcon(HLIconSize.hero))
                        .foregroundStyle(HLText.primary)
                        .frame(width: medallionSide, height: medallionSide)
                        .background(Circle().fill(HLSurface.tertiary))
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        // The object's name in 17 pt semibold, as on the
                        // list card and in the sheets.
                        Text(medication.name)
                            .hlText(.objectName)
                        Text(verbatim: Self.subtitle(medication))
                            .hlText(.factLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Category pill — same chrome and the same rule as the list
                // card's (1.4 B4: only a category that tells something; no
                // "Medikament" or "Sonstige" pill). GLP-1 INN/class badges ride
                // the badge row below.
                if let categoryLabel {
                    HLBadge(categoryLabel)
                }

                // The plan belongs to the object (Z16 §3): its cadence and
                // dose windows, then the consistent "Letzte / Nächste
                // Einnahme" pair the list card uses. A record has nothing due
                // (v1.39.1, #1033): its "Nur dokumentiert" badge says so.
                HLFactGroup {
                    // The person's own directions, in full, before the plan.
                    if let note = medication.note {
                        HLFactRow(label: Text("med.note.label"), value: Text(verbatim: note))
                    }
                    if let plan = MedicationPlanText.line(medication.displaySchedule) {
                        HLFactRow(label: Text("Plan"), value: Text(verbatim: plan))
                    }
                    if let windows = MedicationPlanText.doseWindows(medication.displaySchedule) {
                        HLFactRow(label: Text("med.hero.doseWindows.label"), value: Text(verbatim: windows))
                    }
                    heroScheduleRow(labelKey: "med.card.schedule.daily.last.label", value: lastValue)
                    if medication.tracksIntake {
                        heroScheduleRow(labelKey: "med.card.schedule.daily.next.label", value: nextValue)
                    }
                }

                // The badges wrap as whole chips, line by line, so a large
                // text size never splits "Aktiv" into letters.
                if hasBadges {
                    HLFlowLayout(spacing: HLSpace.sm) {
                        // GLP-1 INN + frequency badges (when recognised) ride
                        // the badge row, not the header — mono `.neutral` tone
                        // keeps the hero monochrome. The active checkmark is
                        // canonical signal.
                        if let drug {
                            HLBadge(Self.innLabel(drug.inn), tone: .neutral)
                            HLBadge(frequencyLabel(drug.standardInjectionFrequency), tone: .neutral)
                        } else if let cls = medication.treatmentClass {
                            HLBadge(cls, tone: .neutral)
                        }
                        if medication.active {
                            HLBadge(String(localized: "Active"), icon: "checkmark", tone: .success)
                        }
                        if !medication.tracksIntake {
                            HLBadge(String(localized: "medications.recordOnly.badge"), icon: "doc.text")
                                .accessibilityIdentifier("medications.recordOnly.badge")
                        }
                        if let course = MedicationCourseBadge.resolve(medication) { MedicationCourseStatusBadge(badge: course) }
                    }
                }
            }
        }
    }

    private var identityLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
            : AnyLayout(HStackLayout(spacing: HLSpace.md))
    }

    private var hasBadges: Bool {
        drug != nil || medication.treatmentClass != nil || medication.active || !medication.tracksIntake
            || MedicationCourseBadge.resolve(medication) != nil
    }

    /// The newest of the medication's own `lastTakenAt` and the history's
    /// newest take.
    nonisolated static func lastTaken(_ lastTakenAt: Date?, latestHistoryTake: Date?) -> Date? {
        switch (lastTakenAt, latestHistoryTake) {
        case let (row?, history?): max(row, history)
        case let (row?, nil): row
        case let (nil, history?): history
        case (nil, nil): nil
        }
    }

    /// The newest take in the server ledger, or, without one, in the intake
    /// pages: a taken dose (on time, late or ad hoc), never a skip or a miss.
    nonisolated static func latestTake(
        ledger: [MedicationDoseHistoryRow]?,
        intakes: [PaginatedIntakeEvent]
    ) -> Date? {
        if let ledger {
            return ledger.compactMap { row -> Date? in
                switch row.status {
                case .takenOnTime, .takenLate, .adHoc: row.intake?.takenAt ?? row.at
                default: nil
                }
            }.max()
        }
        return intakes.filter { !$0.skipped }.compactMap(\.takenAt).max()
    }

    /// The active ingredient in the reader's language ("Dulaglutid"); a name
    /// the catalogue does not know stays as the drug record spells it.
    nonisolated static func innLabel(_ inn: String) -> String {
        switch inn {
        case "Tirzepatide": String(localized: "glp1.inn.tirzepatide")
        case "Semaglutide": String(localized: "glp1.inn.semaglutide")
        case "Liraglutide": String(localized: "glp1.inn.liraglutide")
        case "Dulaglutide": String(localized: "glp1.inn.dulaglutide")
        case "Exenatide": String(localized: "glp1.inn.exenatide")
        default: inn
        }
    }

    /// The dose, and, when the server sends no reminders for a medication that
    /// would otherwise remind (MED-PLUS, v1.42.2 `remindersActive`), "erinnert
    /// nicht" in the same line.
    static func subtitle(_ medication: Medication) -> String {
        guard medication.saysNoReminders else { return medication.dose }
        let dose = medication.dose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dose.isEmpty else { return String(localized: "med.hero.noReminders") }
        return String(localized: "med.hero.dose.noReminders \(dose)")
    }

    /// POLISH-A (SHOTS F-AX-MEDCARD) — side by side, and label over value at
    /// an accessibility size, where two columns cut "morgen, 8…".
    private func heroScheduleRow(labelKey: String.LocalizationValue, value: String) -> some View {
        HLFactRow(label: Text(String(localized: labelKey)), value: Text(value))
    }

    private var categoryLabel: String? {
        MedicationCard.categoryPillLabel(category: medication.category, label: medication.categoryLabel)
    }

    private var lastValue: String {
        guard let last = Self.lastTaken(medication.lastTakenAt, latestHistoryTake: latestHistoryTake) else {
            return String(localized: "med.card.schedule.value.unset")
        }
        return MedicationCard.relativeDateTime(last)
    }

    private var nextValue: String {
        guard let next = MedicationCard.computeNextDose(
            medication: medication,
            timeZone: profileTimeZone,
            now: .now
        ) else {
            return String(localized: "med.card.schedule.value.unset")
        }
        return MedicationCard.relativeDateTime(next)
    }

    private func frequencyLabel(_ freq: GLP1DrugCatalog.InjectionFrequency) -> String {
        switch freq {
        case .daily: String(localized: "Daily")
        case .twiceDaily: String(localized: "2× daily")
        case .weekly: String(localized: "Weekly")
        }
    }
}

// MARK: - Intake history

/// Operator brief 2026-05-24: "in den Verlauf Sachen
/// sehe ich auch die Sachen relativ unsortiert leider noch. […]
/// vor allen Dingen nur die Sachen angezeigt werden, die ich nicht
/// genommen habe". `Alle` keeps the existing at-a-glance read,
/// `nichtGenommen` filters to anything that is not a confirmed
/// taken intake (skipped, auto-skipped, still-pending past-due).
private enum VerlaufFilter: Hashable {
    case alle
    case nichtGenommen
}

struct IntakeHistorySection: View {
    let intakes: [PaginatedIntakeEvent]
    let hasMore: Bool
    /// The medication's configured dose for the taken rows.
    var dose: String = ""
    /// The server's count of all intakes (`meta.total`), `nil` when it sent
    /// none.
    var totalCount: Int?
    let isLoading: Bool
    let onLoadMore: () -> Void
    /// T-4 retro-mutate hooks (commit 2 = signature plumbing,
    /// commit 3 = wire to MedicationsStore from the parent screen).
    let onMarkTaken: (PaginatedIntakeEvent) -> Void
    let onMarkSkipped: (PaginatedIntakeEvent) -> Void
    let onDelete: (PaginatedIntakeEvent) -> Void
    /// The corrected administration instant for an entry the
    /// operator picked in the inline editor below. Parent sends it over the
    /// intake PUT (`MedicationDetailScreen.editIntakeTime(_:to:)`).
    let onEditTime: (PaginatedIntakeEvent, Date) -> Void

    /// The entry whose inline time editor is open, if any. Local, one at a
    /// time, and closed by either button — an inline row rather than a sheet so
    /// the correction happens where the wrong time is being read.
    @State private var timeEditTarget: String?
    /// The instant the open editor currently holds.
    @State private var draftTime: Date = .now

    /// Local-only filter state, not persisted across
    /// app launches (operator only wants ad-hoc isolation when they
    /// scan the history, default Alle keeps "what did I do recently"
    /// intact on every fresh open).
    @State private var filter: VerlaufFilter = .alle

    /// D9 (v0.10.0 Walkthrough-1) — collapsed by default to the last 7 ENTRIES
    /// (not the last 7 days) so the history opens tidy regardless of dosing
    /// cadence. "Mehr anzeigen" first reveals the already-loaded older rows,
    /// then subsequent taps page via `onLoadMore`. Page size stays 30 so the
    /// 30-day KPI / glyph analytics keep their rows. Mirrors the mood screen's
    /// last-7 + "Alle anzeigen" pattern for cross-screen consistency.
    @State private var isExpanded = false

    /// Collapsed window: the 7 most-recent intake entries.
    private static let collapsedCount = 7

    /// Sort + filter applied in one pass so the parent stays a thin
    /// pass-through. Sort is stable `scheduledFor` desc —
    /// the call site also pre-sorts, but doing it here too means the
    /// section is self-contained and any future caller stays safe.
    /// On the detail page the newest entries and a row to the full list;
    /// the full list, with filter and paging, is its own page.
    var mode: LedgerHistorySection.Mode = .preview

    private var visibleIntakes: [PaginatedIntakeEvent] {
        let now = Date.now
        let sorted = intakes.sorted { $0.scheduledFor > $1.scheduledFor }
        if mode == .preview {
            return Array(sorted.prefix(LedgerHistorySection.previewCount))
        }
        // Collapse to the 7 most-recent ENTRIES (the filter is applied
        // AFTER the window so "Alle"/"Nicht genommen" both read from the same
        // 7-row collapsed set; expanding lifts the cap before filtering).
        let windowed: [PaginatedIntakeEvent] = isExpanded
            ? sorted
            : Array(sorted.prefix(Self.collapsedCount))
        switch filter {
        case .alle:
            return windowed
        case .nichtGenommen:
            // "Nicht genommen" = anything that does not render the
            // green-checkmark in IntakeHistoryRow. Mirrors the row's
            // statusIcon branches: skipped, auto-skipped,
            // and past-due-pending all count; future-scheduled rows
            // are dropped because they have not had a chance yet.
            return windowed.filter { event in
                if event.takenAt != nil, !event.skipped { return false }
                if event.scheduledFor > now { return false }
                return true
            }
        }
    }

    var body: some View {
        let rows = visibleIntakes
        Group {
            HLSectionHeader("History", rank: .area)
            if rows.isEmpty {
                HLCard { HLEmptyNote(Text(emptyLabel)) }
            } else {
                HLCard(layout: .rows) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { _, event in
                        IntakeHistoryRow(
                            event: event,
                            // Retro-mark only on past/due rows; delete is
                            // offered on every row inside IntakeHistoryRow
                            // (v0.14.8 operator brief — delete everywhere).
                            canRetroMark: event.scheduledFor < .now,
                            onMarkTaken: { onMarkTaken(event) },
                            onMarkSkipped: { onMarkSkipped(event) },
                            onDelete: { onDelete(event) },
                            onEditTime: { beginTimeEdit(event) },
                            dose: dose
                        )
                        if timeEditTarget == event.id {
                            timeEditor(for: event)
                        }
                    }
                    if mode == .preview {
                        // The row to the full list whenever there is a
                        // history, with the server's total once more pages wait.
                        if !intakes.isEmpty {
                            HLDrillRow("med.history.show_all", count: hasMore ? totalCount : intakes.count)
                                .hlRowLink { fullPage }
                                .accessibilityIdentifier("med.history.showAll")
                        }
                    } else {
                        historyToggle
                    }
                }
            }
        }
        // The filter belongs to the full list's bar, not to its content.
        .hlPageActions(mode == .full ? HLTabHeaderActions([filterAction]) : .none)
    }

    /// The whole history on a page of its own, with filter and paging.
    private var fullPage: some View {
        var full = self
        full.mode = .full
        return HLPage { full }
            .navigationTitle(Text("History"))
            .navigationBarTitleDisplayMode(.inline)
            .hlDeleteConfirmation()
    }

    /// Open the inline editor on `event`, seeded with the time
    /// it currently claims (never `.now`: the operator is correcting a value,
    /// not entering a new one).
    private func beginTimeEdit(_ event: PaginatedIntakeEvent) {
        draftTime = event.takenAt ?? event.scheduledFor
        timeEditTarget = event.id
    }

    /// The inline correction row. Bounded exactly like the manual backfill
    /// sheet: no future instant, nothing older than the server's five-year
    /// `takenAt` floor — so a value that cannot be saved cannot be picked.
    private func timeEditor(for event: PaginatedIntakeEvent) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            DatePicker(
                selection: $draftTime,
                in: Date.now.addingTimeInterval(-MedicationsStore.takenAtMaxAge) ... Date.now,
                displayedComponents: [.date, .hourAndMinute]
            ) {
                HLRowTitle("med.history.edit_time.label")
            }
            .datePickerStyle(.compact)
            HLButtonPair {
                HLButton(HLControlWord.save.key) {
                    timeEditTarget = nil
                    onEditTime(event, draftTime)
                }
            } secondary: {
                HLButton(HLControlWord.cancel.key, variant: .secondary) {
                    timeEditTarget = nil
                }
            }
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "med.history.edit_time.action")))
    }

    /// True when there are more loaded rows than the collapsed 7-entry window
    /// (so "Mehr" has something to reveal before it needs to page).
    private var hasOlderLoadedRows: Bool {
        intakes.count > Self.collapsedCount
    }

    /// Collapsed-by-7-entries disclosure. Reuses the existing
    /// "Load more" link styling (`HLText.primary` mono). Three states on the
    /// `.alle` filter:
    /// - collapsed + (older loaded rows OR more pages) → "Mehr" expands.
    /// - expanded + `hasMore` → "Mehr" pages the next 30 via `onLoadMore`.
    /// - expanded + no more pages → "Weniger" re-collapses to 7 days.
    /// The `.nichtGenommen` filter keeps paging only (no day window toggle).
    @ViewBuilder
    private var historyToggle: some View {
        switch Self.historyLink(
            filtersMissed: filter == .nichtGenommen,
            isExpanded: isExpanded,
            hasOlderLoadedRows: hasOlderLoadedRows,
            hasMore: hasMore
        ) {
        case .showMore:
            HLLinkButton("med.verlauf.history.show_more", isExpanded: false) {
                isExpanded = true
            }
        case .showFewer:
            HLLinkButton("med.verlauf.history.show_less", isExpanded: true) {
                isExpanded = false
            }
        case .loadMore:
            HLLoadMoreRow(hasMore: true, isLoading: isLoading, load: onLoadMore)
        case .none:
            EmptyView()
        }
    }

    /// The link under the full history.
    enum HistoryLink: Equatable {
        case showMore
        case showFewer
        case loadMore
        case none
    }

    /// Collapsed, the link unfolds the rows already loaded; unfolded, it
    /// pages the next ones while the server has more, then folds back. The
    /// missed-only filter only pages.
    nonisolated static func historyLink(
        filtersMissed: Bool,
        isExpanded: Bool,
        hasOlderLoadedRows: Bool,
        hasMore: Bool
    ) -> HistoryLink {
        if filtersMissed { return hasMore ? .loadMore : .none }
        if !isExpanded { return hasOlderLoadedRows || hasMore ? .showMore : .none }
        return hasMore ? .loadMore : .showFewer
    }

    private var filterAction: HLTabHeaderAction {
        .filter(label: "Filter history", isSelected: filter != .alle) {
            Picker(
                selection: $filter,
                label: Text(String(localized: "Filter history"))
            ) {
                Text(String(localized: "All")).tag(VerlaufFilter.alle)
                Text(String(localized: "Not taken")).tag(VerlaufFilter.nichtGenommen)
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

// Note: `IntakeHistoryRow` lives in its own file (`IntakeHistoryRow.swift`)
// since T-4 — it carries the retro-mutate context-menu surface and is
// reusable from any screen that lists historical intakes.

// MARK: - Inventory

struct InventorySection: View {
    let inventory: Glp1InventoryDTO

    var body: some View {
        HLSectionHeader("Supply", rank: .area)
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: inventory.lowStock ? "exclamationmark.triangle.fill" : "tray.full.fill")
                        .font(.hlIcon(HLIconSize.lg))
                        .foregroundStyle(inventory.lowStock ? HLColor.statusWarn : HLText.secondary)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        // The GLP-1 pen aggregate was the
                        // ONE unguarded supply path: raw `Int` counts rendered
                        // verbatim, so a corrupt server value would read as
                        // "minus X Pens". Route both counts through the same
                        // central sanity gate; a corrupt count renders "—".
                        if let pens = inventory.pensRemaining {
                            Text(InventorySanity.validCount(pens).map {
                                String(format: String(localized: "%d Pens"), $0)
                            } ?? InventorySanity.placeholder)
                                .hlText(.objectName)
                                .monospacedDigit()
                        }
                        if let weeks = inventory.weeksOfSupply {
                            Text(InventorySanity.validCount(weeks).map {
                                String(format: String(localized: "≈ %d weeks of supply"), $0)
                            } ?? InventorySanity.placeholder)
                                .hlText(.factLabel)
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                }
                if inventory.lowStock {
                    Text(String(localized: "Supply is running low."))
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusWarn)
                }
            }
        }
    }
}

// MARK: - Notes

struct NotesSection: View {
    let text: String

    var body: some View {
        HLSectionHeader("Notes", rank: .area)
        HLCard {
            Text(text)
                .hlText(.factLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
