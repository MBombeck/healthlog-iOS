import Foundation

/// **v1.39.1 (#1033) — intake tracking.** Split out of `Medication.swift`
/// (file_length discipline): the derived reads of the server's `trackIntake`
/// and the helpers every planning surface uses to leave a medication kept as a
/// record out.
public extension Medication {
    /// **v1.39.1 (#1033)** — whether intake is tracked for this medication.
    /// `false` only when the server said so: the medication is then kept as a
    /// record, with no due dose, no reminder on any channel, no intake buttons
    /// and no adherence figure.
    var tracksIntake: Bool {
        trackIntake != false
    }

    /// **v1.39.4 (#1040)** — the server's `intakeActionable`; a server that
    /// predates the field (`nil`) reads as `true`. The server resolves it as
    /// `active && trackIntake && courseStatus == CURRENT` on the account's
    /// clock, so it is never re-derived here from `startsOn` / `endsOn`.
    var isIntakeActionable: Bool {
        intakeActionable != false
    }

    /// Whether this medication offers Taken / Skip TODAY: intake is tracked
    /// and the server calls it actionable. Every surface that offers a dose
    /// action (card, row, quick intake, take-all, Live Activity, widget,
    /// watch, Siri) ANDs this in. Logging a past dose from the history is
    /// deliberately not gated by it.
    var offersIntakeActions: Bool {
        tracksIntake && isIntakeActionable
    }

    /// The schedule to SHOW for this medication: the live one, or for a
    /// medication kept as a record, the stored one. Never used to plan
    /// anything — planning reads ``schedule``, which is empty for a record.
    var displaySchedule: MedicationSchedule {
        tracksIntake ? schedule : (recordedSchedule ?? schedule)
    }
}

public extension Medication {
    /// **E1** — whether the server behind `medications` knows `trackIntake`
    /// (v1.39.1+): any row it served carries the field. The add sheet offers
    /// the switch only then; with no row to tell, it does not guess.
    static func serverKnowsTrackIntake(_ medications: [Medication]) -> Bool {
        medications.contains { $0.trackIntake != nil }
    }

    /// **v1.39.1 (#1033)** — this medication with ``schedule`` swapped for
    /// `schedule`, every other field kept. The medication editor opens a
    /// medication kept as a record on its STORED schedule
    /// (``displaySchedule``), so a save that touches the schedule edits what
    /// the person sees instead of a daily-08:00 default.
    func replacingSchedule(_ schedule: MedicationSchedule) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: dose,
            treatmentClass: treatmentClass,
            category: category,
            dosesPerUnit: dosesPerUnit,
            unitsPerDose: unitsPerDose,
            schedule: schedule,
            lastTakenAt: lastTakenAt,
            todayEventCount: todayEventCount,
            notificationsEnabled: notificationsEnabled,
            active: active,
            archivedAt: archivedAt,
            startsOn: startsOn,
            endsOn: endsOn,
            oneShot: oneShot,
            asNeeded: asNeeded,
            trackIntake: trackIntake,
            recordedSchedule: recordedSchedule,
            deliveryForm: deliveryForm,
            createdAt: createdAt,
            nextDueAt: nextDueAt,
            nextDueOverdue: nextDueOverdue,
            liveActivityEnabled: liveActivityEnabled,
            criticalAlarmEnabled: criticalAlarmEnabled,
            trackInjectionSites: trackInjectionSites,
            allowedInjectionSites: allowedInjectionSites,
            externalSource: externalSource,
            externalId: externalId,
            pausedAt: pausedAt,
            stockDosesRemaining: stockDosesRemaining,
            runwayDays: runwayDays,
            courseStatus: courseStatus,
            intakeActionable: intakeActionable
        )
    }
}

public extension MedicationIntake {
    /// **v1.39.1 (#1033)** — drops the rows of every medication the server
    /// keeps as a record (`trackIntake: false`). Such a medication has nothing
    /// due: no dose card entry, no ring slot, no widget or watch dose. A row
    /// whose medication is not in `medications` is kept, as before.
    ///
    /// **v1.39.4 (#1040)** — also drops the still-open rows (neither taken nor
    /// skipped) of a medication the server calls not actionable today
    /// (`intakeActionable: false`, e.g. an ended course), so no surface built
    /// from these rows offers Taken / Skip for it. Its resolved rows stay.
    static func excludingUntrackedMedications(
        _ intakes: [MedicationIntake],
        medications: [Medication]
    ) -> [MedicationIntake] {
        let untracked = Set(medications.filter { !$0.tracksIntake }.map(\.id))
        let notActionable = Set(medications.filter { !$0.isIntakeActionable }.map(\.id))
        guard !untracked.isEmpty || !notActionable.isEmpty else { return intakes }
        return intakes.filter { intake in
            if untracked.contains(intake.medicationId) { return false }
            guard notActionable.contains(intake.medicationId) else { return true }
            return intake.status == .taken || intake.status == .skipped
        }
    }
}
