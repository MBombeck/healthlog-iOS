import SwiftUI

/// **W-REMINDERS (#23 v1.18.1) — manage Vorsorge measurement reminders.**
///
/// The native counterpart to the web `/settings/notifications` reminder list,
/// consuming the LIVE `GET /api/measurement-reminders`. Each row shows the type
/// label, the server-computed schedule + next-due (rendered verbatim — NO local
/// due-date math), a provenance badge (Vorsorge vs Coach via `origin`), and the
/// course-end (`endsOn`) when set. A swipe / context action marks the reminder
/// done ("Erledigt", the MANUAL satisfy) or deletes it; the toolbar `+` creates
/// a new Vorsorge reminder.
///
/// Reached from `NotificationsScreen` (the preventive-care opt-in card's
/// "Manage reminders" link). Built lazily off `container.api` + `container.swr`
/// like the parent's `NotificationsStore`.
struct MeasurementRemindersScreen: View {
    /// The manage screen now reads the app-wide store
    /// (promoted to `AppContainer.measurementRemindersStore`) so it shares one
    /// SWR-deduped load with the Home Vorsorge tile. The previous view-local
    /// `@State` store double-fetched against the tile and never participated in
    /// the logout cascade.
    @Environment(MeasurementRemindersStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var showingCreate = false
    /// The reminder being edited, presented via `.sheet(item:)` in edit mode.
    @State private var editingReminder: MeasurementReminderRow?
    /// The reminder whose detail sheet is open (tap opens history + details).
    @State private var detailRow: MeasurementReminderRow?

    var body: some View {
        HLPage {
            SectionRootHeader("reminders.manage.title")
            NextVisitSection { content(store: store) } // VISIT — "Nächster Termin" above, only while booked
            // 1.0.3 (1.4.1) — where the screening cadences come from. 1.4 B4:
            // only under reminders; the empty state states nothing to cite.
            if VorsorgeCard.showsSources(reminders: store.reminders) {
                HLSourcesLink(topic: .vorsorge)
            }
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
        // Inline when pushed; as a sidebar tab the page heads itself.
        .hlSectionRootTitle(Text("reminders.manage.title"))
        .hlPageActions([
            .add(label: "reminders.create.action", identifier: "MeasurementRemindersScreen.create") {
                showingCreate = true
            }
        ])
        .task { await store.load() }
        .hlRefresh(in: .list) { await store.load(force: true) }
        .sheet(isPresented: $showingCreate) {
            MeasurementReminderCreateSheet { body in
                await MeasurementReminderCreateSheet.outcome(store.create(body), store: store)
            }
        }
        .sheet(item: $editingReminder) { row in
            MeasurementReminderCreateSheet(
                editing: row,
                onCreate: { _ in .unknown("") },
                onUpdate: { await MeasurementReminderCreateSheet.outcome(store.update(id: $0, patch: $1), store: store) }
            )
        }
        .sheet(item: $detailRow) { row in
            VorsorgeReminderDetailSheet(
                row: row,
                store: store,
                onMeasure: { kind in router.requestMeasure(prefill: kind) },
                onCheckIn: { router.requestMentalWellbeingCheckIn() },
                onMarkDone: { Task { await store.complete(id: row.id) } }
            )
        }
        // A reminder card's delete asks here, on the page.
        .hlDeleteConfirmation()
        .hlAcknowledgeAlert(
            "Error",
            item: Binding(get: { store.error }, set: { if $0 == nil { store.error = nil } })
        ) { err in
            Text(err.userFacingDescription)
        }
    }

    @ViewBuilder
    private func content(store: MeasurementRemindersStore) -> some View {
        if VorsorgeCard.shouldShowEmptyState(reminders: store.reminders) {
            emptyCard(loading: store.isLoading)
        } else {
            // v0.15.1 web-parity — each reminder renders as its OWN med-styled
            // card (mirroring web `vorsorge-section.tsx` v1.18.2): cadence chip
            // + next/last block + discreet 7-day strip + origin badge + a single
            // bottom-pinned action that branches on `measurementType`
            // (measure-now vs mark-done). No status-driven card tint — the calm
            // dark look stays; due state reads through the action button only.
            //
            // The repetitive "due dates are server-computed" footer
            // stays removed; reminders auto-satisfy server-side.
            VStack(spacing: HLSpace.md) {
                // G1 (2026-08-22) — the aggregate adherence header („4 von 4 im
                // Plan") is GONE, on the operator's statement „soll komplett
                // raus". It is worth recording that he asked for it himself at
                // b215 (`b84adbe0`, 2026-07-07) and withdrew it on 2026-08-22:
                // restoring it needs a NEW request, not the old one. The
                // per-reminder completion ledger the card's last revision pointed
                // at is unaffected — it lives on the reminder it describes, in
                // `VorsorgeReminderDetailSheet`.
                ForEach(store.reminders) { row in
                    VorsorgeReminderCardView(
                        row: row,
                        // The tile needs the store for its own skip/snooze
                        // pair; the same store, the same methods and the same
                        // learned 404 gate the detail sheet uses.
                        store: store,
                        onMeasure: { kind in router.requestMeasure(prefill: kind) },
                        // A screening reminder (PHQ9/GAD7/WHO5) opens the
                        // mental-health check-in surface, not a numeric form.
                        onCheckIn: { router.requestMentalWellbeingCheckIn() },
                        onMarkDone: { Task { await store.complete(id: row.id) } },
                        onEdit: { editingReminder = row },
                        // Parity 1.8a — it asks first, never deletes inline.
                        delete: .confirmed(
                            title: "reminders.delete.confirm.title",
                            message: "reminders.delete.confirm.body"
                        ) {
                            _ = await store.delete(id: row.id)
                        },
                        // The header/body tap opens the detail sheet.
                        onOpenDetail: { detailRow = row }
                    )
                }
            }
        }
    }

    /// The app's one empty-state lockup, on the page rather than in
    /// a card titled "Erinnerungen" over a line saying there are none. It has
    /// no button: the plus in the bar is the one way to add a reminder.
    @ViewBuilder
    private func emptyCard(loading: Bool) -> some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLLayout.cardInset)
        } else {
            // The one action creates the first reminder where the eye
            // already is; the plus in the bar stays.
            HLEmptyState(icon: "calendar.badge.clock", title: "reminders.empty.title") {
                HLButton("reminders.create.action", systemImage: "plus", variant: .secondary) { showingCreate = true }
                    .accessibilityIdentifier("MeasurementRemindersScreen.empty.create")
            }
            .accessibilityIdentifier("MeasurementRemindersScreen.empty")
        }
    }
}

// MARK: - Card

/// One preventive-care reminder rendered as its own med-styled card — the iOS
/// mirror of the web `vorsorge-section.tsx` `VorsorgeCard` (v1.18.2):
///
/// - **Header:** the reminder name + the cadence chip ("Every N days" / Custom)
///   directly beside it; Edit and Delete sit in the card's context menu.
/// - **Origin/state badges:** Vorsorge vs Coach provenance, plus a "disabled"
///   pill when the reminder is off.
/// - **Next/last block:** "Next due" (relative, calm wording) + "Last done"
///   (the server `lastSatisfiedAt`, "—" when never) — render-only.
/// - **7-day strip:** discreet bars from the metric's last seven readings
///   (mirrors `VorsorgeTrendStrip`); self-suppresses for free-text reminders or
///   a too-thin window.
/// - **`endsOn` line:** the course-end, when set (render verbatim).
/// - **Action:** a single bottom-pinned button that branches on
///   `measurementType` — "Measure now" (opens the prefilled capture sheet via
///   the SAME `router.requestMeasure(prefill:)` path as the Home tile) vs
///   "Mark done" (the server-authoritative `complete`). The card surface stays
///   NEUTRAL; only the button takes the prominent tone when due.
struct VorsorgeReminderCardView: View {
    let row: MeasurementReminderRow
    /// The tile's own skip/snooze pair calls the store directly, the
    /// same way the detail sheet does. Handing the store down rather than four
    /// more closures keeps ONE implementation of the accepted cycle actions
    /// (`VorsorgeReminderLedgerActions`), which is the whole lesson of the
    /// mirrored-tile drift this plan closes.
    let store: MeasurementRemindersStore
    let onMeasure: (MetricKind) -> Void
    /// Start the mental-health check-in (screening reminders).
    let onCheckIn: () -> Void
    let onMarkDone: () -> Void
    let onEdit: () -> Void
    let delete: HLDeleteAction
    /// The header/body tap opens the detail sheet (history + details),
    /// mirroring the mental-health card's `onOpenDetail`. Kebab + primary button
    /// stay their own targets.
    let onOpenDetail: () -> Void

    private var primaryAction: VorsorgeCard.PrimaryAction {
        VorsorgeCard.primaryAction(for: row)
    }

    var body: some View {
        // FW-VORSORGE (b210, corrected 2026-08-23) — the card mirrors
        // `MedicationCard`'s anatomy: the same `HLCard` chrome, the same
        // `HLSpace.md` inter-block rhythm, a headline header, a monochrome
        // category-pill treatment (`metaRow`), and a schedule block that matches
        // the med `ScheduleLine`.
        //
        // The last clause of this comment used to say the action „already used
        // the `.secondary` twin of `monochromeActionButton`". That stopped being
        // true on 2026-07-31 (`d06174e6`) and the comment kept saying it for
        // three weeks — which is how the operator found G2 a third time. The
        // actions are no longer described here at all: they render from
        // `HLTileActionButton`, the single carrier R9/E2-A1 names, and
        // `VorsorgeMedicationTileParityTests` is what states the parity now.
        // A comment cannot be red; a test can.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                header
                // The meta + Next/Last + strip region is one tap target
                // that opens the detail sheet (like the mental-health card's
                // header tap). The primary button
                // below stay separate 44-pt targets.
                Button(action: onOpenDetail) {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        metaRow
                        nextLastBlock
                        VorsorgeTrendStripView(measurementType: row.measurementType)
                        if let ends = endsOnLine {
                            Text(ends)
                                .hlText(.footnote)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hlRow)
                .accessibilityHint(Text("vorsorge.card.openDetail.hint"))
                .accessibilityIdentifier("vorsorge.card.openDetail.\(row.id)")
                primaryButton
                // Überspringen and Snoozen at TILE level, not sheet-only.
                // The operator's „Skip/Snooze funktionieren ordentlich" meant
                // reachable the way the medication tile's pair is reachable:
                // without opening anything. Same type as the detail sheet mounts,
                // so the two placements cannot drift; the pair self-suppresses
                // per reminder once the server has refused the route for it
                // (the 08-22 capability-refusal path, reused rather than
                // reimplemented — on a pre-v1.37.20 server the affordances
                // withdraw for the session by design).
                VorsorgeReminderLedgerActions(row: row, store: store, placement: .tile)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        // Edit and Delete live in the card's context menu, as on every row in
        // a card: one way to them, no own "more" button in the head.
        .contextMenu {
            Button(action: onEdit) {
                Label("reminders.action.edit", systemImage: "pencil")
            }
            HLDeleteMenuItem(delete)
        }
    }

    /// The reminder's name, as an object card names its object: 17 semibold,
    /// up to two lines. It is also a tap target for the detail sheet.
    private var header: some View {
        Button(action: onOpenDetail) {
            Text(headerTitle)
                .hlText(.objectName, status: row.enabled ? HLText.primary : HLText.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
    }

    /// Meta pill row on its own line below the header, mirroring the
    /// med card's `categoryPill` placement + `HLSpace.md` gap. Type + cadence use
    /// the SAME monochrome capsule treatment as `MedicationCard.categoryPill`
    /// (`HLSurface.tertiary` fill, `.hlCaption` semibold, `HLText.secondary`); the
    /// Coach provenance + disabled state keep their signal-carrying `HLBadge`.
    @ViewBuilder
    private var metaRow: some View {
        if typeBadgeText != nil || cadenceChip != nil || hasStateBadges {
            HStack(spacing: HLSpace.xs) {
                if let type = typeBadgeText {
                    metaPill(type)
                }
                if let chip = cadenceChip {
                    metaPill(chip)
                }
                originBadge
                ledgerStatePills
                if !row.enabled {
                    HLBadge(String(localized: "vorsorge.card.disabled"), tone: .neutral)
                }
            }
        }
    }

    /// **ROUTE-07 (v1.37.20)** — the two server-owned ledger states, formatted
    /// and never computed. "Snoozed" is `snoozedUntil > now` and "skipped" is
    /// `lastSkippedAt > lastSatisfiedAt` — the clock comparisons the accepted
    /// DTO tells clients to make, both routed through `VorsorgeCard` so the card
    /// and the detail sheet read the row identically. The skip count is the
    /// server's `skipCount` rendered verbatim.
    @ViewBuilder
    private var ledgerStatePills: some View {
        if let until = row.snoozedUntil, VorsorgeCard.isSnoozed(row) {
            metaPill(String(
                format: String(localized: "vorsorge.card.snoozedUntil"),
                HLDateFormat.dayMonth(until)
            ))
        }
        if VorsorgeCard.hasSkippedCurrentCycle(row) {
            metaPill(String(localized: "vorsorge.card.skippedCycle"))
        }
        if row.skipCount > 0 {
            metaPill(String(format: String(localized: "vorsorge.card.skipCount"), row.skipCount))
        }
    }

    /// The same mark as the medication card's category, so both card
    /// families share one.
    private func metaPill(_ text: String) -> some View {
        HLBadge(text)
    }

    /// Row-1 title: the user Bezeichnung, or the type label when no label
    /// exists. Parity 1.8b — a COACH reminder's `label` is an i18n key, so it
    /// goes through `VorsorgeCard.resolvedLabel(for:)` instead of rendering
    /// verbatim.
    private var headerTitle: String {
        if let resolved = VorsorgeCard.resolvedLabel(for: row) { return resolved }
        return MeasurementReminderType.label(for: row.measurementType, fallback: "")
    }

    /// Row-2 type badge text — `nil` when there is no type, or when the title
    /// already IS the type label (no-label fallback) so we don't duplicate it.
    private var typeBadgeText: String? {
        guard row.measurementType?.isEmpty == false else { return nil }
        guard let resolved = VorsorgeCard.resolvedLabel(for: row) else { return nil }
        return Self.badge(MeasurementReminderType.label(for: row.measurementType, fallback: resolved), title: resolved)
    }

    /// The type badge, unless it says what the title already says: a label
    /// the person typed as the type's own name ("Taillenumfang" over
    /// "Taillenumfang") is one name, not two.
    nonisolated static func badge(_ typeLabel: String, title: String) -> String? {
        let same = typeLabel.trimmingCharacters(in: .whitespaces)
            .compare(title.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        return same ? nil : typeLabel
    }

    /// Next-due (relative, calm wording) + last-done block — both render-only.
    ///
    /// Fact rows like the medication card's schedule: label secondary, value
    /// primary on the right, at AX sizes the value under its label instead of
    /// a column of syllables ("Nächs-/ter Ter-/min").
    private var nextLastBlock: some View {
        HLFactGroup {
            HLFactRow(label: Text("vorsorge.card.nextDue"), value: Text(dueText))
            HLFactRow(label: Text("vorsorge.card.lastDone"), value: Text(lastDoneText))
        }
    }

    /// **G2 (third delivery, 2026-08-23).** The tile's primary action.
    ///
    /// b198 already asked for this to stop being a full-`.tint` slab that
    /// out-typed the card heading („over the top / creepy"), and b210/b215
    /// delivered it as a mirror of the medication card's inline pair. `d06174e6`
    /// then translated the mirror's `.restrained` to `.secondary` — correct
    /// under the wording of the day, and it took the shape from
    /// 44 pt/`.hlSubhead`/monochrome to 48 pt/`.hlHeadline`/`HLText.primary`
    /// without anything noticing.
    ///
    /// There is no mirror any more. `HLTileActions` is the one carrier
    /// R9/E2-A1 names, the medication tile renders from the same type, and
    /// `VorsorgeMedicationTileParityTests` fails — with the history in its
    /// message — if either surface leaves it alone.
    private var primaryButton: some View {
        HLTileActions([primaryItem])
    }

    /// One action, still a tile row: it stands over the skip and snooze pair
    /// and keeps that pair's height and ink.
    private var primaryItem: HLTileAction.Item {
        switch primaryAction {
        case let .measure(kind):
            HLTileAction.Item("vorsorge.card.measureNow", icon: "plus", identifier: "vorsorge.card.measureNow") {
                onMeasure(kind)
            }
        case .checkIn:
            // Screening reminder (PHQ9/GAD7/WHO5): the score is derived,
            // so the action starts the mental-health check-in rather than a
            // numeric capture form.
            HLTileAction.Item("vorsorge.card.checkIn", icon: "brain.head.profile", identifier: "vorsorge.card.checkIn") {
                onCheckIn()
            }
        case .markDone:
            HLTileAction.Item("vorsorge.card.markDone", icon: "checkmark", identifier: "vorsorge.card.markDone") {
                onMarkDone()
            }
        }
    }

    /// The badge band below the header now only carries the Coach
    /// provenance pill and the disabled state. The generic "Vorsorge" pill was
    /// dropped (it was redundant on a screen that is already all Vorsorge); type
    /// + cadence moved into the header's row 2.
    private var hasStateBadges: Bool {
        row.origin == .coach || !row.enabled
            || VorsorgeCard.isSnoozed(row) || row.skipCount > 0
            || VorsorgeCard.hasSkippedCurrentCycle(row)
    }

    /// Provenance pill — Coach (suggestion) only. The generic Vorsorge pill was
    /// removed; `.vorsorge` / `.unknown` render nothing here.
    @ViewBuilder
    private var originBadge: some View {
        switch row.origin {
        case .coach:
            HLBadge(String(localized: "reminder.origin.coach"), icon: "sparkles", tone: .purple)
        case .vorsorge, .unknown:
            EmptyView()
        }
    }

    /// Cadence chip text — "Every N days" or a "Custom" label for an RRULE.
    private var cadenceChip: String? {
        guard let (key, days) = VorsorgeCard.cadenceKeyAndArg(for: row) else { return nil }
        if let days {
            return String(format: String(localized: String.LocalizationValue(key)), days)
        }
        return String(localized: String.LocalizationValue(key))
    }

    /// Relative due text — the web `relativeDueKey` mirror. Shared with the
    /// detail sheet via `VorsorgeCard.dueDisplayText`.
    private var dueText: String {
        VorsorgeCard.dueDisplayText(nextDueAt: row.nextDueAt)
    }

    /// Relative last-done text — "heute"/"gestern" where natural, absolute date
    /// fallback. Shared with the detail sheet via `VorsorgeCard.lastDoneDisplayText`.
    private var lastDoneText: String {
        VorsorgeCard.lastDoneDisplayText(lastSatisfiedAt: row.lastSatisfiedAt)
    }

    /// Course-end line, shown only when `endsOn` is set. Render verbatim.
    private var endsOnLine: String? {
        guard let ends = row.endsOn else { return nil }
        return String(
            format: String(localized: "reminders.endsOn.label"),
            HLDateFormat.date(ends, style: .abbreviated)
        )
    }
}

// MARK: - Type label resolver

/// Localized label for a server `MeasurementReminderType` (UPPER_SNAKE). The
/// raw optional token stays forward-compatible; known types resolve through the
/// catalog and unknown types fall back to user prose or localized generic copy.
enum MeasurementReminderType {
    /// Known catalog in create-sheet picker order (vitals first, then the
    /// body-composition family) → localization key. Driving the resolver off a
    /// table (not a `switch`) keeps the lookup flat and forward-compat: an
    /// unknown future wire value title-cases instead of rendering blank.
    private static let keysByWire: KeyValuePairs<String, String> = [
        "WEIGHT": "reminder.type.weight",
        "BLOOD_PRESSURE_SYS": "reminder.type.bloodPressure",
        "PULSE": "reminder.type.pulse",
        "BLOOD_GLUCOSE": "reminder.type.bloodGlucose",
        "OXYGEN_SATURATION": "reminder.type.oxygenSaturation",
        "BODY_TEMPERATURE": "reminder.type.bodyTemperature",
        "BODY_FAT": "reminder.type.bodyFat",
        "FAT_MASS": "reminder.type.fatMass",
        "FAT_FREE_MASS": "reminder.type.fatFreeMass",
        "MUSCLE_MASS": "reminder.type.muscleMass",
        "LEAN_BODY_MASS": "reminder.type.leanBodyMass",
        "BONE_MASS": "reminder.type.boneMass",
        "TOTAL_BODY_WATER": "reminder.type.totalBodyWater",
        "VISCERAL_FAT": "reminder.type.visceralFat",
        "BODY_MASS_INDEX": "reminder.type.bodyMassIndex",
        // #42 (v1.27.6) — mental-wellbeing screening reminders. The score is a
        // server-derived screening sum, not a hand-entered measurement; the
        // action routes to the check-in surface (see `isMentalHealthScreening`).
        "PHQ9_SCORE": "reminder.type.phq9Score",
        "GAD7_SCORE": "reminder.type.gad7Score",
        "WHO5_SCORE": "reminder.type.who5Score",
        "SCI_SCORE": "reminder.type.sciScore",
        "WAIST_CIRCUMFERENCE": "reminder.type.waistCircumference"
    ]

    /// Types a server reminder may target that the app shows but never offers
    /// in the create sheet: it cannot record them, and an older server would
    /// reject them. Kept apart from `keysByWire` because that table is `catalog`.
    private static let displayOnlyKeysByWire: [String: String] = [
        "BLOOD_KETONES": "reminder.type.bloodKetones"
    ]

    /// Server-derived mental-wellbeing score reminders route to the check-in,
    /// never to numeric manual entry. Raw tokens preserve forward compatibility
    /// with the DTO while this set names the four currently supported screeners.
    private static let mentalHealthScreeningWire: Set<String> = [
        "PHQ9_SCORE", "GAD7_SCORE", "WHO5_SCORE", "SCI_SCORE"
    ]

    /// Whether a raw type is one of the four derived screening scores.
    static func isMentalHealthScreening(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return mentalHealthScreeningWire.contains(raw)
    }

    static func label(for raw: String?, fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        if let key = keysByWire.first(where: { $0.key == raw })?.value ?? displayOnlyKeysByWire[raw] {
            return String(localized: String.LocalizationValue(key))
        }
        // Forward-compat for a server enum widening. The earlier
        // path title-cased the raw wire value ("SOME_NEW_TYPE" → "Some New
        // Type"), which renders an English-looking label to a German user (the
        // same English-title-casing W3 removed from the notification labels).
        // Instead prefer the user's own Bezeichnung, and only when there is none
        // fall back to a safe localized generic — never an English-cased wire
        // value.
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty { return trimmedFallback }
        return String(localized: "reminder.type.generic")
    }

    /// The known catalog, in the create-sheet picker order. Each entry is
    /// `(wireValue, localizedLabel)`.
    static var catalog: [(wire: String, label: String)] {
        keysByWire.map { (wire: $0.key, label: label(for: $0.key, fallback: $0.key)) }
    }
}
