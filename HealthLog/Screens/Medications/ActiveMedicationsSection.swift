import SwiftUI

/// Ausgelagert aus ActiveMedicationRow.swift (file_length, reine Verschiebung — b177 QA-FINAL).
/// hand-off from `MedicationsStore` to per-card props.
///
/// **08-13 — the card stack is the whole of this section.** 08-05 collapsed
/// `MedicationListView` to one case and left the compact alternate row and the
/// inert `view:` parameter behind, because a frozen Phase-06 presentation row
/// pinned the unmounted branch in source. That row is now dispositioned
/// `DELETED_BY_LATER_PHASE` under this plan, so the branch, its dense row file
/// and the parameter that used to choose between them are gone rather than
/// merely unreachable.
struct ActiveMedicationsSection: View {
    let medications: [Medication]
    /// v0.6.1.2 Y4 (D-019): kept on the section signature so the
    /// hosting screen does not have to break the call-site contract
    /// while the per-row quick-mark drops; the value is no longer
    /// rendered by the row. The detail-screen "Heute" sub-section is
    /// now the canonical take-action surface for a medication.
    let todayIntakes: [MedicationIntake]
    let onAdd: () -> Void
    let onEdit: (Medication) -> Void
    let onArchive: (Medication) -> Void
    /// Mark-action plumbing from the parent screen. Receives the
    /// synth-placeholder intake id (or the server-created intake id
    /// when one already exists for today's slot) along with the
    /// desired status. Mirrors the existing
    /// `MedicationsStore.markIntakeQuick` contract so the card stack
    /// keeps web parity on the bulk-intake POST path.
    ///
    /// **v0.11 #60** — the `Medication` rides along so the host can gate
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
    /// **v0.8.3 W-B** — compliance-value tap target. Pushes the detail
    /// screen, where the 90-day green/yellow/red adherence track lives.
    /// Parent forwards through the same `Medication`-value navigation.
    let onComplianceTap: (Medication) -> Void
    /// **15-04 (E3)** — long-press on a card's Genommen CTA. The host opens the
    /// existing free-intake dialog, preselected on this medication.
    let onDeviatingDose: (MedicationCardActions.DeviatingDose) -> Void
    /// Pre-merged today + recent-history intakes used by each card's
    /// compliance computation. The parent screen passes the SWR-served
    /// today list; the per-card history fetch lives in a future
    /// extension when the operator surfaces a real need for live 30-day
    /// bars (today the rate divides by `effectiveDays` which clamps to
    /// the medication's earliest seen intake, so a fresh medication
    /// still reads sensibly).
    let windowIntakes: [MedicationIntake]

    /// **v0.6.1.4 Y4.2** — the store carries the per-medication
    /// server-canonical compliance cache. Read via
    /// `cardComplianceSnapshot(for:windowIntakes:)` which returns the
    /// cached value or falls back to the local algorithm. The
    /// `windowIntakes` argument keeps the fallback path lossless.
    @Environment(MedicationsStore.self) private var store

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("medications.section.active.title")

            if medications.isEmpty {
                EmptyActiveMedicationsState(onAdd: onAdd)
            } else {
                LazyVStack(spacing: HLSpace.md) {
                    ForEach(medications, id: \.id) { med in
                        MedicationCard(
                            medication: med,
                            displayState: .from(medication: med),
                            scheduleSummary: Self.scheduleSummary(med.schedule),
                            // v0.6.1.4 Y4.2 — prefer the server-canonical
                            // snapshot cached on the store. Falls back to
                            // the local-algorithm port for the brief window
                            // before the per-medication fetch lands (cold
                            // cache, offline). The card never paints blank.
                            compliance: store.cardComplianceSnapshot(
                                for: med,
                                windowIntakes: windowIntakes
                            ),
                            lastTakenAt: med.lastTakenAt,
                            onHistory: { onHistory(med) },
                            onComplianceTap: { onComplianceTap(med) },
                            onEdit: { onEdit(med) },
                            onMarkTaken: { dispatchMark(med: med, status: .taken) },
                            onMarkSkipped: { dispatchMark(med: med, status: .skipped) },
                            onArchive: { onArchive(med) },
                            onDeviatingDose: onDeviatingDose,
                            isMarking: isMarking(med: med),
                            takenToday: isTakenToday(med: med),
                            // v0.14.1 INV-med-cadence-phantom (BUG 1) — anchor the
                            // card's next-dose projection on the server-profile
                            // zone so it matches the detail screen + reminders.
                            profileTimeZone: store.profileTimeZone
                        )
                        // v0.6.1.3 Y4.1 — subtle skid-in on mount /
                        // insert so the card-stack reads as "settling
                        // into place" rather than popping in flat. Pow's
                        // `.movingParts.skid` is an elastic slide from
                        // the leading edge; restrained enough that it
                        // doesn't compete with the per-tile content.
                        // Reduce-motion users get the default
                        // opacity-fade transition instead via the
                        // accessibility-driven `transition` branch.
                        .transition(reduceMotion ? .opacity : .movingParts.skid)
                    }
                }
                // Bind the LazyVStack to the medication-id list so the
                // ForEach diff drives the transition cleanly on insertion
                // (new med added) and reorder (archive removes a card).
                .hlAnimation(.smooth(duration: 0.3), value: medications.map(\.id))
            }
        }
    }

    /// **v0.8.2 W1b (audit B5).** `true` while the resolved pending
    /// today-intake for `med` is mid-mark. Only the materialised /
    /// synth-placeholder dose carries a stable id the store can track;
    /// an ad-hoc PRN mark (no pending row) generates its id at tap-time,
    /// so its in-flight window is too brief to reflect here — the
    /// store-level guard still coalesces those, this is only the visible
    /// disable for the resolvable dose.
    /// **v0.14 BC** — today's dose for `med` is logged as taken. Reuses the
    /// canonical `MedicationQuickMarkState.resolve` so the card's resting
    /// "done" state agrees with the same source of truth the quick-mark uses.
    private func isTakenToday(med: Medication) -> Bool {
        MedicationQuickMarkState.resolve(
            medicationId: med.id,
            todayIntakes: todayIntakes
        ) == .takenToday
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

    /// **v0.14.1 ITEM-A** — pick which pending today-dose a Genommen /
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

    /// Joins each scheduled time as `HH:mm` with a `·` separator.
    /// Internal `static` so the section-level snapshot test + the row
    /// contract tests can share the exact projection logic without
    /// reaching into private state. `nonisolated` so the contract tests
    /// can call it off the MainActor without the View struct's default
    /// isolation forcing test-suite ceremony.
    nonisolated static func scheduleSummary(_ schedule: MedicationSchedule) -> String {
        schedule.times
            .sorted()
            .map { String(format: "%02d:%02d", $0.hour, $0.minute) }
            .joined(separator: " · ")
    }
}

/// Empty state for "user has medications but none active right now"
/// (e.g. everything archived).
///
/// **POLISH-MED (v0.5.5.6).** Drops the `HLCard` wrapper so the empty
/// state lives on the same canvas as the free-floating rows it
/// replaces. The visual hierarchy — small icon + short title + body +
/// CTA — is enough; the card chrome was overkill for a transient
/// "all archived" message.
struct EmptyActiveMedicationsState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: HLSpace.md) {
            Image(systemName: "pills")
                .font(.hlIcon(HLIconSize.hero, weight: .light))
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
                .padding(.top, HLSpace.sm)
            // Y8: hierarchy correction per handbook §2.7 — title must
            // be headline (17pt), body subhead (15pt). The prior
            // subhead-semibold + caption shape inverted the empty
            // state into caption-only reading weight.
            Text("medications.section.active.empty.title")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            Text("medications.section.active.empty.body")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HLSpace.md)
            HLButton(
                String(localized: "medications.section.active.empty.cta"),
                icon: "plus",
                variant: .restrained,
                action: onAdd
            )
            .padding(.horizontal, HLSpace.md)
            .padding(.top, HLSpace.xxs)
            .padding(.bottom, HLSpace.sm)
            .accessibilityIdentifier("medications.section.active.empty.cta")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.md)
    }
}
