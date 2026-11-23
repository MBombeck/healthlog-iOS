import SwiftUI

/// Ausgelagert aus ActiveMedicationRow.swift (file_length, reine Verschiebung — b177 QA-FINAL).
/// hand-off from `MedicationsStore` to per-card props.
///
/// **The card stack is the whole of this section.** 08-05 collapsed
/// `MedicationListView` to one case and left the compact alternate row and the
/// inert `view:` parameter behind, because a frozen Phase-06 presentation row
/// pinned the unmounted branch in source. That row is now dispositioned
/// `DELETED_BY_LATER_PHASE` under this plan, so the branch, its dense row file
/// and the parameter that used to choose between them are gone rather than
/// merely unreachable.
struct ActiveMedicationsSection: View {
    let medications: [Medication]
    /// Kept on the section signature so the
    /// hosting screen does not have to break the call-site contract
    /// while the per-row quick-mark drops; the value is no longer
    /// rendered by the row. The detail-screen "Heute" sub-section is
    /// now the canonical take-action surface for a medication.
    let todayIntakes: [MedicationIntake]
    let onEdit: (Medication) -> Void
    let onArchive: (Medication) -> Void
    /// Context-menu „Ausblenden“. The host takes the card out of this list.
    var onHide: (Medication) -> Void = { _ in }
    /// How many active medications are hidden on this device. With every
    /// active one hidden the section steps aside instead of claiming there
    /// are none.
    var hiddenCount: Int = 0
    /// Mark-action plumbing from the parent screen. Receives the
    /// synth-placeholder intake id (or the server-created intake id
    /// when one already exists for today's slot) along with the
    /// desired status. Mirrors the existing
    /// `MedicationsStore.markIntakeQuick` contract so the card stack
    /// keeps web parity on the bulk-intake POST path.
    ///
    /// The `Medication` rides along so the host can gate
    /// the injection-site capture interstitial on
    /// `medication.injectionSiteCaptureEnabled` before firing the mark.
    let onMark: (_ intakeId: String, _ status: IntakeStatus, _ medication: Medication) -> Void
    /// Mark-action fallback for medications without a today-intake
    /// row (PRN / off-day weekly). Receives the medication +
    /// status; the parent translates to a synth-placeholder POST.
    let onMarkAdHoc: (_ medication: Medication, _ status: IntakeStatus) -> Void
    /// History tap target — pushes the detail screen scrolled to the
    /// Verlauf section. Parent forwards through the navigation stack.
    let onHistory: (Medication) -> Void
    /// Compliance-value tap target. Pushes the detail
    /// screen, where the 90-day green/yellow/red adherence track lives.
    /// Parent forwards through the same `Medication`-value navigation.
    let onComplianceTap: (Medication) -> Void
    /// Long-press on a card's Genommen CTA. The host opens the
    /// existing free-intake dialog, preselected on this medication.
    let onDeviatingDose: (MedicationCardActions.DeviatingDose) -> Void
    /// #186 — the dose a reminder tap is about. Its card, and every card
    /// with a dose in the same slot, is marked and scrolled to.
    var landing: MedicationReminderLanding?

    /// The store carries the per-medication
    /// server-canonical compliance cache. Read via
    /// `cardComplianceSnapshot(for:)`, which returns the cached server value,
    /// or "unknown" once the fetch failed — never a device-computed rate.
    @Environment(MedicationsStore.self) private var store

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the section shows for the visible and hidden active medications.
    enum Content: Equatable {
        case cards
        /// No active medication at all: the empty state with its add button.
        case empty
        /// Every active medication is hidden: nothing here, „Ausgeblendet“
        /// below carries them.
        case omitted
    }

    nonisolated static func content(visibleCount: Int, hiddenCount: Int) -> Content {
        if visibleCount > 0 { return .cards }
        return hiddenCount > 0 ? .omitted : .empty
    }

    var body: some View {
        switch Self.content(visibleCount: medications.count, hiddenCount: hiddenCount) {
        case .omitted:
            EmptyView()
        case .empty:
            HLSectionHeader("medications.section.active.title")
            // Only archived medications exist here; the title carries the
            // state, and the plus in the tab header adds one (M2).
            HLEmptyState(icon: "pills", title: "medications.section.active.empty.title")
        case .cards:
            HLSectionHeader("medications.section.active.title")
            let marked = markedIDs
            LazyVStack(spacing: HLLayout.cardGap) {
                ForEach(medications, id: \.id) { med in
                    MedicationCard(
                        medication: med,
                        displayState: .from(medication: med),
                        // v1.39.1 — a record shows its stored schedule as information.
                        scheduleSummary: Self.scheduleSummary(med.displaySchedule),
                        // The server-canonical snapshot
                        // cached on the store; skeleton while pending,
                        // "unknown" when the fetch failed.
                        compliance: store.cardComplianceSnapshot(for: med),
                        lastTakenAt: med.lastTakenAt,
                        onHistory: { onHistory(med) },
                        onComplianceTap: { onComplianceTap(med) },
                        onEdit: { onEdit(med) },
                        onMarkTaken: { dispatchMark(med: med, status: .taken) },
                        onMarkSkipped: { dispatchMark(med: med, status: .skipped) },
                        onArchive: { onArchive(med) },
                        onHide: { onHide(med) },
                        onDeviatingDose: onDeviatingDose,
                        isMarking: isMarking(med: med),
                        takenToday: isTakenToday(med: med),
                        snoozedUntil: Self.snoozedUntil(medicationId: med.id, todayIntakes: todayIntakes),
                        serverWindowStatus: Self.serverWindowStatus(
                            medicationId: med.id,
                            todayIntakes: todayIntakes,
                            now: .now
                        ),
                        // 1.7: neutral until the store confirms today's doses.
                        doseStateUnconfirmed: store.isDoseStateUnconfirmed,
                        // v0.14.1 INV-med-cadence-phantom (BUG 1) — anchor the
                        // card's next-dose projection on the server-profile
                        // zone so it matches the detail screen + reminders.
                        profileTimeZone: store.profileTimeZone
                    )
                    // Subtle skid-in on mount /
                    // insert so the card-stack reads as "settling
                    // into place" rather than popping in flat. Pow's
                    // `.movingParts.skid` is an elastic slide from
                    // the leading edge; restrained enough that it
                    // doesn't compete with the per-tile content.
                    // Reduce-motion users get the default
                    // opacity-fade transition instead via the
                    // accessibility-driven `transition` branch.
                    .transition(reduceMotion ? .opacity : .movingParts.skid)
                    .hlCardMark(marked.contains(med.id))
                }
            }
            // Bind the LazyVStack to the medication-id list so the
            // ForEach diff drives the transition cleanly on insertion
            // (new med added) and reorder (archive removes a card).
            .hlAnimation(.smooth(duration: 0.3), value: medications.map(\.id))
            // #186 — the topmost marked card scrolls into view once the list
            // holds it.
            .modifier(MedicationLandingScroll(cardID: marked.first, sequence: landing?.sequence))
        }
    }

    /// The cards the current reminder landing marks, topmost first.
    private var markedIDs: [String] {
        guard let landing else { return [] }
        return MedicationReminderLanding.markedIDs(
            medicationId: landing.medicationId,
            slot: landing.slot,
            todayIntakes: todayIntakes,
            visibleOrder: medications.map(\.id),
            now: .now
        )
    }

    /// **v0.8.2 W1b (audit B5).** `true` while the resolved pending
    /// today-intake for `med` is mid-mark. Only the materialised /
    /// synth-placeholder dose carries a stable id the store can track;
    /// an ad-hoc PRN mark (no pending row) generates its id at tap-time,
    /// so its in-flight window is too brief to reflect here — the
    /// store-level guard still coalesces those, this is only the visible
    /// disable for the resolvable dose.
    /// Today's dose for `med` is logged as taken. Reuses the
    /// canonical `MedicationQuickMarkState.resolve` so the card's resting
    /// "done" state agrees with the same source of truth the quick-mark uses.
    /// The card's check only once every dose of today is settled, so it
    /// never stands beside "Jetzt fällig" for the evening dose.
    private func isTakenToday(med: Medication) -> Bool {
        MedicationDueRule.allDosesSettled(medicationId: med.id, todayIntakes: todayIntakes)
    }

    /// #191 — the snooze holding one of today's doses of the medication,
    /// as the today rows say it (`status: "snoozed"` with `snoozedUntil`).
    nonisolated static func snoozedUntil(medicationId: String, todayIntakes: [MedicationIntake]) -> Date? {
        todayIntakes
            .filter { $0.medicationId == medicationId && $0.status == .snoozed }
            .compactMap(\.snoozedUntil)
            .max()
    }

    /// #190 (final) — the card's pill from the server's three instants of
    /// the earliest open dose today: due from `dueAt`, overdue from
    /// `overdueSince`, missed (the triangle) from `missedAfter`. `nil` when
    /// no open row carries them (an older server, or the capability shut).
    nonisolated static func serverWindowStatus(
        medicationId: String,
        todayIntakes: [MedicationIntake],
        now: Date,
        enabled: Bool = MedicationServerResolvedSlots.isAvailable()
    ) -> MedicationWindowStatus?? {
        guard enabled else { return nil }
        let timed = todayIntakes
            .filter { $0.medicationId == medicationId && ($0.status == .pending || $0.status == .snoozed) }
            .compactMap { intake in intake.doseState?.phase(at: now).map { (intake.scheduledAt, $0) } }
            .sorted { $0.0 < $1.0 }
        guard !timed.isEmpty else { return nil }
        let phases = timed.map(\.1)
        if phases.contains(.missed) { return .some(.veryLate) }
        if phases.contains(.overdue) { return .some(.late) }
        if phases.contains(.due) { return .some(.inWindow) }
        return .some(nil)
    }

    private func isMarking(med: Medication) -> Bool {
        guard let pending = todayIntakes
            .filter({ $0.medicationId == med.id && $0.status == .pending })
            .min(by: { $0.scheduledAt < $1.scheduledAt }) else { return false }
        return store.isMarking(intakeId: pending.id)
    }

    private func dispatchMark(med: Medication, status: IntakeStatus) {
        if let pending = Self.resolveDispatchDose(
            medicationId: med.id,
            todayIntakes: todayIntakes,
            now: .now
        ) {
            onMark(pending.id, status, med)
        } else {
            onMarkAdHoc(med, status)
        }
    }

    /// Pick which pending today-dose a Genommen /
    /// Übersprungen tap records. Weekly meds have one pending slot (Trulicity
    /// logged fine); a daily multi-dose med (Lisinopril) has several, and the
    /// old rule marked the *earliest* slot — so an evening tap recorded the
    /// long-past morning `scheduledFor` the operator never recognised in
    /// Verlauf. New rule: prefer the most-recent already-due slot
    /// (`scheduledAt <= now`), else the soonest upcoming slot.
    nonisolated static func resolveDispatchDose(
        medicationId: String,
        todayIntakes: [MedicationIntake],
        now: Date
    ) -> MedicationIntake? {
        let pending = todayIntakes
            .filter { $0.medicationId == medicationId && $0.status == .pending }
        guard !pending.isEmpty else { return nil }
        // Most-recent due-or-overdue slot (latest scheduledAt <= now).
        if let due = pending
            .filter({ $0.scheduledAt <= now })
            .max(by: { $0.scheduledAt < $1.scheduledAt })
        {
            return due
        }
        // No slot due yet — take the soonest upcoming one.
        return pending.min(by: { $0.scheduledAt < $1.scheduledAt })
    }

    /// Joins each scheduled time in the device's clock format.
    /// Internal `static` so the section-level snapshot test + the row
    /// contract tests can share the exact projection logic without
    /// reaching into private state. `nonisolated` so the contract tests
    /// can call it off the MainActor without the View struct's default
    /// isolation forcing test-suite ceremony.
    nonisolated static func scheduleSummary(
        _ schedule: MedicationSchedule,
        locale: Locale = HLTimeFormat.current().formattingLocale
    ) -> String {
        ClockTimeText.list(schedule.times, locale: locale)
    }
}
