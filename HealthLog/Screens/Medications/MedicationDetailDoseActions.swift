import SwiftUI

/// **#191 point 5 — take, skip and snooze on the medication page.**
///
/// The web's detail page acts on today's open dose where it names it: the
/// dose ("Today, 08:00") with its state beside it, then Take and Skip, and
/// "Remind me later (30 min)" as the quiet third choice. The same store
/// paths as the card run underneath, so the toast with its Undo, the
/// already-taken notice and the outbox behave exactly as on the list.
///
/// Absent for a medication without a schedule, one kept as a record, one
/// whose doses come from Apple Health or are recorded automatically, and
/// when no dose of today is open.
struct MedicationDetailDoseActions: View {
    let medication: Medication
    /// The compliance block of the page: its `currentDose` names the dose
    /// the actions act on (#191, final). `nil` before the compliance read.
    var complianceDisplay: ComplianceDisplay?
    @Environment(MedicationsStore.self) private var store
    @State private var takePulse = 0
    @State private var isWorking = false

    var body: some View {
        if Self.offersActions(medication), let dose = Self.currentOpenDose(
            medicationId: medication.id,
            todayIntakes: store.derivedTodayIntakes,
            complianceDisplay: complianceDisplay,
            now: .now
        ) {
            let look = Self.look(for: dose, now: .now)
            // 1.7: until the store confirms today's doses the row names the
            // time only, and the actions rest dimmed.
            let unconfirmed = store.isDoseStateUnconfirmed
            HLCard("med.detail.dose.title") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HLFactRow(
                        label: Text(verbatim: MedicationCard.relativeDateTime(dose.scheduledAt)),
                        value: Text(verbatim: unconfirmed ? "" : look.title).foregroundStyle(Self.color(look.tone))
                    )
                    .accessibilityIdentifier("MedicationDetail.dose.state")
                    if !unconfirmed, let note = Self.note(for: dose, look: look, now: .now) {
                        Text(verbatim: note)
                            .hlText(.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HLTileActions([
                        HLTileAction.Item("med.dose.action.take", icon: "checkmark", identifier: "MedicationDetail.dose.take") {
                            takePulse &+= 1
                            run(dose, .taken)
                        },
                        HLTileAction.Item("med.dose.action.skip", icon: "forward.end", identifier: "MedicationDetail.dose.skip") {
                            run(dose, .skipped)
                        }
                    ])
                    .sensoryFeedback(.success, trigger: takePulse)
                    .disabled(isWorking || unconfirmed)
                    .opacity(unconfirmed ? 0.5 : 1)
                    if Self.canSnooze(dose) {
                        HLLinkButton(Text(verbatim: MedicationDoseWords.snooze(minutes: MedicationSnooze.minutes))) {
                            run(dose, .snoozed)
                        }
                        .disabled(isWorking || unconfirmed)
                        .accessibilityIdentifier("MedicationDetail.dose.snooze")
                    }
                }
            }
        }
    }

    private func run(_ dose: MedicationIntake, _ status: IntakeStatus) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            if status == .snoozed {
                _ = await store.markIntakeQuick(intakeId: dose.id, status: .snoozed)
            } else {
                _ = await store.markIntakeQuickUndoable(intakeId: dose.id, status: status)
            }
            isWorking = false
        }
    }

    // MARK: - Pure rules

    /// Whether this page offers dose actions at all.
    nonisolated static func offersActions(_ medication: Medication) -> Bool {
        medication.active
            && medication.tracksIntake
            && medication.allowsManualDoseLogging
            && !medication.asNeeded
            && medication.autoMarkTaken != true
    }

    /// **#191 (final) — the dose the server names.** With
    /// ``MedicationCapability/currentDoseOpenSlot`` and a compliance block,
    /// `currentDose.targetAt` picks today's open row of that slot; a
    /// `targetAt` of null means there is no current dose. Otherwise (an older
    /// server, or before the compliance read) the rule below.
    nonisolated static func currentOpenDose(
        medicationId: String,
        todayIntakes: [MedicationIntake],
        complianceDisplay: ComplianceDisplay?,
        now: Date,
        serverNamesDose: Bool = MedicationCapabilities.isOpen(.currentDoseOpenSlot)
    ) -> MedicationIntake? {
        guard serverNamesDose, let complianceDisplay else {
            return openDose(medicationId: medicationId, todayIntakes: todayIntakes, now: now)
        }
        guard let target = complianceDisplay.currentDose?.targetAt else { return nil }
        return todayIntakes.first {
            $0.medicationId == medicationId && ($0.status == .pending || $0.status == .snoozed)
                && abs(($0.doseState?.slotInstant ?? $0.scheduledAt).timeIntervalSince(target)) < 60
        }
    }

    /// The dose the actions act on: the latest of today's open doses that is
    /// due already, else the next one (the card's rule, with a snoozed dose
    /// counted as open: the snooze only moved its reminder).
    nonisolated static func openDose(
        medicationId: String,
        todayIntakes: [MedicationIntake],
        now: Date
    ) -> MedicationIntake? {
        let open = todayIntakes.filter {
            $0.medicationId == medicationId && ($0.status == .pending || $0.status == .snoozed)
                && ($0.doseState.flatMap { MedicationDosePhase(wire: $0.state) }?.isOpen ?? true)
        }
        if let due = open.filter({ $0.scheduledAt <= now }).max(by: { $0.scheduledAt < $1.scheduledAt }) {
            return due
        }
        return open.min(by: { $0.scheduledAt < $1.scheduledAt })
    }

    /// The state beside the dose: the server's when it resolved one, else
    /// pending before the dose time and due after it.
    nonisolated static func look(
        for dose: MedicationIntake,
        now: Date,
        serverState: Bool = MedicationServerResolvedSlots.isAvailable()
    ) -> MedicationDoseLook {
        if serverState, let state = dose.doseState,
           let look = MedicationDoseLook(wire: state.state, takenLate: state.takenLate)
        {
            return look
        }
        return MedicationDoseLook(phase: dose.scheduledAt > now ? .pending : .due)
    }

    /// The line under the state: the snooze, or the missed hint.
    nonisolated static func note(for dose: MedicationIntake, look: MedicationDoseLook, now: Date) -> String? {
        if dose.status == .snoozed, let until = dose.snoozedUntil, until > now {
            return MedicationDoseWords.snoozedUntil(HLTimeFormat.time(until))
        }
        if look.phase == .missed { return MedicationDoseWords.missedStillCounts }
        return nil
    }

    /// A snooze needs a server row to hold it.
    nonisolated static func canSnooze(_ dose: MedicationIntake) -> Bool {
        !dose.isSynthesizedPlaceholder
    }

    static func color(_ tone: MedicationDoseTone) -> Color {
        switch tone {
        case .quiet, .muted: HLText.secondary
        case .due: HLText.primary
        case .warning, .late: HLColor.statusWarn
        case .critical: HLColor.statusBad
        case .success: HLColor.statusOK
        }
    }
}
