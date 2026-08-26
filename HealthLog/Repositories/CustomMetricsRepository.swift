import Foundation

/// Actor repository for the user-defined custom-metric store (server v1.25.5 —
/// `/api/custom-metrics`, `/{id}`, `/{id}/entries`, `/{id}/entries/{entryId}`).
/// Clones the ``LabsRepository`` posture: optimistic writes through `APIClient`,
/// SWR cache-first on the catalog read, and outbox-backed durability on every
/// write.
///
/// **NO MODULE GATE — verified, not assumed.** The four route files call only
/// `requireAuth()`; there is no `requireModule` / `module.disabled` arm anywhere
/// under `src/app/api/custom-metrics/`, and `custom-metrics` is absent from the
/// server's `MODULE_KEYS` registry (`src/lib/modules/registry.ts`). So there is
/// deliberately no `isDisabled` discriminator here — unlike labs / illness /
/// documents. Custom metrics are available to every authenticated account.
///
/// **Reads.** The metric CATALOG (`GET /api/custom-metrics`) routes through
/// `swr.fetchCachingFirst(.customMetrics)` so the list paints from disk on a
/// cold offline launch. The per-metric ENTRY feed stays network-direct: it is
/// paged + sort-directional, and caching it per `(id, limit, offset, sortDir)`
/// would explode the key space for no offline win the catalog does not already
/// give (same reasoning `LabsRepository` applies to its filtered reads).
///
/// **Outbox durability.** Every write is outbox-backed: on a retriable network
/// failure (`HLError.shouldPersistToOutbox`) the write is persisted to the
/// encrypted `OutboxQueue` under its idempotency key and the typed `HLError` is
/// re-thrown, so the store keeps its optimistic state + surfaces the offline
/// banner. `OutboxReplayService.dispatchCustomMetrics` drains the six kinds at
/// reachability, re-issuing the identical request under the persisted key.
///
/// **Idempotency caveat — deliberate asymmetry.** Only the two POST routes are
/// wrapped in the server's `withIdempotency`; PATCH and DELETE are not. That is
/// safe: a PATCH is naturally idempotent (same body → same end state) and DELETE
/// is tombstone-idempotent for the metric (`deletedAt` stamp) and 404-idempotent
/// for an entry (a replayed hard-delete of an already-deleted row surfaces a 404,
/// which the replay treats as a settled no-op). The client sends the key on
/// every write regardless — an ignored header costs nothing and keeps the outbox
/// payloads uniform.
public actor CustomMetricsRepository {
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

    /// Server page cap on the entries feed (`listCustomMetricEntriesSchema`:
    /// `limit` is `1...500`). Requesting more is a 422, so the client's own
    /// history window must never exceed this.
    public static let entriesPageCap = 500

    /// True when an `HLError` is the per-user `(userId, name)` uniqueness `409`
    /// the metric routes raise on a duplicate NAME. Maps to an inline editor
    /// message rather than a generic failure banner.
    public nonisolated static func isDuplicateName(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 409
        }
        return false
    }

    // MARK: - Reads

    /// `GET /api/custom-metrics` — the caller's metric catalog, name-ordered,
    /// each row enriched with its latest logged value + total entry count.
    /// SWR cache-first for offline readability.
    public func customMetrics() async throws -> ListCustomMetricsResponse {
        let api = api
        @Sendable func networkFetch() async throws -> ListCustomMetricsResponse {
            let req: APIRequest<ListCustomMetricsResponse> = .get("/api/custom-metrics")
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .customMetrics,
                decoding: ListCustomMetricsResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/custom-metrics/{id}` — the bare definition. Note this shape
    /// carries NO `latest` / `entryCount` (the server's `serialiseCustomMetric`
    /// omits both); read the list for those.
    public func customMetric(id: String) async throws -> CustomMetricDTO {
        let req: APIRequest<CustomMetricDTO> = .get("/api/custom-metrics/\(id)")
        return try await api.send(req)
    }

    /// `GET /api/custom-metrics/{id}/entries` — the value feed with offset
    /// pagination. `limit` is clamped to the server's 500 cap so a caller can
    /// never trip a 422 by asking for more.
    public func entries(
        metricID: String,
        limit: Int = 100,
        offset: Int = 0,
        sortDir: String = "desc"
    ) async throws -> ListCustomMetricEntriesResponse {
        let clamped = min(max(limit, 1), Self.entriesPageCap)
        let query: [(String, String)] = [
            ("limit", String(clamped)),
            ("offset", String(max(offset, 0))),
            ("sortDir", sortDir)
        ]
        let req: APIRequest<ListCustomMetricEntriesResponse> = .get(
            "/api/custom-metrics/\(metricID)/entries", query: query
        )
        return try await api.send(req)
    }

    // MARK: - Metric-definition writes

    /// `POST /api/custom-metrics`. A duplicate LIVE name is a `409`
    /// (``isDuplicateName(_:)`` discriminates it); a name matching a
    /// SOFT-DELETED metric REVIVES that row instead, which is why the returned
    /// definition may already carry history.
    @discardableResult
    public func createMetric(_ body: CustomMetricCreate) async throws -> CustomMetricDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<CustomMetricDTO> = try .post(
                "/api/custom-metrics", body: body, idempotencyKey: key
            )
            let created = try await api.send(req)
            await invalidate()
            return created
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .createCustomMetric,
                payload: OutboxQueue.Payloads.CreateCustomMetric(body: body),
                key: key
            )
            throw err
        }
    }

    /// Replay drain for `createCustomMetric`. Returns the server-assigned id so a
    /// queued entry-write against the optimistic metric id can be remapped
    /// (`resolveEntityId`, the audit-v0162 H-4 seam).
    @discardableResult
    public func replayCreateMetricReturningServerId(
        _ body: CustomMetricCreate,
        idempotencyKey: String
    ) async throws -> String {
        let req: APIRequest<CustomMetricDTO> = try .post(
            "/api/custom-metrics", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await api.send(req).id
    }

    /// `PATCH /api/custom-metrics/{id}` partial edit.
    @discardableResult
    public func updateMetric(id: String, _ patch: CustomMetricPatch) async throws -> CustomMetricDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<CustomMetricDTO> = try .patch(
                "/api/custom-metrics/\(id)", body: patch, idempotencyKey: key
            )
            let updated = try await api.send(req)
            await invalidate()
            return updated
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .updateCustomMetric,
                payload: OutboxQueue.Payloads.UpdateCustomMetric(id: id, patch: patch),
                key: key, clientEntityId: id
            )
            throw err
        }
    }

    /// Replay drain for `updateCustomMetric`.
    public func replayUpdateMetric(id: String, _ patch: CustomMetricPatch, idempotencyKey: String) async throws {
        let req: APIRequest<CustomMetricDTO> = try .patch(
            "/api/custom-metrics/\(id)", body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/custom-metrics/{id}` — SOFT delete (stamps `deletedAt`).
    /// The logged values are RETAINED server-side and a later create under the
    /// same name revives both the definition and its history. There is no
    /// restore endpoint, so the client offers no undo-restore (unlike labs).
    public func deleteMetric(id: String) async throws {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<DeletedFlagResponse> = .delete(
                "/api/custom-metrics/\(id)", idempotencyKey: key
            )
            _ = try await api.send(req)
            await invalidate()
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .deleteCustomMetric,
                payload: OutboxQueue.Payloads.DeleteCustomMetric(id: id),
                key: key, clientEntityId: id
            )
            throw err
        }
    }

    /// Replay drain for `deleteCustomMetric` (tombstone-idempotent).
    public func replayDeleteMetric(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeletedFlagResponse> = .delete(
            "/api/custom-metrics/\(id)", idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Entry writes

    /// `POST /api/custom-metrics/{id}/entries` — log a value. The server
    /// snapshots the metric's CURRENT unit onto the row; the client never sends
    /// one.
    @discardableResult
    public func createEntry(metricID: String, _ body: CustomMetricEntryCreate) async throws -> CustomMetricEntryDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<CustomMetricEntryDTO> = try .post(
                "/api/custom-metrics/\(metricID)/entries", body: body, idempotencyKey: key
            )
            let created = try await api.send(req)
            await invalidate()
            return created
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .createCustomMetricEntry,
                payload: OutboxQueue.Payloads.CreateCustomMetricEntry(metricID: metricID, body: body),
                key: key, clientEntityId: metricID
            )
            throw err
        }
    }

    /// Replay drain for `createCustomMetricEntry`. The metric id is resolved by
    /// the replay service before this is called, so an entry queued against an
    /// optimistic metric id lands on the real one.
    public func replayCreateEntry(
        metricID: String,
        _ body: CustomMetricEntryCreate,
        idempotencyKey: String
    ) async throws {
        let req: APIRequest<CustomMetricEntryDTO> = try .post(
            "/api/custom-metrics/\(metricID)/entries",
            body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `PATCH /api/custom-metrics/{id}/entries/{entryId}` partial edit.
    @discardableResult
    public func updateEntry(
        metricID: String,
        entryID: String,
        _ patch: CustomMetricEntryPatch
    ) async throws -> CustomMetricEntryDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<CustomMetricEntryDTO> = try .patch(
                "/api/custom-metrics/\(metricID)/entries/\(entryID)", body: patch, idempotencyKey: key
            )
            let updated = try await api.send(req)
            await invalidate()
            return updated
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .updateCustomMetricEntry,
                payload: OutboxQueue.Payloads.UpdateCustomMetricEntry(
                    metricID: metricID, entryID: entryID, patch: patch
                ),
                key: key, clientEntityId: entryID
            )
            throw err
        }
    }

    /// Replay drain for `updateCustomMetricEntry`.
    public func replayUpdateEntry(
        metricID: String,
        entryID: String,
        _ patch: CustomMetricEntryPatch,
        idempotencyKey: String
    ) async throws {
        let req: APIRequest<CustomMetricEntryDTO> = try .patch(
            "/api/custom-metrics/\(metricID)/entries/\(entryID)",
            body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/custom-metrics/{id}/entries/{entryId}` — HARD delete. Unlike
    /// the metric definition (soft) and lab results (soft + restore), a logged
    /// value is gone for good, so the UI must confirm destructively and must not
    /// promise an undo.
    public func deleteEntry(metricID: String, entryID: String) async throws {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<DeletedFlagResponse> = .delete(
                "/api/custom-metrics/\(metricID)/entries/\(entryID)", idempotencyKey: key
            )
            _ = try await api.send(req)
            await invalidate()
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .deleteCustomMetricEntry,
                payload: OutboxQueue.Payloads.DeleteCustomMetricEntry(metricID: metricID, entryID: entryID),
                key: key, clientEntityId: entryID
            )
            throw err
        }
    }

    /// Replay drain for `deleteCustomMetricEntry`. A replay after the original
    /// landed hits a 404 (the row is already gone) — a settled no-op, not a
    /// failure the queue should retry forever.
    public func replayDeleteEntry(metricID: String, entryID: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeletedFlagResponse> = .delete(
            "/api/custom-metrics/\(metricID)/entries/\(entryID)",
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Private

    /// Drop the cached catalog after any successful write so a mutation is never
    /// masked by a fresh-enough cached row. Entry writes invalidate it too — the
    /// catalog embeds `latest` + `entryCount`, which a value write changes.
    private func invalidate() async {
        await swr?.invalidate([.customMetrics])
    }

    /// Persist a retriable failed write to the encrypted outbox under its
    /// idempotency key. A persistence failure compounds the network failure, so
    /// it is logged (sanitized) and swallowed — the original `HLError` is the one
    /// re-thrown to the caller (mirrors `LabsRepository` / `MeasurementsRepository`).
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
            HLLog.outbox.error(
                "Custom-metrics outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))"
            )
        }
    }
}
