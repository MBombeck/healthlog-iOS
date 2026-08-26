import Foundation

/// Actor repository for the v1.25 structured-records ALLERGY surface
/// (`/api/allergies`, `…/{id}`). Mirrors ``LabsRepository``: SWR cache-first reads
/// when a coordinator is supplied (QOL-OFF-2 — the allergy list paints from disk
/// on a cold offline launch instead of the empty "add your first…" state),
/// optimistic outbox-backed writes through `APIClient`. Every successful write
/// invalidates `.allergies` so a mutation is never masked by a fresh-enough
/// cached row; logout purges every row via `SWRCoordinator.invalidateAll()`.
///
/// **Outbox durability (PHI).** Every write is outbox-backed: on a retriable
/// network failure (`HLError.shouldPersistToOutbox`) the write is persisted to
/// the encrypted `OutboxQueue` under its idempotency key and the typed `HLError`
/// is re-thrown (the store keeps its optimistic state). `OutboxReplayService`
/// drains the allergy kinds at reachability, re-issuing the identical request
/// under the persisted key. The server `withIdempotency` dedups a create within
/// 24h; PATCH is naturally idempotent; the soft-delete is tombstone-idempotent —
/// a replay-after-landed is always safe.
///
/// **No restore endpoint** (unlike illness): the soft-delete has no inverse, so
/// the store uses a deferred-delete undo (fire DELETE only after the undo window
/// expires) rather than a lossless restore.
public actor AllergiesRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    private let swr: SWRCoordinator?

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.swr = swr
    }

    /// True when an `HLError` is a `404` (a tombstoned / cross-user id). Callers
    /// tolerate this rather than surfacing an error.
    public nonisolated static func isNotFound(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 404
        }
        return false
    }

    // MARK: - Reads

    /// `GET /api/allergies` — the caller's live allergies, newest-first.
    /// `includeInactive == false` returns only `status=ACTIVE`; the default
    /// (param omitted / `true`) returns all non-deleted.
    ///
    /// **QOL-OFF-2:** the canonical all-non-deleted read (`includeInactive != false`,
    /// the store's default) routes through `swr.fetchCachingFirst(.allergies)` so
    /// the list is offline-readable. The `includeInactive == false` (active-only)
    /// variant stays network-direct.
    public func list(limit: Int = 100, includeInactive: Bool? = nil) async throws -> [AllergyDTO] {
        let api = api
        var query: [(String, String)] = [("limit", String(limit))]
        if let includeInactive {
            query.append(("includeInactive", includeInactive ? "true" : "false"))
        }
        let frozenQuery = query
        @Sendable func networkFetch() async throws -> [AllergyDTO] {
            let req: APIRequest<[AllergyDTO]> = .get("/api/allergies", query: frozenQuery)
            return try await api.send(req)
        }
        if let swr, includeInactive != false {
            return try await swr.fetchCachingFirst(
                .allergies,
                decoding: [AllergyDTO].self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/allergies/{id}` — single owned record (incl. decrypted PHI).
    public func get(id: String) async throws -> AllergyDTO {
        let req: APIRequest<AllergyDTO> = .get("/api/allergies/\(id)")
        return try await api.send(req)
    }

    // MARK: - Writes (optimistic; idempotency-keyed; outbox-backed)

    /// `POST /api/allergies`. Returns the created record. Outbox-backed.
    ///
    /// `clientEntityId` (audit-v0162 H-4) — the `optimistic-<uuid>` id the store
    /// minted for its in-memory placeholder. Stamped on the queued create so that
    /// when this replays and the server assigns a real id, `OutboxReplayService`
    /// can remap any queued offline edit/delete of the same record to the server
    /// id (instead of 404-ing on the optimistic id).
    @discardableResult
    public func create(_ body: AllergyCreate, clientEntityId: String? = nil) async throws -> AllergyDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<AllergyDTO> = try .post("/api/allergies", body: body, idempotencyKey: key)
            let created = try await api.send(req)
            await invalidate([.allergies])
            return created
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .createAllergy, payload: OutboxQueue.Payloads.CreateAllergy(body: body),
                key: key, clientEntityId: clientEntityId
            )
            throw err
        }
    }

    /// Replay drain for `createAllergy`.
    public func replayCreate(_ body: AllergyCreate, idempotencyKey: String) async throws {
        _ = try await replayCreateReturningServerId(body, idempotencyKey: idempotencyKey)
    }

    /// audit-v0162 H-4 — replay drain that returns the server-assigned id so the
    /// replay service can remap dependent update/delete ops off the optimistic id.
    @discardableResult
    public func replayCreateReturningServerId(_ body: AllergyCreate, idempotencyKey: String) async throws -> String {
        let req: APIRequest<AllergyDTO> = try .post(
            "/api/allergies", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await api.send(req).id
    }

    /// `PATCH /api/allergies/{id}` partial edit. Returns the updated record.
    @discardableResult
    public func update(id: String, _ patch: AllergyPatch) async throws -> AllergyDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<AllergyDTO> = try .patch("/api/allergies/\(id)", body: patch, idempotencyKey: key)
            let updated = try await api.send(req)
            await invalidate([.allergies])
            return updated
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .updateAllergy, payload: OutboxQueue.Payloads.UpdateAllergy(id: id, patch: patch),
                key: key, clientEntityId: id
            )
            throw err
        }
    }

    /// Replay drain for `updateAllergy`.
    public func replayUpdate(id: String, _ patch: AllergyPatch, idempotencyKey: String) async throws {
        let req: APIRequest<AllergyDTO> = try .patch(
            "/api/allergies/\(id)", body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/allergies/{id}` (soft, idempotent). Returns the server's
    /// `deleted` flag. Outbox-backed.
    @discardableResult
    public func delete(id: String) async throws -> Bool {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<DeleteRecordResult> = .delete("/api/allergies/\(id)", idempotencyKey: key)
            let deleted = try await api.send(req).deleted
            await invalidate([.allergies])
            return deleted
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .deleteAllergy, payload: OutboxQueue.Payloads.DeleteAllergy(id: id),
                key: key, clientEntityId: id
            )
            throw err
        }
    }

    /// Replay drain for `deleteAllergy`.
    public func replayDelete(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeleteRecordResult> = .delete(
            "/api/allergies/\(id)", idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Cache invalidation (QOL-OFF-2)

    /// Drop the cached list snapshot after a successful write so a mutation is
    /// never masked by a fresh-enough cached row. No-op without a coordinator.
    private func invalidate(_ keys: [CacheKey]) async {
        await swr?.invalidate(keys)
    }

    // MARK: - Outbox enqueue helper

    /// Persist a retriable failed write to the encrypted outbox under its
    /// idempotency key. A persistence failure is logged (sanitized) + swallowed;
    /// the original `HLError` is the one re-thrown (mirrors `IllnessRepository`).
    private func enqueue(
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey,
        clientEntityId: String? = nil
    ) async {
        do {
            let data = try encoder.encode(payload)
            try await outbox.enqueue(.init(
                kind: kind, payload: data, idempotencyKey: key.raw, clientEntityId: clientEntityId
            ))
        } catch {
            HLLog.outbox.error("Allergy outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
