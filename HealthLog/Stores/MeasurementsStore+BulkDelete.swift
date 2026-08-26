import Foundation

// v0.14.8 W3 — multi-select bulk delete, split into a focused extension so
// `MeasurementsStore.swift` stays under the SwiftLint `file_length` /
// `type_body_length` baselines (the same seam `+SeriesBacked.swift` uses).

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
    func bulkDelete(_ measurementsToDelete: [Measurement]) async -> Bool {
        guard let lease = captureAuthenticatedSessionLease() else { return false }
        guard !measurementsToDelete.isEmpty else { return true }
        let snapshot = recent
        var ids: [String] = []
        for m in measurementsToDelete {
            ids.append(m.id)
            if let diaId = m.bloodPressureDiastolicId {
                ids.append(diaId)
            }
        }
        let removedIDs = Set(ids)
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
}
