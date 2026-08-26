import Foundation

/// v0.14.8 W3 — v1.15.13 adoption: multi-select bulk delete for the
/// measurement management list (`POST /api/measurements/bulk-delete`,
/// RESEARCH-SERVER-PARITY A2).
///
/// **Server contract** (`src/app/api/measurements/bulk-delete/route.ts`):
/// body `{ ids: [1..200] }`, ownership-scoped soft-delete (tombstones) in one
/// `updateMany`; forged / foreign / already-deleted ids are silent no-ops
/// (never a 404 existence leak); response `{ deleted: <count> }`. Wrapped in
/// `withIdempotency`, so the per-chunk `Idempotency-Key` dedups replays
/// inside the 24h window — and beyond it the tombstone semantics make a
/// re-delete harmless anyway.
extension MeasurementsRepository {
    /// `{ deleted: n }` success body of the bulk-delete route.
    struct BulkDeleteResponse: Codable {
        let deleted: Int
    }

    /// Server bound: `z.array(z.string().min(1)).min(1).max(200)`.
    static let bulkDeleteMaxIDsPerBatch = 200

    /// Soft-deletes `ids` on the server (optimistic + outbox-enrolled).
    ///
    /// - Chunks selections larger than 200 ids; each chunk carries its own
    ///   `Idempotency-Key`.
    /// - On a *retriable* failure the failed chunk AND every not-yet-sent
    ///   chunk land on the outbox under `bulkDeleteMeasurements`, then the
    ///   error re-throws — the calling store keeps its optimistic removal
    ///   (mirrors the single-delete contract).
    /// - On a non-retriable failure the error re-throws without enqueueing;
    ///   the store rolls its optimistic removal back.
    /// - **Standalone:** deletes the rows from the local mirror, no network.
    ///
    /// Returns the number of rows the server confirmed tombstoned (standalone:
    /// the number of local rows removed).
    @discardableResult
    public func bulkDelete(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        if standalone?.isActive == true, let standalone {
            for id in ids {
                try await standalone.local.standaloneDeleteMeasurement(externalId: id)
            }
            return ids.count
        }
        let chunks = stride(from: 0, to: ids.count, by: Self.bulkDeleteMaxIDsPerBatch).map {
            Array(ids[$0 ..< min($0 + Self.bulkDeleteMaxIDsPerBatch, ids.count)])
        }
        var deleted = 0
        var anyChunkLanded = false
        for (index, chunk) in chunks.enumerated() {
            let idempotencyKey = IdempotencyKey()
            do {
                deleted += try await postBulkDelete(chunk, idempotencyKey: idempotencyKey)
                anyChunkLanded = true
            } catch {
                if let err = error as? HLError, err.shouldPersistToOutbox {
                    // Queue the failed chunk under ITS key, plus every chunk
                    // that never got sent (fresh keys) — the replay drains
                    // them in enqueue order.
                    await enqueueBulkDelete(chunk, idempotencyKey: idempotencyKey)
                    for pending in chunks.dropFirst(index + 1) {
                        await enqueueBulkDelete(pending, idempotencyKey: IdempotencyKey())
                    }
                }
                if anyChunkLanded {
                    // Rows a landed chunk removed must not linger in cached
                    // pages even though the overall call failed.
                    await invalidateAfterWriteAllKinds()
                }
                throw error
            }
        }
        // No kind context on an id-only delete — fan out (same as the
        // single delete).
        await invalidateAfterWriteAllKinds()
        return deleted
    }

    /// Outbox-replay path: re-POSTs one chunk under the persisted key.
    @discardableResult
    public func replayBulkDelete(ids: [String], idempotencyKey: String) async throws -> Int {
        let deleted = try await postBulkDelete(ids, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
        await invalidateAfterWriteAllKinds()
        return deleted
    }

    // MARK: - Private

    private func postBulkDelete(_ ids: [String], idempotencyKey: IdempotencyKey) async throws -> Int {
        let req: APIRequest<BulkDeleteResponse> = try .post(
            "/api/measurements/bulk-delete",
            body: OutboxQueue.Payloads.BulkDeleteMeasurements(ids: ids),
            idempotencyKey: idempotencyKey
        )
        return try await api.send(req).deleted
    }

    private func enqueueBulkDelete(_ ids: [String], idempotencyKey: IdempotencyKey) async {
        do {
            let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.BulkDeleteMeasurements(ids: ids))
            try await outbox.enqueue(.init(
                kind: .bulkDeleteMeasurements,
                payload: payload,
                idempotencyKey: idempotencyKey.raw
            ))
        } catch {
            HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
