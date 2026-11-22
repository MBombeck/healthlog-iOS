import Foundation

/// v1.15.13 adoption: multi-select bulk delete for the
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
    ///   (mirrors the single-delete contract). When they cannot all be
    ///   stored, none stays queued and the error is `notPersisted`.
    /// - On a non-retriable failure the error re-throws without enqueueing;
    ///   the store rolls its optimistic removal back.
    ///
    /// Returns the number of rows the server confirmed tombstoned.
    @discardableResult
    public func bulkDelete(ids requested: [String]) async throws -> Int {
        // A synthetic bucket key names no row; never send it.
        let ids = requested.filter { !Measurement.isSyntheticServerRowID($0) }
        guard !ids.isEmpty else { return 0 }
        let chunks = stride(from: 0, to: ids.count, by: Self.bulkDeleteMaxIDsPerBatch).map {
            Array(ids[$0 ..< min($0 + Self.bulkDeleteMaxIDsPerBatch, ids.count)])
        }
        var deleted = 0
        var anyChunkLanded = false
        for (index, chunk) in chunks.enumerated() {
            let idempotencyKey = IdempotencyKey()
            let row = UUID()
            do {
                let op = try Self.bulkDeleteOperation(chunk, idempotencyKey: idempotencyKey, row: row)
                deleted += try await outbox.writeAhead(op) { [self] in
                    try await postBulkDelete(chunk, idempotencyKey: idempotencyKey)
                }
                anyChunkLanded = true
            } catch {
                var failure = error
                if let err = error as? HLError, err.shouldPersistToOutbox {
                    // The failed chunk is stored under ITS key already. Every
                    // chunk that never got sent follows under a fresh key; the
                    // replay drains them in enqueue order.
                    do {
                        try await enqueueUnsent(chunks.dropFirst(index + 1), after: row)
                    } catch let enqueueError {
                        // A chunk that is neither sent nor stored must not
                        // pass as queued: the caller rolls the removal back.
                        HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: enqueueError)))")
                        failure = HLError.notPersisted(String(describing: err))
                    }
                }
                if anyChunkLanded {
                    // Rows a landed chunk removed must not linger in cached
                    // pages even though the overall call failed.
                    await invalidateAfterWriteAllKinds()
                }
                throw failure
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

    /// `{ restored: n }` success body of the restore route.
    struct RestoreResponse: Codable {
        let restored: Int
    }

    /// Body of `POST /api/measurements/restore` (`{ ids }`, strict).
    struct RestoreRequest: Codable {
        let ids: [String]
    }

    /// The delete-Undo counterpart of the bulk delete
    /// (`POST /api/measurements/restore`, v1.16.4). From server 1.46.2 one
    /// blood-pressure half brings back every row deleted with it (the other
    /// half and the pulse). Not queued on failure: the caller shows the error
    /// and the reading stays deleted, which a later restore can still undo.
    ///
    /// Returns the number of rows the server un-tombstoned.
    @discardableResult
    public func restore(ids requested: [String]) async throws -> Int {
        let ids = requested.filter { !Measurement.isSyntheticServerRowID($0) }
        guard !ids.isEmpty else { return 0 }
        precondition(ids.count <= Self.bulkDeleteMaxIDsPerBatch, "measurement restore capped at 200")
        let req: APIRequest<RestoreResponse> = try .post(
            "/api/measurements/restore",
            body: RestoreRequest(ids: ids),
            idempotencyKey: IdempotencyKey()
        )
        let restored = try await api.send(req).restored
        await invalidateAfterWriteAllKinds()
        return restored
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

    /// Queues the chunks that were never sent, all of them or none. When one
    /// cannot be stored, what this call has queued so far is taken back, the
    /// failed chunk included: the caller hears "not saved" and shows every row
    /// again, and a chunk left in the queue would delete some of them later.
    /// A delete is safe to ask for again.
    private func enqueueUnsent(_ unsent: ArraySlice<[String]>, after failedRow: UUID) async throws {
        var queued = [failedRow]
        do {
            for chunk in unsent {
                let op = try Self.bulkDeleteOperation(chunk, idempotencyKey: IdempotencyKey())
                try await outbox.enqueue(op)
                queued.append(op.id)
            }
        } catch {
            for id in queued {
                try? await outbox.remove(id: id)
            }
            throw error
        }
    }

    private static func bulkDeleteOperation(
        _ ids: [String],
        idempotencyKey: IdempotencyKey,
        row: UUID = UUID()
    ) throws -> OutboxQueue.Operation {
        let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.BulkDeleteMeasurements(ids: ids))
        return OutboxQueue.Operation(id: row, kind: .bulkDeleteMeasurements, payload: payload, idempotencyKey: idempotencyKey.raw)
    }
}
