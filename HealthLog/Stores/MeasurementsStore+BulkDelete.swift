import Foundation

// v0.14.8 W3 — multi-select bulk delete, split into a focused extension so
// `MeasurementsStore.swift` stays under the SwiftLint `file_length` /
// `type_body_length` baselines (the same seam `+SeriesBacked.swift` uses).
//
// 1.5 FIX-DATA — the single delete and its undo live here too, so every
// lease-fenced delete effect stays in a file the Phase-06 effect inventory
// assigns (06-03). What a delete removes and sends is decided without any
// effect in `MeasurementsStore+ReadingDelete.swift`.

@MainActor
public extension MeasurementsStore {
    /// Multi-select bulk delete (v1.15.13
    /// `POST /api/measurements/bulk-delete`). Optimistic: the selected rows
    /// leave `recent` immediately; a durably-enqueued failure (the repo
    /// chunked the ids onto the outbox) keeps the removal, a non-retriable
    /// failure rolls it back. No undo toast — the destructive confirmation
    /// dialog already gates the action, and a multi-row re-POST undo would
    /// re-create every row under fresh ids (the single-delete undo
    /// trade-off, multiplied).
    ///
    /// BP rows: the merged pair's diastolic peer id is included so the
    /// server tombstones BOTH halves (a lone DIA half would resurface).
    /// 1.5 FIX-DATA: a 1.46.2 server also deletes the reading's pulse and
    /// counts it, so `deleted` may exceed the ids sent; the pulse rows leave
    /// the list with the reading (`MeasurementsStore+ReadingDelete.swift`).
    func bulkDelete(_ measurementsToDelete: [Measurement]) async -> Bool {
        guard let lease = captureAuthenticatedSessionLease() else { return false }
        guard !measurementsToDelete.isEmpty else { return true }
        let snapshot = recent
        var ids: [String] = []
        var removedIDs: Set<String> = []
        let takesReading = serverTakesWholeReading
        for m in measurementsToDelete {
            ids.append(m.id)
            if let diaId = m.bloodPressureDiastolicId {
                ids.append(diaId)
            }
            if takesReading {
                removedIDs.formUnion(readingPulseRows(of: m).map(\.id))
            }
        }
        removedIDs.formUnion(ids)
        // audit-v0162 H-3 — bump before the optimistic multi-row removal so an
        // in-flight `.fresh` can't resurrect any of the deleted rows.
        bumpMutationGeneration()
        recent.removeAll { removedIDs.contains($0.id) }
        do {
            try lease.requireCurrent()
            _ = try await repo.bulkDelete(ids: ids)
            try lease.requireCurrent()
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            error = err
            // Mirrors `delete(_:)`: a retriable failure is already on the
            // outbox — keep the optimistic removal; only a genuinely-dropped
            // bulk delete resurrects the rows.
            if !err.shouldPersistToOutbox {
                recent = snapshot
            }
            return false
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            self.error = .unknown(String(describing: error))
            recent = snapshot
            return false
        }
    }

    // MARK: - Single delete (1.5 FIX-DATA: moved here from `MeasurementsStore.swift`)

    /// Optimistic delete — drops the row immediately, restores it on a
    /// non-retriable failure.
    ///
    /// **Undo (v0.5.5.1):** if an `UndoCoordinator` was injected, the
    /// optimistic remove is paired with an undo affordance enqueued BEFORE
    /// the network call. On a non-retriable failure we roll back the
    /// optimistic remove AND dismiss the toast (the row still lives on the
    /// server, so the undo affordance would do harm).
    ///
    /// **Blood pressure (1.5):** see the file note. The pulse of the reading
    /// leaves the list together with it when the server deletes it as well.
    func delete(_ measurement: Measurement) async -> Bool {
        guard let lease = captureAuthenticatedSessionLease() else { return false }
        let snapshot = recent
        let plan = deletePlan(for: measurement)
        let outcome = MeasurementDeleteOutcome()
        // audit-v0162 H-3 — bump BEFORE the optimistic removal so an in-flight
        // `.fresh` (fetched before this delete) is dropped instead of re-adding
        // the row.
        bumpMutationGeneration()
        let removed = plan.localIDs
        recent.removeAll { removed.contains($0.id) }
        // Queue undo BEFORE the network round-trip so a fast double-tap can
        // recover even while the DELETE is still in flight.
        undoCoordinator?.enqueue(
            message: String(localized: "undo.measurement.removed")
        ) { [weak self] in
            await self?.undoDelete(plan, outcome: outcome)
        }
        do {
            try lease.requireCurrent()
            switch plan.wire {
            case let .single(id):
                try await repo.delete(id: id)
            case let .bulk(ids):
                // The count may be larger than the ids sent (a 1.46.2 server
                // counts the pulse too); any answer without an error is success.
                try await repo.bulkDelete(ids: ids)
            }
            try lease.requireCurrent()
            outcome.landed = true
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            error = err
            // A durably-enqueued DELETE (retriable OR a transient-refresh 401
            // the repo just queued) keeps the optimistic removal — the Outbox
            // replays the DELETE later. Only a genuinely-dropped DELETE
            // resurrects the rows + dismisses undo.
            if !err.shouldPersistToOutbox {
                recent = snapshot
                undoCoordinator?.dismiss(reason: .cancelled)
            }
            return false
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return false }
            self.error = .unknown(String(describing: error))
            recent = snapshot
            undoCoordinator?.dismiss(reason: .cancelled)
            return false
        }
    }

    // MARK: - Undo

    private func undoDelete(_ plan: MeasurementDeletePlan, outcome: MeasurementDeleteOutcome) async {
        if plan.serverTakesWholeReading, outcome.landed {
            await restoreReading(plan)
        } else {
            // Before 1.46.2, or the DELETE is still queued: the restore route
            // would find nothing to restore, so re-create the reading.
            await restoreDeletedMeasurement(plan.row)
        }
    }

    /// 1.46.2 — un-tombstones the reading from its systolic id. The server
    /// keeps the ids, so the rows come back exactly as they were. On failure
    /// the rows leave again and the error shows: the reading stays deleted on
    /// the server, and a re-create here could double it if the restore did land.
    private func restoreReading(_ plan: MeasurementDeletePlan) async {
        guard let lease = captureAuthenticatedSessionLease() else { return }
        bumpMutationGeneration()
        let rows = [plan.row] + plan.pulseRows
        for row in rows {
            reinsert(row)
        }
        do {
            try lease.requireCurrent()
            try await repo.restore(ids: [plan.row.id])
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return }
            self.error = (error as? HLError) ?? .unknown(String(describing: error))
            bumpMutationGeneration()
            let ids = plan.localIDs
            recent.removeAll { ids.contains($0.id) }
        }
    }

    /// Re-inserts a deleted measurement at its original chronological slot
    /// and re-posts it through the standard create path. The new server
    /// row carries a fresh id; the original id is gone for good. This is
    /// the acceptable trade-off documented in the v0.5.5.1 undo brief.
    private func restoreDeletedMeasurement(_ measurement: Measurement) async {
        guard let lease = captureAuthenticatedSessionLease() else { return }
        // audit-v0162 H-3 — a re-insert is an optimistic mutation too; bump so a
        // stale `.fresh` from before the restore can't drop the row again.
        bumpMutationGeneration()
        reinsert(measurement)
        // Re-post via the create path so the server gets the row back.
        // Errors land on `self.error` exactly like a fresh capture would.
        _ = await capture(
            kind: measurement.kind,
            value: measurement.value,
            note: measurement.note,
            glucoseContext: measurement.glucoseContext
        )
        guard authenticatedEffectIsCurrent(lease) else { return }
        // The new row from `capture` carries a different id than the
        // restored snapshot. Drop the snapshot copy now that the real row
        // is in place so the list doesn't show a duplicate.
        recent.removeAll { $0.id == measurement.id }
    }
}
