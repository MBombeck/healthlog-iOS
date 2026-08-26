import Foundation

/// Actor repository for the v1.25 structured-records FAMILY-HISTORY surface
/// (`/api/family-history`, `…/{id}`). Mirrors ``AllergiesRepository`` exactly:
/// SWR cache-first reads when a coordinator is supplied (QOL-OFF-2 — offline
/// readability), optimistic outbox-backed writes, the persisted idempotency key
/// making a replay-after-landed duplicate-safe (server dedups a create within
/// 24h; PATCH is idempotent; the soft-delete is tombstone-idempotent). Every
/// successful write invalidates `.familyHistory`. No restore endpoint — the store
/// uses a deferred-delete undo.
public actor FamilyHistoryRepository {
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

    /// True when an `HLError` is a `404` (a tombstoned / cross-user id).
    public nonisolated static func isNotFound(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 404
        }
        return false
    }

    // MARK: - Reads

    /// `GET /api/family-history` — the caller's entries, newest-first.
    /// SWR cache-first (`.familyHistory`) for offline readability (QOL-OFF-2).
    public func list(limit: Int = 100) async throws -> [FamilyHistoryEntryDTO] {
        let api = api
        let query: [(String, String)] = [("limit", String(limit))]
        @Sendable func networkFetch() async throws -> [FamilyHistoryEntryDTO] {
            let req: APIRequest<[FamilyHistoryEntryDTO]> = .get("/api/family-history", query: query)
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .familyHistory,
                decoding: [FamilyHistoryEntryDTO].self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/family-history/{id}` — single owned entry (incl. decrypted note).
    public func get(id: String) async throws -> FamilyHistoryEntryDTO {
        let req: APIRequest<FamilyHistoryEntryDTO> = .get("/api/family-history/\(id)")
        return try await api.send(req)
    }

    // MARK: - Writes (optimistic; idempotency-keyed; outbox-backed)

    /// `POST /api/family-history`. Returns the created entry. Outbox-backed.
    ///
    /// `clientEntityId` (audit-v0162 H-4) — the store's `optimistic-<uuid>` id,
    /// stamped on the queued create so a queued offline edit/delete is remapped
    /// to the server id once this replays.
    @discardableResult
    public func create(_ body: FamilyHistoryCreate, clientEntityId: String? = nil) async throws -> FamilyHistoryEntryDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<FamilyHistoryEntryDTO> = try .post("/api/family-history", body: body, idempotencyKey: key)
            let created = try await api.send(req)
            await invalidate([.familyHistory])
            return created
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .createFamilyHistory, payload: OutboxQueue.Payloads.CreateFamilyHistory(body: body),
                key: key, clientEntityId: clientEntityId
            )
            throw err
        }
    }

    /// Replay drain for `createFamilyHistory`.
    public func replayCreate(_ body: FamilyHistoryCreate, idempotencyKey: String) async throws {
        _ = try await replayCreateReturningServerId(body, idempotencyKey: idempotencyKey)
    }

    /// audit-v0162 H-4 — replay drain returning the server-assigned id.
    @discardableResult
    public func replayCreateReturningServerId(_ body: FamilyHistoryCreate, idempotencyKey: String) async throws -> String {
        let req: APIRequest<FamilyHistoryEntryDTO> = try .post(
            "/api/family-history", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await api.send(req).id
    }

    /// `PATCH /api/family-history/{id}` partial edit. Returns the updated entry.
    @discardableResult
    public func update(id: String, _ patch: FamilyHistoryPatch) async throws -> FamilyHistoryEntryDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<FamilyHistoryEntryDTO> = try .patch("/api/family-history/\(id)", body: patch, idempotencyKey: key)
            let updated = try await api.send(req)
            await invalidate([.familyHistory])
            return updated
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .updateFamilyHistory, payload: OutboxQueue.Payloads.UpdateFamilyHistory(id: id, patch: patch),
                key: key, clientEntityId: id
            )
            throw err
        }
    }

    /// Replay drain for `updateFamilyHistory`.
    public func replayUpdate(id: String, _ patch: FamilyHistoryPatch, idempotencyKey: String) async throws {
        let req: APIRequest<FamilyHistoryEntryDTO> = try .patch(
            "/api/family-history/\(id)", body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/family-history/{id}` (soft, idempotent). Returns the server's
    /// `deleted` flag. Outbox-backed.
    @discardableResult
    public func delete(id: String) async throws -> Bool {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<DeleteRecordResult> = .delete("/api/family-history/\(id)", idempotencyKey: key)
            let deleted = try await api.send(req).deleted
            await invalidate([.familyHistory])
            return deleted
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .deleteFamilyHistory, payload: OutboxQueue.Payloads.DeleteFamilyHistory(id: id),
                key: key, clientEntityId: id
            )
            throw err
        }
    }

    /// Replay drain for `deleteFamilyHistory`.
    public func replayDelete(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeleteRecordResult> = .delete(
            "/api/family-history/\(id)", idempotencyKey: IdempotencyKey(raw: idempotencyKey)
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
            HLLog.outbox.error("Family-history outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
