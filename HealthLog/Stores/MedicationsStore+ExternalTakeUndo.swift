import Foundation

extension MedicationsStore {
    /// **#188 (7) — "Just logged as taken. Undo?" on the next open.**
    ///
    /// A dose taken from the notification, the widget, the Live Activity, the
    /// critical alarm or the Watch had no undo, because the app was not on
    /// screen. Those paths note the take in ``ExternalTakeLog``; after the
    /// foreground reload this offers one undo for the newest take inside the
    /// offer window. The undo deletes the intake through the existing route
    /// (`DELETE /api/medications/[id]/intake/[eventId]`), which reopens the
    /// slot. A take whose row the today list does not carry (yet) is not
    /// offered: there is nothing that could be deleted.
    func offerUndoForExternalTake(now: Date = .now) {
        guard let undoCoordinator else { return }
        // R1 (9): the row is looked up first; an entry whose row the list
        // does not carry yet stays in the log for the next open.
        let intakes = todayIntakes
        guard let entry = externalTakeLog.takeOffer(now: now, isUndoable: { Self.intakeToUndo(for: $0, in: intakes) != nil }),
              let intake = Self.intakeToUndo(for: entry, in: intakes),
              let sessionLease = captureAuthenticatedSessionLease() else { return }
        undoCoordinator.enqueue(message: String(localized: "undo.medication.taken.elsewhere"), ttl: 8) { [weak self] in
            guard let self, sessionLease.isCurrent else { return }
            // #191: only the take the person was offered, never a newer one.
            // R1 (1): the key this device wrote with is the precondition, so
            // the server refuses to remove a row someone else holds.
            await deleteIntake(
                medicationId: intake.medicationId,
                eventId: intake.id,
                expected: undoPrecondition(
                    syncVersion: intake.syncVersion,
                    idempotencyKey: entry.idempotencyKey ?? intake.idempotencyKey
                )
            )
        }
    }

    /// The server row an external take created, and only that one (R1 (1)):
    /// the row id the write answered with, or else the row that carries the
    /// write's idempotency key. Same medication, taken, a real server id (a
    /// placeholder has none). An entry without either (an older build) finds
    /// nothing: a take on the same slot from the pill box or the web is
    /// someone else's and is never removed.
    nonisolated static func intakeToUndo(
        for entry: ExternalTakeLog.Entry,
        in intakes: [MedicationIntake]
    ) -> MedicationIntake? {
        let binding = entry.binding
        guard !binding.isEmpty else { return nil }
        return intakes.first { intake in
            guard intake.medicationId == entry.medicationId,
                  intake.status == .taken,
                  !intake.isSynthesizedPlaceholder else { return false }
            if let rowID = binding.rowID { return intake.id == rowID }
            guard let key = binding.idempotencyKey, let rowKey = intake.idempotencyKey else { return false }
            return rowKey == key
        }
    }
}

extension MedicationsStore {
    /// **#188 (7) — deleting a history entry can be undone**, like the web's
    /// toast. The undo records the entry again (taken at its time, or
    /// skipped) on its slot; a still-open row has nothing to restore and gets
    /// no undo. `afterRestore` lets the detail screen reload its ledger.
    func offerUndoForDeletedIntake(
        _ event: PaginatedIntakeEvent,
        medicationId: String,
        afterRestore: @escaping @MainActor () async -> Void
    ) {
        guard let undoCoordinator, let restore = Self.restoration(of: event),
              let sessionLease = captureAuthenticatedSessionLease() else { return }
        undoCoordinator.enqueue(message: String(localized: "undo.medication.intake.deleted")) { [weak self] in
            guard let self, sessionLease.isCurrent else { return }
            await logIntakeFree(
                medicationId: medicationId,
                takenAt: restore.takenAt,
                skipped: restore.skipped,
                scheduledFor: event.scheduledFor,
                injectionSite: event.injectionSite.flatMap(InjectionSite.fromServerRawValue)
            )
            await afterRestore()
        }
    }

    /// What re-recording a deleted entry writes; `nil` for an open row.
    nonisolated static func restoration(of event: PaginatedIntakeEvent) -> (takenAt: Date, skipped: Bool)? {
        if event.skipped { return (event.scheduledFor, true) }
        guard let takenAt = event.takenAt else { return nil }
        return (takenAt, false)
    }
}
