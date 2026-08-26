import SwiftUI

// Section views backing `MedicationDetailScreen` — moved verbatim out of
// `MedicationDetailScreen.swift` so the screen file stays under SwiftLint's
// `file_length` ceiling (pure code movement, no behavior change). The
// structs flip from `private` to internal so the screen (now a sibling
// file) can keep referencing them.

// MARK: - Queued banner

struct RetroMutateQueuedBanner: View {
    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(HLText.secondary)
            Text(String(localized: "medication.quick_mark.queued_offline"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer()
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.sm)
                .fill(HLColor.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: HLRadius.sm)
                        .stroke(HLColor.separator, lineWidth: 1)
                )
        )
        .padding(.horizontal, HLSpace.lg)
        .padding(.top, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }
}

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

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(spacing: HLSpace.md) {
                    // Route-appropriate glyph on a flat mono backplate
                    // (handbook §1.2): a syringe for an injection, a pill for
                    // everything else — an oral med no longer shows a syringe.
                    Image(systemName: medication.isInjection ? "syringe.fill" : "pills.fill")
                        .font(.hlIcon(HLIconSize.hero))
                        .foregroundStyle(HLText.primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(HLSurface.tertiary))
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(medication.name)
                            .font(.hlTitle2)
                            .foregroundStyle(HLText.primary)
                        Text(medication.dose)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                    Spacer()
                }

                // Category pill — same chrome as the list card's category pill,
                // shown for EVERY med (GLP-1 INN/class badges moved into the
                // badge row below) so the hero block is structurally identical
                // across med types.
                Text(categoryLabel)
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, HLSpace.xs)
                    .background(HLSurface.tertiary, in: Capsule())

                // Consistent "Letzte / Nächste Einnahme" strip — the SAME label
                // set + order the list card uses, regardless of cadence or med
                // type. Always two rows so every detail hero has the same rhythm.
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    heroScheduleRow(labelKey: "med.card.schedule.daily.last.label", value: lastValue)
                    heroScheduleRow(labelKey: "med.card.schedule.daily.next.label", value: nextValue)
                }

                HStack(spacing: HLSpace.sm) {
                    // GLP-1 INN + frequency badges (when recognised) ride the
                    // badge row, not the header — mono `.neutral` tone keeps the
                    // hero monochrome. The active checkmark is canonical signal.
                    if let drug {
                        HLBadge(drug.inn, tone: .neutral)
                        HLBadge(frequencyLabel(drug.standardInjectionFrequency), tone: .neutral)
                    } else if let cls = medication.treatmentClass {
                        HLBadge(cls, tone: .neutral)
                    }
                    if medication.active {
                        HLBadge(String(localized: "Active"), icon: "checkmark", tone: .success)
                    }
                }
            }
        }
    }

    private func heroScheduleRow(labelKey: String.LocalizationValue, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Text(String(localized: labelKey))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(value)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var categoryLabel: String {
        guard let raw = medication.category, !raw.isEmpty else {
            return String(localized: "med.card.category.fallback")
        }
        return MedicationCard.localizedCategory(raw)
    }

    private var lastValue: String {
        guard let last = medication.lastTakenAt else {
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

// MARK: - Last dose card

struct LastDoseSection: View {
    let lastTakenAt: Date
    let medication: Medication

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // Wording: "letzte Dosis" / "last dose" — never "next dose". The
            // SwiftLint guard in `Pharmacokinetics/` + this file forbids
            // any predictive copy (MDR boundary).
            HLSectionLabel("Last dose")
            HLCard {
                HStack(spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(HLDateFormat.date(lastTakenAt, style: .complete))
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                        // M3 — clock honours the user's time-format preference.
                        Text(HLTimeFormat.time(lastTakenAt))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                    Spacer()
                    Text(medication.dose)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Intake history

/// v0.6.1.25 B2 — operator brief 2026-05-24: "in den Verlauf Sachen
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
    let isLoading: Bool
    let onLoadMore: () -> Void
    /// T-4 retro-mutate hooks (commit 2 = signature plumbing,
    /// commit 3 = wire to MedicationsStore from the parent screen).
    let onMarkTaken: (PaginatedIntakeEvent) -> Void
    let onMarkSkipped: (PaginatedIntakeEvent) -> Void
    let onDelete: (PaginatedIntakeEvent) -> Void
    /// **15-01 (B1)** — the corrected administration instant for an entry the
    /// operator picked in the inline editor below. Parent sends it over the
    /// intake PUT (`MedicationDetailScreen.editIntakeTime(_:to:)`).
    let onEditTime: (PaginatedIntakeEvent, Date) -> Void

    /// The entry whose inline time editor is open, if any. Local, one at a
    /// time, and closed by either button — an inline row rather than a sheet so
    /// the correction happens where the wrong time is being read.
    @State private var timeEditTarget: String?
    /// The instant the open editor currently holds.
    @State private var draftTime: Date = .now

    /// v0.6.1.25 B2 — local-only filter state, not persisted across
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
    /// pass-through. Sort is stable `scheduledFor` desc (REG-10) —
    /// the call site also pre-sorts, but doing it here too means the
    /// section is self-contained and any future caller stays safe.
    private var visibleIntakes: [PaginatedIntakeEvent] {
        let now = Date.now
        let sorted = intakes.sorted { $0.scheduledFor > $1.scheduledFor }
        // D9 — collapse to the 7 most-recent ENTRIES (the filter is applied
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
            // statusIcon branches: skipped, auto-skipped (REG-10),
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
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                HLSectionLabel("History")
                Spacer()
                filterMenu
            }
            HLCard {
                if rows.isEmpty {
                    Text(emptyLabel)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, event in
                            IntakeHistoryRow(
                                event: event,
                                // Retro-mark only on past/due rows; delete is
                                // offered on every row inside IntakeHistoryRow
                                // (v0.14.8 operator brief — delete everywhere).
                                canRetroMark: event.scheduledFor < .now,
                                onMarkTaken: { onMarkTaken(event) },
                                onMarkSkipped: { onMarkSkipped(event) },
                                onDelete: { onDelete(event) },
                                onEditTime: { beginTimeEdit(event) }
                            )
                            if timeEditTarget == event.id {
                                timeEditor(for: event)
                            }
                            if idx < rows.count - 1 {
                                Divider().background(HLColor.separator)
                            }
                        }
                        historyToggle
                    }
                }
            }
        }
    }

    /// **15-01 (B1)** — open the inline editor on `event`, seeded with the time
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
                String(localized: "med.history.edit_time.label"),
                selection: $draftTime,
                in: Date.now.addingTimeInterval(-MedicationsStore.takenAtMaxAge) ... Date.now,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            HStack(spacing: HLSpace.md) {
                Button(String(localized: "Cancel")) {
                    timeEditTarget = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Button(String(localized: "Save")) {
                    timeEditTarget = nil
                    onEditTime(event, draftTime)
                }
                .buttonStyle(.plain)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            }
            .font(.hlSubhead)
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

    /// D9 — collapsed-by-7-entries disclosure. Reuses the existing
    /// "Load more" link styling (`HLText.primary` mono). Three states on the
    /// `.alle` filter:
    /// - collapsed + (older loaded rows OR more pages) → "Mehr" expands.
    /// - expanded + `hasMore` → "Mehr" pages the next 30 via `onLoadMore`.
    /// - expanded + no more pages → "Weniger" re-collapses to 7 days.
    /// The `.nichtGenommen` filter keeps paging only (no day window toggle).
    @ViewBuilder
    private var historyToggle: some View {
        if filter == .alle {
            if !isExpanded, hasOlderLoadedRows || hasMore {
                toggleLink(titleKey: "med.verlauf.history.show_more", isBusy: false) {
                    isExpanded = true
                }
            } else if isExpanded, hasMore {
                toggleLink(titleKey: "Load more", isBusy: isLoading, action: onLoadMore)
            } else if isExpanded {
                toggleLink(titleKey: "med.verlauf.history.show_less", isBusy: false) {
                    isExpanded = false
                }
            }
        } else if hasMore {
            toggleLink(titleKey: "Load more", isBusy: isLoading, action: onLoadMore)
        }
    }

    private func toggleLink(
        titleKey: String.LocalizationValue,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    // v0.6.1.2 Y4 (D-026) — link flips from .tint to
                    // HLText.primary mono.
                    Text(String(localized: titleKey))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                }
                Spacer()
            }
            .padding(.top, HLSpace.md)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    /// Trailing menu next to the "Verlauf" caption — mirrors the
    /// inline filter affordances we already use on MedicationsScreen
    /// (active/archived) and SourceFilterChips. Menu over a chip row
    /// keeps the header height stable and stays compact in DE locale.
    private var filterMenu: some View {
        Menu {
            Picker(
                selection: $filter,
                label: Text(String(localized: "Filter history"))
            ) {
                Text(String(localized: "All")).tag(VerlaufFilter.alle)
                Text(String(localized: "Not taken")).tag(VerlaufFilter.nichtGenommen)
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

// Note: `IntakeHistoryRow` lives in its own file (`IntakeHistoryRow.swift`)
// since T-4 — it carries the retro-mutate context-menu surface and is
// reusable from any screen that lists historical intakes.

// MARK: - Inventory

struct InventorySection: View {
    let inventory: Glp1InventoryDTO

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("Supply")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HStack(spacing: HLSpace.md) {
                        Image(systemName: inventory.lowStock ? "exclamationmark.triangle.fill" : "tray.full.fill")
                            .font(.hlIcon(HLIconSize.lg))
                            .foregroundStyle(inventory.lowStock ? HLColor.statusWarn : HLText.secondary)
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            // **W-INVENTORY** — the GLP-1 pen aggregate was the
                            // ONE unguarded supply path: raw `Int` counts rendered
                            // verbatim, so a corrupt server value would read as
                            // "minus X Pens". Route both counts through the same
                            // central sanity gate; a corrupt count renders "—".
                            if let pens = inventory.pensRemaining {
                                Text(InventorySanity.validCount(pens).map {
                                    String(format: String(localized: "%d Pens"), $0)
                                } ?? InventorySanity.placeholder)
                                    .font(.hlHeadline)
                                    .foregroundStyle(HLText.primary)
                                    .monospacedDigit()
                            }
                            if let weeks = inventory.weeksOfSupply {
                                Text(InventorySanity.validCount(weeks).map {
                                    String(format: String(localized: "≈ %d weeks of supply"), $0)
                                } ?? InventorySanity.placeholder)
                                    .font(.hlSubhead)
                                    .foregroundStyle(HLText.secondary)
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
}

// MARK: - Notes

struct NotesSection: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("Notes")
            HLCard {
                Text(text)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Unknown GLP-1 brand

struct UnknownGLP1BrandSection: View {
    let brand: String

    var body: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(
                    String(localized: "Drug level curve not available"),
                    systemImage: "info.circle"
                )
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                Text(String(
                    format: String(
                        localized: "%@ ist nicht im EMA-Katalog. Eine Wirkstoffkurve ist nur für zugelassene GLP-1-Präparate verfügbar."
                    ),
                    brand
                ))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
