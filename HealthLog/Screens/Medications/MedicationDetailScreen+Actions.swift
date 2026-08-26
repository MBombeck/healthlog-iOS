import SwiftUI

// MARK: - Retro-mutate + ledger-row actions + low-supply alert

/// W-FILELEN — the retro-mutate / ledger-row write actions + the MED-4/C3
/// low-supply alert reconcile, lifted verbatim out of `MedicationDetailScreen`
/// into this same-module extension to keep the screen body under the 600-line
/// `file_length` swiftlint budget. Pure move, no behaviour change. The `@State` /
/// `@Environment` members these methods read are `internal` on the screen for
/// exactly this reason.
extension MedicationDetailScreen {
    // MARK: - MED-4 / C3 low-supply alert

    /// Re-evaluate the **server's** runway against the user's threshold and
    /// (re)arm the local low-supply alert. No-op when notifications aren't
    /// wired (standalone / macOS) or before the inventory fetch has landed.
    ///
    /// ROUTE-06: the day count is `Medication.runwayDays` verbatim — the same
    /// figure the server's own low-stock engine evaluates, so the local alert
    /// and the server push cannot disagree about when supply is low. The only
    /// local step is `runwayWithinThreshold`, which *filters*: `nil` means
    /// "nothing to alert about" (tracking off, or above the threshold, or the
    /// alert is switched off) and `reconcileLowSupplyAlert` treats it as
    /// "clear + re-arm". A server `0` passes the filter and alerts, because an
    /// exhausted supply is the case the alert exists for.
    ///
    /// `items` is the settle signal, not an input: the alert is re-evaluated
    /// when the inventory fetch completes, and before that there is nothing
    /// worth arming.
    func reconcileLowSupplyAlert(items: [MedicationInventoryItemDTO]?) {
        guard let notifications = appContainer?.notifications else { return }
        guard items != nil else { return }
        let medication = store.medication
        let runway = MedicationInventorySection.runwayWithinThreshold(
            medication.runwayDays,
            threshold: LowStockRunwayPrefStore.days()
        )
        Task {
            await notifications.reconcileLowSupplyAlert(
                medicationID: medication.id,
                medicationName: medication.name,
                runwayDays: runway
            )
        }
    }

    // MARK: - T-4 retro-mutate wiring

    /// Apply the optimistic patch locally, dispatch the network call, and
    /// either accept the result (success / queued) or roll back the
    /// optimistic patch (non-retriable failure). Mirrors the pattern T-3
    /// established for MedicationsScreen archive UX:
    /// `MedicationsStore.WriteOutcome.queued` keeps the optimistic state
    /// visible + flashes a banner; `.failed` reverts the row + surfaces
    /// the error via `store.error` (already wired upstream).
    func retroMark(event: PaginatedIntakeEvent, status: IntakeStatus) {
        guard let original = store.applyOptimisticMark(eventId: event.id, status: status) else { return }
        let medicationId = store.medication.id
        let scheduledAt = event.scheduledFor
        Task {
            let outcome = await medicationsStore.markIntakeRetroactively(
                medicationId: medicationId,
                eventId: event.id,
                status: status,
                scheduledAt: scheduledAt
            )
            handleOutcome(outcome, rollback: {
                store.rollbackOptimisticMark(eventId: event.id, original: original)
            })
            if case .success = outcome {
                // W3-MEDCONTRACT — converge the ledger Verlauf onto the
                // server's re-attributed truth (no-op when no ledger).
                await store.reloadDoseHistory()
            }
        }
    }

    /// **15-01 (B1)** — the operator corrects WHEN a logged dose was taken.
    /// Same shape as `retroMark` above: patch the row the user is looking at
    /// first, then send `takenAt` alone over the intake PUT the retro-mark path
    /// already uses; `.failed` puts the row back, `.queued` keeps it standing
    /// (the outbox holds the patch).
    func editIntakeTime(_ event: PaginatedIntakeEvent, to newTime: Date) {
        guard let original = store.applyOptimisticTimeEdit(
            eventId: event.id,
            takenAt: newTime
        ) else { return }
        let medicationId = store.medication.id
        Task {
            let outcome = await medicationsStore.editIntakeTakenAt(
                medicationId: medicationId,
                eventId: event.id,
                takenAt: newTime
            )
            handleOutcome(outcome, rollback: {
                store.rollbackOptimisticMark(eventId: event.id, original: original)
            })
            if case .success = outcome {
                // The ledger grades on-time vs late from `takenAt` — converge
                // on the server's re-reading of the corrected instant.
                await store.reloadDoseHistory()
            }
        }
    }

    func deleteIntake(_ event: PaginatedIntakeEvent) {
        // W3-MEDCONTRACT — the optimistic snapshot is best-effort now: a
        // ledger-rendered row may not sit in the legacy `intakes` page set
        // (e.g. older than the drained pages), and the delete must still go
        // through. The legacy section is unaffected (its rows always exist
        // in `intakes`, so the snapshot stays available for rollback).
        let snapshot = store.applyOptimisticDelete(eventId: event.id)
        let medicationId = store.medication.id
        Task {
            let outcome = await medicationsStore.deleteIntake(
                medicationId: medicationId,
                eventId: event.id
            )
            handleOutcome(outcome, rollback: {
                if let snapshot {
                    store.rollbackOptimisticDelete(snapshot.event, at: snapshot.index)
                }
            })
            if case .success = outcome {
                await store.reloadDoseHistory()
            }
        }
    }

    // MARK: - W3-MEDCONTRACT ledger-row actions

    /// Retro-mark a ledger row. Patches the legacy `intakes` mirror when the
    /// event is loaded there (keeps the PK chart + fallback analytics in
    /// sync), PUTs via the store, then refreshes the ledger so the row shows
    /// the server's grading (on-time vs late is the server's call, not ours).
    func ledgerRetroMark(_ row: MedicationDoseHistoryRow, status: IntakeStatus) {
        guard let eventId = row.intake?.id else { return }
        let medicationId = store.medication.id
        let scheduledAt = row.intake?.scheduledFor ?? row.at
        let original = store.applyOptimisticMark(eventId: eventId, status: status)
        Task {
            let outcome = await medicationsStore.markIntakeRetroactively(
                medicationId: medicationId,
                eventId: eventId,
                status: status,
                scheduledAt: scheduledAt
            )
            handleOutcome(outcome, rollback: {
                if let original {
                    store.rollbackOptimisticMark(eventId: eventId, original: original)
                }
            })
            if case .success = outcome {
                await store.reloadDoseHistory()
            }
        }
    }

    /// "Diesem Slot zuordnen" — pin an ad-hoc take onto its nearest unserved
    /// slot (`forceSlotInstant`, counted taken-late server-side).
    func ledgerPin(_ row: MedicationDoseHistoryRow) {
        guard let eventId = row.intake?.id, let slot = row.nearestSlot?.at else { return }
        let medicationId = store.medication.id
        Task {
            let outcome = await medicationsStore.pinIntakeToSlot(
                medicationId: medicationId,
                eventId: eventId,
                slotInstant: slot
            )
            handleOutcome(outcome, rollback: {})
            if case .success = outcome {
                await store.reloadDoseHistory()
            }
        }
    }

    /// "Zuordnung lösen" — release a user pin; the server re-attributes the
    /// take by window band on its own `takenAt`.
    func ledgerUnpin(_ row: MedicationDoseHistoryRow) {
        guard let eventId = row.intake?.id else { return }
        let medicationId = store.medication.id
        Task {
            let outcome = await medicationsStore.unpinIntake(
                medicationId: medicationId,
                eventId: eventId
            )
            handleOutcome(outcome, rollback: {})
            if case .success = outcome {
                await store.reloadDoseHistory()
            }
        }
    }

    /// Synthesise the `PaginatedIntakeEvent` the shared delete-confirmation
    /// dialog presents from a ledger row (the row may not exist in the
    /// legacy `intakes` pages).
    static func deleteCandidate(for row: MedicationDoseHistoryRow) -> PaginatedIntakeEvent? {
        guard let intake = row.intake, let id = intake.id else { return nil }
        return PaginatedIntakeEvent(
            id: id,
            takenAt: intake.takenAt,
            skipped: intake.skipped,
            scheduledFor: intake.scheduledFor,
            injectionSite: nil
        )
    }

    func handleOutcome(
        _ outcome: MedicationsStore.WriteOutcome,
        rollback: @escaping () -> Void
    ) {
        switch outcome {
        case .success:
            // Optimistic state already matches; no UI work needed.
            queuedBannerShownAt = nil
        case .queued:
            // Keep optimistic state visible — outbox will reconcile. Flash
            // the "Wird beim nächsten Sync übertragen" banner so the
            // operator knows the action landed offline.
            queuedBannerShownAt = .now
            Task {
                try? await Task.sleep(for: .seconds(3))
                // Only clear if no newer queue event arrived in the meantime.
                if let shownAt = queuedBannerShownAt, Date().timeIntervalSince(shownAt) >= 3 {
                    queuedBannerShownAt = nil
                }
            }
        case .failed:
            rollback()
            queuedBannerShownAt = nil
        }
    }
}
