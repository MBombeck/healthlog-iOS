import Pow
import SwiftUI

// Existing medication-card implementation predates the repository's file
// split discipline. Task-scoped layout work stays in a private subview below.
// swiftlint:disable file_length

/// **Medication card — v0.6.1.2 Y4 redesign.**
///
/// Operator brief 2026-05-23: *"jedes Medikament als eigene Karte —
/// natürlich nicht in den Farben, aber der Aufbau, der ist eigentlich
/// ganz cool"*. Translates the web app's
/// `src/components/medications/medication-card.tsx` (the generic
/// Lisinopril card) and `glp1-medication-card.tsx` (the Trulicity
/// variant) into v0.6.1 monochrome, preserving block order, vocabulary,
/// and behaviour:
///
///     ┌──────────────────────────────────────────────────────────┐
///     │ Lisinopril 5 mg                            ↺   ✎          │ ← header
///     │ Bluthochdruck                                           │ ← category pill
///     │                                                          │
///     │ Letzter Termin   gestern, 08:00                          │ ← schedule (weekly→Termin, daily→Einnahme)
///     │ Nächster Termin  heute, 08:00                            │
///     │                                                          │
///     │ 7-Tage-Compliance                            86 %        │ ← compliance bars
///     │ ████████████████████░░░                                  │
///     │ 30-Tage-Compliance                           92 %        │
///     │ █████████████████████░░                                  │
///     │                                                          │
///     │ [ ✓ Genommen ]            [ ⏭ Übersprungen ]            │ ← inline actions (active rows only)
///     └──────────────────────────────────────────────────────────┘
///
/// Card body tap pushes the existing `MedicationDetailScreen`. The two
/// icon buttons (`clock.arrow.circlepath` for history, `pencil` for
/// edit) live in the header and own their own 44 pt hit targets so
/// they do not collide with the body tap.
///
/// **Compliance:** the bars show the server's rates verbatim
/// (`/api/medications/compliance`). Without a server answer the slot says
/// "adherence unknown"; the card never computes a rate itself.
struct MedicationCard: View {
    let medication: Medication
    let displayState: ActiveMedicationDisplayState
    let scheduleSummary: String
    /// `nil` while the server-canonical compliance
    /// fetch is pending: the card paints a redacted skeleton pair instead of
    /// a local interim value that would jump on server arrival.
    let compliance: MedicationsStore.ComplianceCardSnapshot?
    let lastTakenAt: Date?
    /// Tap on `clock.arrow.circlepath` icon in the header. Caller pushes
    /// the detail screen pre-scrolled to the Verlauf section.
    let onHistory: () -> Void
    /// Tap on the compliance value/bar. Caller pushes the
    /// detail screen, which surfaces the 90-day green/yellow/red adherence
    /// `VerlaufGlyphTrack` (taken / late / missed). Routed through the same
    /// `Medication`-value navigation as the card body + history icon so the
    /// compliance number becomes a faster shortcut to the adherence track.
    let onComplianceTap: () -> Void
    /// Tap on `pencil` icon in the header. Caller opens the
    /// `EditMedicationSheet`.
    let onEdit: () -> Void
    /// Tap on the Genommen primary CTA. Caller dispatches
    /// `MedicationsStore.markIntakeQuick` for the synth-placeholder.
    let onMarkTaken: () -> Void
    /// Tap on the Übersprungen secondary CTA.
    let onMarkSkipped: () -> Void
    /// Tap on archive context-menu item.
    let onArchive: () -> Void
    /// Context-menu „Ausblenden“: leaves the list on this device only.
    var onHide: () -> Void = {}
    /// Long-press on "Genommen" → "Mit abweichender Dosis
    /// erfassen…". The host opens the EXISTING free-intake dialog, preselected
    /// on this medication. Optional: a host that offers no such dialog passes
    /// nothing and the affordance does not render (the plain tap is unaffected
    /// either way).
    var onDeviatingDose: ((MedicationCardActions.DeviatingDose) -> Void)?
    /// **v0.8.2 W1b (audit B5).** `true` while a mark for this card's
    /// dose is awaiting its network round-trip. Disables the
    /// Genommen / Übersprungen pair so a rapid second tap can't fire a
    /// duplicate `recordFromReminder` (the store coalesces it anyway —
    /// this is the visible affordance that the tap registered).
    var isMarking: Bool = false
    /// Whether today's dose for this med is already logged as
    /// taken. Drives the discreet resting "done" state (thin completed border +
    /// dimmed action row) and arms the one-shot border-beam on the fresh
    /// taken-flip, replacing the prominent green-checkmark spray the operator
    /// disliked. Resolved by the section host from `todayIntakes`.
    var takenToday: Bool = false
    /// #191 — the end of the reminder snooze holding today's dose, from the
    /// today row (`status: "snoozed"`, `snoozedUntil`). Shown as "Reminder
    /// snoozed until 08:30" under the next dose.
    var snoozedUntil: Date?
    /// #190 (final) — the open dose's state on the server's clock (`dueAt`,
    /// `overdueSince`, `missedAfter` of today's row). `.some(nil)` means the
    /// server times the dose and nothing is due yet; `nil` means no row
    /// carries the instants, and the local window grading applies.
    var serverWindowStatus: MedicationWindowStatus??
    /// **1.7** — today's dose state is not confirmed yet (the store's hold,
    /// ``DoseStateConfirmation``): the card names the next time without a due
    /// or overdue pill, and its actions rest dimmed until the reload answers.
    var doseStateUnconfirmed: Bool = false
    /// **v0.14.1 INV-med-cadence-phantom (BUG 1)** — the server-profile IANA
    /// timezone the next-dose projection anchors on. Threaded from the section
    /// host (`store.profileTimeZone`) so the card's "nächste Einnahme/Termin"
    /// reads through the SAME `MedicationRecurrenceEngine` the detail screen +
    /// reminders use (which prefers the server `nextDueAt` for rolling/weekly
    /// single-slot cadences) instead of a local day-by-day projection that
    /// flattened a rolling med to "daily" → "morgen" instead of "+7 Tage".
    var profileTimeZone: TimeZone = .current
    /// The instant the card grades itself against. Defaulted to
    /// `.now`, threaded exactly like `profileTimeZone` above, so no production
    /// call site changes and the shipped behaviour is identical.
    ///
    /// It exists because `MedicationDueNowRenderTests` renders this REAL card
    /// and previously anchored its fixture on the live clock — which made the
    /// suite's verdict depend on the wall-clock minute it happened to run at,
    /// and made the day-boundary case (a dose window that runs past midnight)
    /// impossible to state at all. A render test that waits for an hour is not
    /// a test; with an injected instant the suite pins 23:55 and 00:35
    /// explicitly and gives the same answer at any time of day.
    var now: Date = .now
    /// Whether the action buttons should render. Web parity: the
    /// card only shows the Genommen / Übersprungen pair when the
    /// medication is `active`. Inactive (archived / paused) cards
    /// fade and drop the action surface.
    var isActionable: Bool {
        // A med mirrored from Apple Health is source-exclusive: its
        // doses come only from Apple Health, so the manual Genommen /
        // Übersprungen affordance is withheld (never double-count / recompute).
        medication.active && medication.allowsManualDoseLogging
    }

    /// What this card offers beyond its two CTAs.
    private var cardActions: MedicationCardActions {
        MedicationCardActions.resolve(medication: medication, now: now)
    }

    /// Pow micro-interaction triggers. Each counter
    /// drives a single `.changeEffect` / `.sensoryFeedback` pair on the
    /// matching action button. Local state so back-to-back taps still
    /// fire the effect even before the store roundtrip completes —
    /// mirrors the `tapPulse` pattern on `AskCoachHeroCard`.
    @State private var takenPulse: Int = 0
    @State private var skippedPulse: Int = 0

    /// One-shot border-beam trigger. Bumped on the
    /// pending→taken flip (and on the local Genommen tap) so the silver
    /// confirmation sweep replaces the green-checkmark spray.
    @State private var beamTrigger: Int = 0

    /// One-shot dark-orange border-beam trigger for
    /// "Überspringen" (same sweep as the silver taken-beam, `HLColor.skipBeam`).
    @State private var skipBeamTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // W-PERF-SWR (Med/High) — precompute the recurrence-engine results ONCE
        // per body pass. `windowStatus` (`MedicationWindowStatus.reduce`) was
        // evaluated up to 4× and `nextDoseDate` (`computeNextDose` → the
        // recurrence engine) was re-derived inside `scheduleBlock`; both are pure
        // functions of `medication`/`timeZone`/`now`, so resolving them up front
        // and threading them down removes the redundant per-pass recomputation.
        let status = windowStatus
        let nextDose = nextDoseDate
        return NavigationLink(value: medication) {
            // The card stands for one medication: its name in the object
            // name role, the same head as every other object card. Beside
            // the name the drawn check of today's dose, bound to the dose
            // the store holds as taken, never to the tap alone.
            HLCard(object: Text(titleLine)) {
                HLConfirmGlyph(isConfirmed: takenToday)
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLColor.statusOK)
            } content: {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    marks
                    categoryStatusRow(windowStatus: status)
                    scheduleBlock(windowStatus: status, nextDose: nextDose)
                    // The compliance slot keeps the card's anatomy:
                    //  • snapshot pending → redacted skeleton (2 reserved bars)
                    //  • scheduled / rolling med (rate present) → the 2 bars
                    //  • PRN / as-needed (no schedule → rate nil) → a quiet
                    //    "as needed" note in the SAME slot, so a PRN card and a
                    //    scheduled card do not differ structurally.
                    // A medication kept as a record shows no slot: its
                    // "Nur dokumentiert" mark and the "Nicht erfasst" schedule
                    // value already say there is no adherence. Without a server
                    // answer the slot is empty too; one line per card saying so
                    // repeated the same state down the whole list.
                    if !medication.tracksIntake || compliance?.notApplicableReason == .intakeNotTracked {
                        EmptyView()
                    } else if let compliance {
                        if compliance.rate30 != nil {
                            complianceBlock(compliance)
                        } else if !compliance.serverUnavailable {
                            complianceNote
                        }
                    } else {
                        // Server fetch pending → skeleton.
                        complianceSkeleton
                    }
                    if isActionable {
                        actionButtons
                            .padding(.top, HLSpace.xs)
                    }
                }
            }
            .contentShape(Rectangle())
            // The persistent silver "done" border was
            // removed: it was the operator's stray-white-frame bug. A borderless
            // `HLCard` is the canonical resting chrome for EVERY card regardless
            // of med type or taken-state, so a daily med logged today (Lisinopril)
            // and a weekly injectable still pending (Trulicity) read identical at
            // rest. "Done" stays signalled by the dimmed `cardOpacity` (0.82) plus
            // the one-shot taken beam below — no persistent frame on one card only.
            // One-shot border-beam confirmation sweep (silver = taken).
            .hlBorderBeam(trigger: beamTrigger, cornerRadius: HLRadius.card)
            // Dark-orange sweep for "Überspringen".
            .hlBorderBeam(trigger: skipBeamTrigger, cornerRadius: HLRadius.card, tint: HLColor.skipBeam)
            .opacity(cardOpacity)
        }
        .hlPressable() // Press feedback
        .onChange(of: takenToday) { wasTaken, isTaken in
            // Arm the beam on a fresh pending→taken flip (e.g. the dose was
            // marked from another surface and the list revalidated). The local
            // Genommen tap arms it directly in `actionButtons`.
            if isTaken, !wasTaken { beamTrigger &+= 1 }
        }
        .accessibilityIdentifier("medications.card.\(medication.id)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityCardLabel))
        .accessibilityHint(Text(String(localized: "medications.row.detail_hint")))
        .contextMenu {
            ForEach(cardActions.contextMenu, id: \.self) { item in
                contextMenuButton(item)
            }
        }
        // History and edit left the card head for the menu; VoiceOver keeps
        // them as named actions.
        .accessibilityAction(named: Text(String(localized: "med.card.action.history_a11y"))) { onHistory() }
        .accessibilityAction(named: Text(String(localized: "med.card.action.edit_a11y"))) { onEdit() }
    }

    /// Archived cards fade to 0.6 (unchanged); an active card whose
    /// dose is already taken dims a touch (0.82) so "done" reads as a quiet,
    /// settled state rather than a fresh actionable row.
    private var cardOpacity: Double {
        // Every ACTIVE med card renders at full opacity so a
        // taken-today card and a still-pending one read IDENTICALLY (operator:
        // the 0.82 taken-dim made the near-white dark-mode text look like a
        // different colour per card). "Taken" stays signalled by the one-shot
        // beam + the dimmed/disabled action row, not a persistent whole-card dim.
        // Only genuinely inactive (archived/paused) meds fade — a real state,
        // not a per-card style drift.
        medication.active ? 1 : 0.6
    }

    // MARK: - Marks

    /// The marks under the name: where the doses come from, why the card has
    /// no intake buttons, a course that ended or has not begun. History and
    /// edit live in the card's context menu, so the card corner carries no
    /// loose symbols (Z17).
    @ViewBuilder
    private var marks: some View {
        if medication.isAppleHealthMirrored || !medication.tracksIntake || MedicationCourseBadge.resolve(medication) != nil {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                // Provenance mark for an Apple-Health-mirrored med so
                // the user knows the doses (and the missing manual controls)
                // come from Apple Health.
                if medication.isAppleHealthMirrored {
                    AppleHealthProvenanceBadge()
                }
                // v1.39.1 — says why this card has no intake buttons,
                // no next dose and no adherence.
                if !medication.tracksIntake {
                    HLBadge(String(localized: "medications.recordOnly.badge"), icon: "doc.text")
                        .accessibilityIdentifier("medications.recordOnly.badge")
                }
                // v1.39.4 — an ended or not yet started course.
                if let course = MedicationCourseBadge.resolve(medication) { MedicationCourseStatusBadge(badge: course) }
            }
        }
    }

    /// `name + dose` line. Mirrors the web `MedicationCardHeader` —
    /// `{name} {dose}` rendered as one bold title. When the dose string
    /// is empty (mocks) we render the name on its own.
    private var titleLine: String {
        let dose = medication.dose.trimmingCharacters(in: .whitespacesAndNewlines)
        return dose.isEmpty ? medication.name : "\(medication.name) \(dose)"
    }

    // MARK: - Category pill

    private func categoryStatusRow(windowStatus: MedicationWindowStatus?) -> some View {
        MedicationCategoryStatusRow(categoryLabel: categoryLabel, windowStatus: windowStatus)
    }

    /// iOS port of the web `getMedicationCategoryLabel(category, t)` lookup.
    private var categoryLabel: String? {
        Self.categoryPillLabel(category: medication.category, label: medication.categoryLabel)
    }

    /// **The pill only when it tells something.** In a list of
    /// medications a pill reading "Medikament" (no category) or "Sonstige"
    /// (`OTHER`, the add form's default) said nothing on every card. A real
    /// kind (Nahrungsergänzung, Vitamin, Blutdruck, a custom category) keeps
    /// its pill. Shared with the detail hero.
    nonisolated static func categoryPillLabel(category: String?, label: String?) -> String? {
        guard let raw = category?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "OTHER" else { return nil }
        return localizedCategory(raw, label: label)
    }

    // MARK: - Schedule block

    /// Two-row schedule strip — label-left, value-right. Weekly meds
    /// (interval > 1 OR weekday set carries exactly one day) render
    /// `Letzter Termin` + `Nächster Termin`; daily-window meds render
    /// `Letzte Einnahme` + `Nächste Einnahme`. Mirrors the web
    /// `SchedulingSection`'s vocabulary exactly.
    /// W-PERF-SWR (Med/High) — `windowStatus` + `nextDose` are passed in
    /// (precomputed once in `body`) instead of being re-derived here, so the
    /// recurrence engine (`MedicationWindowStatus.reduce` / `computeNextDose`)
    /// runs at most once per body pass rather than per `ScheduleLine`.
    private func scheduleBlock(windowStatus: MedicationWindowStatus?, nextDose: Date?) -> some View {
        // What the strip SAYS is resolved by `MedicationCardSchedule`;
        // this method only paints it. The tint stays here.
        let strip = MedicationCardSchedule.resolve(
            medication: medication,
            lastTakenAt: lastTakenAt,
            scheduleSummary: scheduleSummary,
            windowStatus: windowStatus,
            nextDose: nextDose,
            now: now
        )
        return HLFactGroup {
            ScheduleLine(label: strip.last.label, value: strip.last.value)
            if let next = strip.next {
                ScheduleLine(
                    label: next.label,
                    value: next.value,
                    valueTint: Self.nextValueTint(windowStatus: windowStatus)
                )
            }
            if let snoozedUntil, snoozedUntil > now {
                Text(MedicationDoseWords.snoozedUntil(HLTimeFormat.time(snoozedUntil)))
                    .hlText(.note)
                    .accessibilityIdentifier("MedicationCard.snoozedUntil")
            }
        }
    }

    /// Single state→colour mapping for the
    /// "Nächster Termin / Nächste Einnahme" value, shared by every card so
    /// equivalent states render the SAME colour regardless of med type
    /// (weekly injectable vs daily oral). The med *cadence* only ever picks
    /// the row *label* (Termin vs Einnahme), never the colour. Only the
    /// due-now state lifts to `HLColor.statusOK` (web parity); every other
    /// state — including a still-pending future dose — stays `HLText.primary`.
    /// The overdue (.late/.veryLate) signal is carried by the separate status
    /// pill, not by tinting this value, so the schedule strip never diverges
    /// in colour between two cards in the same state.
    nonisolated static func nextValueTint(windowStatus: MedicationWindowStatus?) -> Color {
        windowStatus == .inWindow ? HLColor.statusOK : HLText.primary
    }

    /// **B11 (v0.10.0 Walkthrough-1)** — current-window dose status for the
    /// header pill. Display-only; computed in parallel to the forward-only
    /// next-dose projector (see `MedicationWindowStatus`). `nil` → no pill.
    ///
    /// **v1.16.4:** the server `nextDueOverdue` flag fills the
    /// gap the local window arithmetic cannot see (rolling/weekly meds whose
    /// open catch-up band spans days) — composed BEHIND the local reducer so
    /// today's finer in-window/late/very-late grading keeps priority.
    private var windowStatus: MedicationWindowStatus? {
        if doseStateUnconfirmed { return nil }
        if let serverWindowStatus { return serverWindowStatus }
        return Self.resolveWindowStatus(medication: medication, timeZone: profileTimeZone, now: now)
    }

    /// **The verdict reads the zone the next-dose line reads.** The
    /// window arithmetic used to run on the device zone while `nextDoseDate`
    /// projects in the account zone (`profileTimeZone`, the server's). Where
    /// the two differ (travel, an account zone set on the web) the card said
    /// "Jetzt fällig" at the device's 08:00 and, in the line below, named the
    /// account's 08:00 hours later. Pure and `nonisolated` for the tests.
    nonisolated static func resolveWindowStatus(
        medication: Medication,
        timeZone: TimeZone,
        now: Date
    ) -> MedicationWindowStatus? {
        MedicationWindowStatus.reduce(medication: medication, now: now, timeZone: timeZone)
            ?? MedicationWindowStatus.serverOverdueFallback(medication: medication, now: now)
    }

    // **One label set across cadences.** Every med reads
    // "Letzte Einnahme" / "Nächste Einnahme" (de) regardless of cadence; the
    // labels and both values now live in `MedicationCardSchedule`.

    /// Soonest future scheduled dose.
    ///
    /// **v0.14.1 INV-med-cadence-phantom (BUG 1).** Now routes through the
    /// authoritative `MedicationRecurrenceEngine` — the SAME source the detail
    /// screen + reminders use — instead of the old local day-by-day projection.
    /// The engine prefers the server-computed `medication.nextDueAt` for
    /// single-slot cadences (rolling / weekly-stride / monthly / yearly /
    /// cyclic), so a rolling/flexible GLP-1 med (Trulicity) shows its real next
    /// date (~+7 days) instead of being flattened to "morgen". Daily / weekday
    /// meds keep behaving as before (the engine projects the calendar grid).
    var nextDoseDate: Date? {
        Self.computeNextDose(
            medication: medication,
            timeZone: profileTimeZone,
            now: now
        )
    }

    /// Soonest occurrence strictly after `now` across every schedule entry,
    /// resolved by `MedicationRecurrenceEngine`. Pure + `nonisolated` so the
    /// contract tests can exercise it off the MainActor. Returns `nil` for PRN
    /// / terminated schedules (engine emits nothing) — the card then falls back
    /// to the `scheduleSummary` text.
    nonisolated static func computeNextDose(
        medication: Medication,
        timeZone: TimeZone,
        now: Date
    ) -> Date? {
        // v1.16.4 — server-flagged OPEN overdue slot: the
        // authoritative next-due instant lies in the PAST while the dose is
        // still takeable (catch-up band open, unresolved). Show THAT instant
        // instead of suppressing it / jumping to a locally-projected future
        // slot — the row pairs it with the "Überfällig" pill via
        // `MedicationWindowStatus.serverOverdueFallback`. The `due <= now`
        // guard routes a (clock-skewed) future instant through the normal
        // forward projection below.
        if medication.hasOpenOverdueDose, let due = medication.nextDueAt, due <= now {
            return due
        }
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        let entries = medication.schedule.entries
        guard !entries.isEmpty else {
            // No structured entries — fall back to the server-authoritative
            // next instant if the wire carried one.
            return medication.nextDueAt.flatMap { $0 > now ? $0 : nil }
        }
        let soonest = entries
            .compactMap { entry in
                MedicationRecurrenceEngine.nextOccurrence(
                    after: now,
                    entry: entry,
                    context: context
                )?.at
            }
            .min()
        // Last-resort fallback: if the engine projected nothing (e.g. a wire
        // shape it can't model) but the server told us a future next instant,
        // trust the server value.
        return soonest ?? medication.nextDueAt.flatMap { $0 > now ? $0 : nil }
    }

    // MARK: - Compliance block

    /// The compliance bars are wrapped in a single
    /// `Button` that pushes the detail screen's 90-day adherence track.
    /// The `Button` hops out of the card-body `NavigationLink` gesture via
    /// `.buttonStyle(.plain)` (same pattern as the header `IconButton`s),
    /// so the compliance number stays its own tap target.
    ///
    /// Dropped the trailing `chevron.right` glyph the
    /// operator read as visual noise. The bars themselves are the
    /// affordance; the whole block stays tappable via the wrapping
    /// `Button` + `.contentShape`, and the percentages now sit cleanly at
    /// the trailing edge with no stray disclosure spacing.
    private func complianceBlock(_ compliance: MedicationsStore.ComplianceCardSnapshot) -> some View {
        Button(action: onComplianceTap) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // The server's cadence-scaled `complianceDisplay`
                // windows, the server-supplied day count as the LABEL, the
                // server rate verbatim. One bar per card: the 30-day
                // window both cadences carry (`listRow`); the detail page this
                // block opens shows every window.
                if let row = compliance.listRow {
                    HLComplianceBar(
                        label: String(
                            format: String(localized: "med.card.compliance.window.label"),
                            row.days
                        ),
                        rate: row.rate
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
        .accessibilityElement(children: .contain)
        .accessibilityHint(Text(String(localized: "med.card.compliance.tap_hint")))
        .accessibilityIdentifier("medications.card.compliance.\(medication.id)")
    }

    /// Redacted placeholder painted while the
    /// server-canonical snapshot is in flight. Reserves the same vertical
    /// rhythm as the real `complianceBlock` (1.4 B4: one bar) so the card
    /// doesn't reflow when the value lands; never shows a number, so nothing
    /// can jump.
    private var complianceSkeleton: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLComplianceBar(
                label: String(
                    format: String(localized: "med.card.compliance.window.label"),
                    30
                ),
                rate: 0
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .accessibilityLabel(Text(String(localized: "med.compliance.loading")))
        .accessibilityIdentifier("medications.card.compliance.skeleton.\(medication.id)")
    }

    /// The compliance slot for a PRN / as-needed medication (no
    /// schedule → no compliance %). Renders in the SAME position + leading
    /// alignment as `complianceBlock` so a PRN card stays structurally identical
    /// to a scheduled card; it simply states "as needed" instead of two bars.
    /// Compliance has no meaning for an on-demand med, so this never shows a
    /// fabricated number. A file-scope subview (like `ScheduleLine`) so it keeps
    /// the card's type-body lean.
    private var complianceNote: some View {
        ComplianceSlotNote(medicationId: medication.id)
    }

    // MARK: - Action buttons

    /// **Pow micro-interactions.**
    /// - Genommen tap fires a green-checkmark spray + `.success` haptic;
    ///   the spray reads as a satisfying "done" beat without overpowering
    ///   the card chrome (Pow's `.spray` particles fade on their own).
    /// - Übersprungen tap fires a subtle `HLText.tertiary` glow + `.impact`
    ///   haptic — the ack is restrained because skipping is a neutral
    ///   action, not a celebration.
    /// - `reduceMotion` collapses the visual flourishes (Pow's
    ///   `isEnabled:` argument) while the haptic still fires so the
    ///   affordance keeps its tactile feedback.
    ///
    /// **Kill Übersprungen purple tint.**
    /// The Übersprungen affordance used `HLButton(.secondary)` which
    /// resolves its label foreground from the user's HLTint pick (default
    /// Dracula purple). On the active medication card that read as a full
    /// purple icon + text label, contradicting Y9.1's "Übersprungen is
    /// gracefully diminished, not a Coach surface" contract. The fix was an
    /// inline monochrome Button with the same chrome (44pt, hairline,
    /// `.hlSubhead`) but `HLText.secondary` ink.
    ///
    /// **That inline button is now `HLTileActionButton`.**
    /// Y9.3's three values did not change; their HOME did. This card was the
    /// reference instance of a shape that a second surface (the Vorsorge tile)
    /// carried as a copy, and a copy is what let `d06174e6` move one of them and
    /// leave the other claiming parity. R9/E2-A1 names one carrier; both tiles
    /// render from it; `VorsorgeMedicationTileParityTests` says so out loud if
    /// that ever stops being true.
    ///
    /// **Side by side while both labels fit their half, stacked when not.**
    /// H2 photographed „Übersprun-gen" on the iPhone SE and „Ge-nom-men" over
    /// three lines at AX-XXL. ``HLTileActionRow`` keeps the equal-width row
    /// wherever the longer label fits its half — every large device at the
    /// default size — and stacks the pair full-width otherwise.
    private var actionButtons: some View {
        HLTileActions(Self.offersSkip(medication) ? [takeItem, skipItem] : [takeItem], spacing: HLSpace.sm)
            .sensoryFeedback(.success, trigger: takenPulse)
            .sensoryFeedback(.impact(weight: .light), trigger: skippedPulse)
            .sensoryFeedback(.selection, trigger: skippedPulse)
            // Additive: a long-press (and, for VoiceOver, a rotor action) on the
            // quick actions offers the deviating dose. The plain taps are
            // untouched; the row builds its buttons itself, so the menu hangs on
            // the row.
            .modifier(DeviatingDoseAffordance(
                target: cardActions.deviatingDose,
                onSelect: onDeviatingDose
            ))
            // Freeze the action pair while the mark is in
            // flight so a rapid second tap is visibly inert.
            .disabled(isMarking || doseStateUnconfirmed)
            .opacity(isMarking || doseStateUnconfirmed ? 0.5 : 1)
    }

    /// #191 point 4: a dose can be skipped only where there are dose times;
    /// an as-needed medication has no dose to skip.
    nonisolated static func offersSkip(_ medication: Medication) -> Bool {
        !medication.asNeeded
    }

    private var takeItem: HLTileAction.Item {
        HLTileAction.Item("med.dose.action.take", icon: "checkmark") {
            takenPulse &+= 1
            // Fire the monochrome border-beam sweep instead of
            // the green-checkmark spray. The beam confirms "taken" as
            // Liquid-Glass chrome light, then settles into the discreet
            // resting border once the store flips `takenToday`.
            beamTrigger &+= 1
            onMarkTaken()
        }
    }

    private var skipItem: HLTileAction.Item {
        HLTileAction.Item("med.dose.action.skip", icon: "forward.end") {
            skippedPulse &+= 1
            // Fire the dark-orange border-beam sweep so a
            // skip reads as a deliberate, distinct signal (same sweep as the
            // silver taken-beam, tinted HLColor.skipBeam).
            skipBeamTrigger &+= 1
            onMarkSkipped()
        }
    }

    // The inline `monochromeActionButton` that used to live here is
    // gone. It was the medication half of a MIRRORED pair: b210 judged
    // `MedicationCard` not reusable and copied its shape onto the Vorsorge tile,
    // which is the channel `d06174e6` came down three weeks later, changing one
    // copy and leaving the other claiming parity. Both tiles now render from
    // `HLTileActionButton`, the single carrier R9/E2-A1 names, so there is no
    // longer a second copy to change. The `.sensoryFeedback` modifiers stay
    // at the `actionButtons` call site.

    // MARK: - Accessibility

    private var accessibilityCardLabel: String {
        var parts: [String] = [
            titleLine,
            MedicationCategoryStatusRow.accessibilityCategoryStatusLabel(
                category: categoryLabel,
                windowStatus: windowStatus
            )
        ]
        if !medication.tracksIntake { parts.append(String(localized: "medications.recordOnly.badge")) }
        if let course = MedicationCourseBadge.resolve(medication) { parts.append(course.title) }
        if !scheduleSummary.isEmpty { parts.append(scheduleSummary) }
        if medication.tracksIntake, let listRow = compliance?.listRow {
            parts.append(
                String(
                    format: String(localized: "med.card.compliance.a11y"),
                    String(format: String(localized: "med.card.compliance.window.label"), listRow.days),
                    listRow.rate
                )
            )
        }
        if let chip = displayState.badgeTitle { parts.append(chip) }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    // MARK: - Static helpers

    /// Relative date+time formatter — "heute, 08:00" / "gestern, 08:00" /
    /// "Mi., 24. Mai, 08:00". Mirrors the web `formatLastTakenAt`
    /// today/yesterday bucketing.
    nonisolated static func relativeDateTime(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        // Honour the user's time-format preference (auto / 24h / 12h)
        // for the clock portion. Routes through the central `HLTimeFormat`
        // helper so every med-time clock reads the same way.
        let time = HLTimeFormat.time(date)
        if day == today {
            return String(format: "%@, %@", String(localized: "medications.today"), time)
        }
        if day == yesterday {
            return String(format: "%@, %@", String(localized: "medications.yesterday"), time)
        }
        if day == tomorrow {
            return String(format: "%@, %@", String(localized: "medications.tomorrow"), time)
        }
        let dateLabel = HLDateFormat.appendingYearIfNeeded(
            date,
            base: Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        )
        return "\(dateLabel), \(time)"
    }

    nonisolated static let categoryStringKeys: [String: String.LocalizationValue] = [
        "BLOOD_PRESSURE": "medications.categoryBloodPressure",
        "VITAMIN": "medications.categoryVitamin",
        "SUPPLEMENT": "medications.categorySupplement",
        "PAIN_RELIEF": "medications.categoryPainRelief",
        "ALLERGY": "medications.categoryAllergy",
        "DIGESTIVE": "medications.categoryDigestive",
        "THYROID": "medications.categoryThyroid",
        "HORMONE": "medications.categoryHormone",
        "SKIN": "medications.categorySkin",
        "SLEEP_AID": "medications.categorySleepAid",
        "DIABETES": "medications.categoryDiabetes",
        "ANTIBIOTIC": "medications.categoryAntibiotic",
        "MENTAL_HEALTH": "medications.categoryMentalHealth",
        "OTHER": "medications.categoryOther"
    ]

    /// v1.40: a custom category (`custom:<uuid>`)
    /// reads as its server label (`categoryLabel`), never as the raw key.
    nonisolated static func localizedCategory(_ raw: String, label: String?) -> String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if raw.hasPrefix("custom:") {
            return String(localized: "medications.categoryCustom")
        }
        return localizedCategory(raw)
    }

    nonisolated static func localizedCategory(_ raw: String) -> String {
        if let key = categoryStringKeys[raw] {
            // String.LocalizationValue routes through the xcstrings catalog.
            return String(localized: key)
        }
        // Unknown / new server category — surface the raw token so the
        // operator can still read it; missing-key noise will be picked up
        // by the next localization pass.
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - As-needed compliance note subview

/// The PRN/as-needed card's compliance-slot content. A file-scope
/// view (mirroring `ScheduleLine`) so a PRN card occupies the SAME compliance
/// slot a scheduled card does, keeping the two cards structurally identical.
struct ComplianceSlotNote: View {
    let medicationId: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Image(systemName: "hand.tap")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text("med.card.compliance.as_needed")
                .hlText(.factLabel)
            Spacer(minLength: HLSpace.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("medications.card.compliance.asneeded.\(medicationId)")
    }
}

// MARK: - Category/status row

/// Category and overdue state stay adjacent at regular sizes. Accessibility
/// sizes fall back to a vertical wrap without truncating either capsule; the
/// outer card announces the same category-before-status order as one label.
private struct MedicationCategoryStatusRow: View {
    /// `nil` when the category says nothing; the row then shows only
    /// an overdue state, or is absent.
    let categoryLabel: String?
    let windowStatus: MedicationWindowStatus?

    private var overdue: MedicationWindowStatus? {
        windowStatus == .inWindow ? nil : windowStatus
    }

    var body: some View {
        if categoryLabel != nil || overdue != nil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                    categoryPill
                    if let overdue { MedicationStatusPill(status: overdue) }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    categoryPill
                    if let overdue { MedicationStatusPill(status: overdue) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.accessibilityCategoryStatusLabel(
                category: categoryLabel,
                windowStatus: windowStatus
            )))
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var categoryPill: some View {
        if let categoryLabel {
            HLBadge(categoryLabel)
        }
    }

    static func accessibilityCategoryStatusLabel(
        category: String?,
        windowStatus: MedicationWindowStatus?
    ) -> String {
        let status: String? = switch windowStatus {
        case .late, .veryLate: MedicationDosePhase.overdue.title
        case .inWindow, nil: nil
        }
        return [category, status].compactMap(\.self).joined(separator: ". ")
    }
}

// MARK: - Schedule line subview

private struct ScheduleLine: View {
    let label: String
    let value: String
    /// The due-now "Jetzt fällig" value renders in HLColor.statusOK
    /// (green, web parity). Every other schedule value stays HLText.primary.
    var valueTint: Color = HLText.primary

    /// The shared fact pair: label left, value right, stacked at the
    /// accessibility sizes so the time of the dose is never cut.
    var body: some View {
        HLFactRow(label: Text(label), value: Text(value).foregroundStyle(valueTint))
            .accessibilityLabel(Text("\(label): \(value)"))
    }
}

// MARK: - Window-status pill subview

/// **B11 (v0.10.0 Walkthrough-1).** Monochrome-surface pill that surfaces a
/// due-now / overdue dose on the medication card, mirroring the web's
/// `MedicationStatusPill`. Color appears ONLY on the glyph + label as the
/// status signal (handbook §1.2: an overdue dose is a legitimate signal):
///
/// Words and glyphs follow the term list (#191, ``MedicationDoseLook``):
/// - `.inWindow` → "Fällig" with the clock, neutral (the dose is on time).
/// - `.late` → "Überfällig" with the alert glyph, amber.
/// - `.veryLate` → "Überfällig" with the triangle, red (late in its window).
///
/// The capsule fill stays a recessed mono well (`HLSurface.tertiary`) so the
/// card surface itself never colours; only the pill carries the signal.
private struct MedicationStatusPill: View {
    let status: MedicationWindowStatus

    var body: some View {
        let look = Self.look(for: status)
        HLBadge(look.title, icon: look.glyph.systemName, tone: Self.tone(look.tone))
            .accessibilityAddTraits(status == .inWindow ? [] : .isHeader)
    }

    static func look(for status: MedicationWindowStatus) -> MedicationDoseLook {
        switch status {
        case .inWindow: MedicationDoseLook(phase: .due)
        case .late: MedicationDoseLook(phase: .overdue)
        case .veryLate: MedicationDoseLook(phase: .overdue, lateInWindow: true)
        }
    }

    static func tone(_ tone: MedicationDoseTone) -> HLBadge.Tone {
        switch tone {
        case .warning, .late: .warning
        case .critical: .critical
        case .quiet, .due, .success, .muted: .neutral
        }
    }
}

// MARK: - Header icon button

/// Surfaces the lifecycle-state badge on the active-meds row.
///
/// The data model (`Medication.active: Bool`) currently only
/// distinguishes Aktiv vs. archived; the section host already filters
/// archived rows out before passing to this row, so production today
/// only emits `.aktiv`. The `.pausiert` / `.beendet` cases stay
/// expressed in the enum so the badge surface is ready when the server
/// schema grows a richer lifecycle state, and so the brief's
/// "state chip only for non-Aktiv" rule has a stable contract callers
/// can unit-test against.
public enum ActiveMedicationDisplayState: Equatable, Sendable {
    case aktiv
    case pausiert
    case beendet

    /// Maps from the `Medication.active` flag. Kept as a separate
    /// derivation so the row component stays presentation-only and the
    /// future expansion to richer lifecycle data has a single switching
    /// point.
    public static func from(medication: Medication) -> ActiveMedicationDisplayState {
        medication.active ? .aktiv : .beendet
    }

    /// `nil` for `.aktiv` (implicit), localised label otherwise.
    /// Consumers render via `HLBadge(_, tone: .neutral)`.
    public var badgeTitle: String? {
        switch self {
        case .aktiv: nil
        case .pausiert: String(localized: "medications.row.state.paused")
        case .beendet: String(localized: "medications.row.state.ended")
        }
    }
}

// Active-medications section host.
//
// Operator brief 2026-05-23 — *"jedes Medikament als
// eigene Karte"*. The section drops its prior free-floating row +
// divider rhythm and stacks one `MedicationCard`
// per active medication, separated by `HLSpace.md` vertical breathing
// room. Each card carries the full anatomy the web app's
// `MedicationCard` paints — header, category pill, schedule strip,
// compliance bars, inline action buttons. The host owns the data

// MARK: - The card's schedule strip, resolved

/// **The two lines of a medication card's schedule strip, as values.**
///
/// Lifted out of `MedicationCard.scheduleBlock` / `lastValue` / `nextValue`
/// so what a card SAYS about its past and its future can be read
/// without a view host. Behaviour is verbatim for scheduled medications: same
/// labels, same relative formatting, same "Jetzt fällig" for an open window,
/// same `scheduleSummary` fallback when the engine projects nothing.
///
/// The tint is deliberately NOT here — `MedicationCard.nextValueTint` stays the
/// single state→colour mapping.
struct MedicationCardSchedule: Equatable {
    struct Line: Equatable {
        let label: String
        let value: String
    }

    /// "Letzte Einnahme" — always present.
    let last: Line
    /// "Nächste Einnahme" — `nil` when the medication has no next intake to
    /// speak of.
    let next: Line?

    static func resolve(
        medication: Medication,
        lastTakenAt: Date?,
        scheduleSummary: String,
        windowStatus: MedicationWindowStatus?,
        nextDose: Date?,
        now: Date
    ) -> MedicationCardSchedule {
        // PRN is the medication-level `asNeeded` flag (the 09-14
        // spelling), never a guess from schedule shapes.
        let isAsNeeded = medication.asNeeded
        return MedicationCardSchedule(
            last: Line(
                label: String(localized: "med.card.schedule.daily.last.label"),
                value: lastValue(lastTakenAt: lastTakenAt, isAsNeeded: isAsNeeded, now: now)
            ),
            // B4, the operator's own rule: a next intake is meaningless for an
            // as-needed medication, so the card does not claim one. v1.39.1
            // (#1033): nothing is due on a record either, and 1.4 B2 lets the
            // "Nur dokumentiert" badge say so instead of a second line that
            // repeated it. Every scheduled medication keeps its line.
            next: isAsNeeded || !medication.tracksIntake ? nil : Line(
                label: String(localized: "med.card.schedule.daily.next.label"),
                value: nextValue(
                    windowStatus: windowStatus,
                    nextDose: nextDose,
                    scheduleSummary: scheduleSummary,
                    now: now
                )
            )
        )
    }

    private static func lastValue(lastTakenAt: Date?, isAsNeeded: Bool, now: Date) -> String {
        guard let last = lastTakenAt else {
            // On a scheduled card the em-dash reads "not yet, the plan
            // says when". A PRN card has no plan to fall back on: its last
            // intake is the whole record, so an absent one is stated.
            return String(localized: isAsNeeded
                ? "med.card.schedule.last.none"
                : "med.card.schedule.value.unset")
        }
        return MedicationCard.relativeDateTime(last, now: now)
    }

    private static func nextValue(
        windowStatus: MedicationWindowStatus?,
        nextDose: Date?,
        scheduleSummary: String,
        now: Date
    ) -> String {
        // A dose that is due now reads "Fällig" (#191) instead of a
        // time, and the separate due-now pill is dropped.
        if windowStatus == .inWindow {
            return MedicationDosePhase.due.title
        }
        guard let next = nextDose else {
            return scheduleSummary.isEmpty
                ? String(localized: "med.card.schedule.value.unset")
                : scheduleSummary
        }
        return MedicationCard.relativeDateTime(next, now: now)
    }
}

// MARK: - Card menu

private extension MedicationCard {
    @ViewBuilder
    func contextMenuButton(_ item: MedicationCardActions.ContextMenuItem) -> some View {
        switch item {
        case .history:
            Button(action: onHistory) {
                Label(String(localized: "med.card.action.history_a11y"), systemImage: "clock.arrow.circlepath")
            }
        case .edit:
            Button(action: onEdit) {
                Label(String(localized: "medications.row.action.edit"), systemImage: "pencil")
            }
        case .hide:
            Button(action: onHide) {
                Label(String(localized: "medications.row.action.hide"), systemImage: "eye.slash")
            }
        case .archive:
            Button(role: .destructive, action: onArchive) {
                Label(String(localized: "medications.row.action.archive"), systemImage: "archivebox")
            }
        }
    }
}

// MARK: - The fast path's second gesture

/// **What a medication card offers beyond its two CTAs.**
///
/// Lifted out of the card so the answer can be read without a view
/// host. The context menu holds Verlauf, Bearbeiten, Ausblenden and Archivieren in that
/// order; the operator's E3 decision is that the deviating dose does NOT join
/// them: it belongs on the CTA's long-press, where the hand already is.
struct MedicationCardActions: Equatable {
    /// The card's long-press context menu, in the order it shows.
    enum ContextMenuItem: String, Equatable {
        /// Opens the medication's intake history.
        case history
        case edit
        /// Leaves the list on this device; the medication keeps running.
        case hide
        case archive
    }

    /// What "Mit abweichender Dosis erfassen…" opens: the EXISTING free-intake
    /// dialog ("Manuell nachtragen"), preselected on this medication at this
    /// instant, with its dose field editable.
    struct DeviatingDose: Equatable {
        let medicationID: String
        let takenAt: Date
    }

    /// `nil` when the card offers no deviating-dose entry point.
    let deviatingDose: DeviatingDose?
    let contextMenu: [ContextMenuItem]

    static func resolve(medication: Medication, now: Date) -> MedicationCardActions {
        // The same predicate the card's own `isActionable` uses: an archived
        // medication has no CTA to long-press, and an Apple-Health-mirrored one
        // is source-exclusive — its doses come from Apple Health and
        // are never entered by hand, deviating or not.
        let canLogByHand = medication.active && medication.allowsManualDoseLogging
        return MedicationCardActions(
            deviatingDose: canLogByHand
                ? DeviatingDose(medicationID: medication.id, takenAt: now)
                : nil,
            contextMenu: [.history, .edit, .hide, .archive]
        )
    }
}

/// Attaches the deviating-dose affordance to the Genommen CTA — and attaches
/// NOTHING when there is none, so a card without the entry point keeps a bare
/// button rather than an empty long-press menu (the "empty long-press feels
/// broken" note in `IntakeHistoryRow`).
private struct DeviatingDoseAffordance: ViewModifier {
    let target: MedicationCardActions.DeviatingDose?
    let onSelect: ((MedicationCardActions.DeviatingDose) -> Void)?

    func body(content: Content) -> some View {
        if let target, let onSelect {
            content
                .contextMenu {
                    Button {
                        onSelect(target)
                    } label: {
                        Label(
                            String(localized: "med.card.action.deviating_dose"),
                            systemImage: "square.and.pencil"
                        )
                    }
                }
                // Long-press has no VoiceOver equivalent by default.
                .accessibilityAction(named: Text(String(localized: "med.card.action.deviating_dose"))) {
                    onSelect(target)
                }
        } else {
            content
        }
    }
}
