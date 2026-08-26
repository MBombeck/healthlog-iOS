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
    /// v0.15 W-FRONTDOORS — the manage screen now reads the app-wide store
    /// (promoted to `AppContainer.measurementRemindersStore`) so it shares one
    /// SWR-deduped load with the Home Vorsorge tile. The previous view-local
    /// `@State` store double-fetched against the tile and never participated in
    /// the logout cascade.
    @Environment(MeasurementRemindersStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var showingCreate = false
    /// The reminder being edited, presented via `.sheet(item:)` in edit mode.
    @State private var editingReminder: MeasurementReminderRow?
    /// Parity 1.8a — the reminder pending deletion, gating the destructive
    /// action behind a confirm. Vorsorge was the last destructive surface that
    /// deleted straight out of the kebab; meds already confirm (archive dialog,
    /// container dialog) and web shows an `AlertDialog`
    /// (`vorsorge-section.tsx:950-969`).
    @State private var pendingDelete: MeasurementReminderRow?
    /// b244 — the reminder whose detail sheet is open (tap opens history + details).
    @State private var detailRow: MeasurementReminderRow?

    var body: some View {
        HLSettingsPage(title: "reminders.manage.title") {
            content(store: store)
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
        .navigationTitle("reminders.manage.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreate = true
                } label: {
                    Label("reminders.create.action", systemImage: "plus")
                }
                .accessibilityIdentifier("MeasurementRemindersScreen.create")
            }
        }
        .task { await store.load() }
        .refreshable { await store.load(force: true) }
        .sheet(isPresented: $showingCreate) {
            MeasurementReminderCreateSheet { body in
                await store.create(body)
            }
        }
        .sheet(item: $editingReminder) { row in
            MeasurementReminderCreateSheet(
                editing: row,
                onCreate: { _ in false },
                onUpdate: { id, patch in await store.update(id: id, patch: patch) }
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
        .hlConfirmDestructive(
            Text("reminders.delete.confirm.title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            message: Text("reminders.delete.confirm.body"),
            confirm: Text("reminders.action.delete"),
            cancel: Text("Cancel"),
            onCancel: { pendingDelete = nil },
            action: {
                if let row = pendingDelete {
                    pendingDelete = nil
                    Task { await store.delete(id: row.id) }
                }
            }
        )
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            ),
            presenting: store.error
        ) { _ in
            Button("OK") { store.error = nil }
        } message: { err in
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
            // F5 (b197) — the repetitive "due dates are server-computed" footer
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
                        // G2 — the tile needs the store for its own skip/snooze
                        // pair; the same store, the same methods and the same
                        // learned 404 gate the detail sheet uses.
                        store: store,
                        onMeasure: { kind in router.requestMeasure(prefill: kind) },
                        // #42 — a screening reminder (PHQ9/GAD7/WHO5) opens the
                        // mental-health check-in surface, not a numeric form.
                        onCheckIn: { router.requestMentalWellbeingCheckIn() },
                        onMarkDone: { Task { await store.complete(id: row.id) } },
                        onEdit: { editingReminder = row },
                        // Parity 1.8a — arm the confirm, never delete inline.
                        onDelete: { pendingDelete = row },
                        // b244 — the header/body tap opens the detail sheet.
                        onOpenDetail: { detailRow = row }
                    )
                }
            }
        }
    }

    private func emptyCard(loading: Bool) -> some View {
        HLSettingsCard(icon: "stethoscope", title: "reminders.list.title") {
            if loading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("reminders.empty.title")
                            .font(.hlHeadline)
                        Text("reminders.empty.subtitle")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(HLText.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("MeasurementRemindersScreen.empty")
            }
        }
    }
}

// MARK: - Card

/// One preventive-care reminder rendered as its own med-styled card — the iOS
/// mirror of the web `vorsorge-section.tsx` `VorsorgeCard` (v1.18.2):
///
/// - **Header:** the reminder name + the cadence chip ("Every N days" / Custom)
///   directly beside it, with a kebab (Edit / Delete) trailing.
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
    /// **G2** — the tile's own skip/snooze pair calls the store directly, the
    /// same way the detail sheet does. Handing the store down rather than four
    /// more closures keeps ONE implementation of the accepted cycle actions
    /// (`VorsorgeReminderLedgerActions`), which is the whole lesson of the
    /// mirrored-tile drift this plan closes.
    let store: MeasurementRemindersStore
    let onMeasure: (MetricKind) -> Void
    /// #42 — start the mental-health check-in (screening reminders).
    let onCheckIn: () -> Void
    let onMarkDone: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// b244 — the header/body tap opens the detail sheet (history + details),
    /// mirroring the mental-health card's `onOpenDetail`. Kebab + primary button
    /// stay their own targets.
    let onOpenDetail: () -> Void

    private var primaryAction: VorsorgeCard.PrimaryAction {
        VorsorgeCard.primaryAction(for: row)
    }

    var body: some View {
        // FW-VORSORGE (b210, corrected 2026-08-23) — the card mirrors
        // `MedicationCard`'s anatomy: the same `HLCard` chrome, the same
        // `HLSpace.md` inter-block rhythm, a `.hlTitle3` header, a monochrome
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
                // b244 — the meta + Next/Last + strip region is one tap target
                // that opens the detail sheet (like the mental-health card's
                // header tap). The kebab (in `header`) and the primary button
                // below stay separate 44-pt targets.
                Button(action: onOpenDetail) {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        metaRow
                        nextLastBlock
                        VorsorgeTrendStripView(measurementType: row.measurementType)
                        if let ends = endsOnLine {
                            Text(ends)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("vorsorge.card.openDetail.hint"))
                .accessibilityIdentifier("vorsorge.card.openDetail.\(row.id)")
                primaryButton
                // G2 — Überspringen and Snoozen at TILE level, not sheet-only.
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
        // QA-b198 Design-M4: the visible kebab Menu in `header` already exposes
        // Edit/Delete; a duplicate hidden `.contextMenu` with the identical
        // actions was redundant (two affordances for one thing) — dropped.
    }

    /// FW-VORSORGE — single-row header, mirroring `MedicationCard.header`: the
    /// title at `.hlTitle3` (one line, shrink-to-fit like the med name) with the
    /// trailing kebab. The type + cadence pills moved out to `metaRow` so they
    /// sit on their own line with the med card's category-pill placement.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            // b244 — the title is also a tap target for the detail sheet (like
            // the mental-health card's header text button).
            Button(action: onOpenDetail) {
                Text(headerTitle)
                    .font(.hlTitle3)
                    .foregroundStyle(row.enabled ? HLText.primary : HLText.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: HLSpace.sm)
            Menu {
                Button(action: onEdit) {
                    Label("reminders.action.edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("reminders.action.delete", systemImage: "trash")
                }
            } label: {
                // FW-VORSORGE (b215) — match `MedicationCard`'s header
                // `IconButton` exactly: the `.hlIcon(HLIconSize.rowAction)` glyph
                // (15pt) inside a full 44×44 HIG hit target, so the trailing
                // affordance carries the SAME weight + tap size as the med card's
                // history/edit icons instead of the prior undersized 16pt frame.
                Image(systemName: "ellipsis")
                    .font(.hlIcon(HLIconSize.rowAction))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("vorsorge.card.more"))
            .accessibilityIdentifier("vorsorge.card.kebab")
        }
    }

    /// FW-VORSORGE — meta pill row on its own line below the header, mirroring the
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
                until.formatted(.dateTime.day().month())
            ))
        }
        if VorsorgeCard.hasSkippedCurrentCycle(row) {
            metaPill(String(localized: "vorsorge.card.skippedCycle"))
        }
        if row.skipCount > 0 {
            metaPill(String(format: String(localized: "vorsorge.card.skipCount"), row.skipCount))
        }
    }

    /// Monochrome capsule identical to `MedicationCard.categoryPill` so the med
    /// + Vorsorge card families share one pill treatment.
    private func metaPill(_ text: String) -> some View {
        Text(text)
            .font(.hlCaption.weight(.semibold))
            .foregroundStyle(HLText.secondary)
            .padding(.horizontal, HLSpace.sm)
            .padding(.vertical, HLSpace.xs)
            .background(HLSurface.tertiary, in: Capsule())
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
        return MeasurementReminderType.label(for: row.measurementType, fallback: resolved)
    }

    /// Next-due (relative, calm wording) + last-done block — both render-only.
    ///
    /// FW-VORSORGE (b215) — the schedule block now mirrors `MedicationCard`'s
    /// `ScheduleLine` 1:1: an `HStack(spacing: HLSpace.sm)` per row, a `.hlSubhead`
    /// secondary label, and a `.hlSubhead` **`HLText.primary`** value that
    /// right-aligns. The last-done value was lifted from the quieter secondary
    /// tone to `HLText.primary` so it reads at the SAME weight as the med card's
    /// "Letzte Einnahme" value (the med card renders both schedule values in
    /// primary) — the parity the operator flagged as "colors feel off". "Nächster
    /// Termin" stays relative via `DueBucket`; "Zuletzt erledigt" is relative too
    /// ("heute"/"gestern", absolute fallback).
    private var nextLastBlock: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text("vorsorge.card.nextDue")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(dueText)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .multilineTextAlignment(.trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text("vorsorge.card.lastDone")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(lastDoneText)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .multilineTextAlignment(.trailing)
            }
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
    /// There is no mirror any more. `HLTileActionButton` is the one carrier
    /// R9/E2-A1 names, the medication tile renders from the same type, and
    /// `VorsorgeMedicationTileParityTests` fails — with the history in its
    /// message — if either surface leaves it alone.
    @ViewBuilder
    private var primaryButton: some View {
        switch primaryAction {
        case let .measure(kind):
            HLTileActionButton("vorsorge.card.measureNow", icon: "plus") {
                onMeasure(kind)
            }
            .accessibilityIdentifier("vorsorge.card.measureNow")
        case .checkIn:
            // #42 — screening reminder (PHQ9/GAD7/WHO5): the score is derived,
            // so the action starts the mental-health check-in rather than a
            // numeric capture form. Same button family as the others.
            HLTileActionButton("vorsorge.card.checkIn", icon: "brain.head.profile") {
                onCheckIn()
            }
            .accessibilityIdentifier("vorsorge.card.checkIn")
        case .markDone:
            HLTileActionButton("vorsorge.card.markDone", icon: "checkmark") {
                onMarkDone()
            }
            .accessibilityIdentifier("vorsorge.card.markDone")
        }
    }

    /// VR1 — the badge band below the header now only carries the Coach
    /// provenance pill and the disabled state. The generic "Vorsorge" pill was
    /// dropped (it was redundant on a screen that is already all Vorsorge); type
    /// + cadence moved into the header's row 2.
    private var hasStateBadges: Bool {
        row.origin == .coach || !row.enabled
            || VorsorgeCard.isSnoozed(row) || row.skipCount > 0
            || VorsorgeCard.hasSkippedCurrentCycle(row)
    }

    /// Provenance pill — Coach (suggestion) only. The generic Vorsorge pill was
    /// removed (VR1); `.vorsorge` / `.unknown` render nothing here.
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
            ends.formatted(.dateTime.day().month().year())
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
        if let key = keysByWire.first(where: { $0.key == raw })?.value {
            return String(localized: String.LocalizationValue(key))
        }
        // F3 (v0153) — forward-compat for a server enum widening. The earlier
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
