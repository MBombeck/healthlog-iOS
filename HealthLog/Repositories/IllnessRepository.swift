import Foundation

/// Actor repository for the v1.18.1 illness / condition-journal surface
/// (`/api/illness/episodes`, `…/{id}`, `…/{id}/resolve`, `…/{id}/day-logs`,
/// `…/{id}/correlation`, `/api/illness/insights`). Clones the
/// ``CycleRepository`` / ``LabsRepository`` posture: optimistic writes through
/// `APIClient`, SWR cache-first reads (when a coordinator is supplied), and a
/// clean `illness.disabled` (403) discriminator so a user-disabled account
/// renders the re-enable surface instead of a hard error.
///
/// **Default-ON (v1.18.3).** The born-gating was dropped — the whole surface
/// gates on `ModuleGate.isEnabled(.illness)` (now default-ON). Every route still
/// 403s with `meta.errorCode: "illness.disabled"` + `meta.module: "illness"` when
/// a user has *disabled* the module (or the operator disabled it server-wide).
/// ``isIllnessDisabled(_:)`` recognises that 403 so the store can render the
/// re-enable / disabled state.
///
/// **Correlation + insights are SERVER-COMPUTED, render-only.** This layer never
/// recomputes a baseline, a deviation, or a recovery gap — it decodes the
/// `Derived<T>` (`IllnessCorrelationDTO`) and the insights summary and passes
/// them through untouched. The two derived endpoints are tolerated DEFENSIVELY
/// (an empty / 404 / not-yet-deployed response surfaces as a "not enough data
/// yet" state, never a crash) — deployment confirmation is pending (see Q1).
///
/// **Outbox durability (v1.18.6 PHI).** Every write is now outbox-backed: on a
/// retriable network failure (`HLError.shouldPersistToOutbox`) the write is
/// persisted to the encrypted `OutboxQueue` under its idempotency key and the
/// typed `HLError` is re-thrown (the store keeps its optimistic state + surfaces
/// the offline banner / undo window). `OutboxReplayService` drains the illness
/// kinds at reachability, re-issuing the identical request under the persisted
/// key (server dedups within 24h; soft-delete + restore + day-log UPSERT are
/// idempotent). The `replay*` entry points are the drain seams. A
/// `illness.disabled` 403 is NEVER enqueued (no retry).
///
/// **No HealthKit / externalId dedup, no sync-changes feed** (web-capture
/// parity; day-logs have no syncVersion).
public actor IllnessRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder

    /// **Cache note (W-B B1).** SWR cache-first reads want dedicated `CacheKey`
    /// cases (`.illnessEpisodes(includeResolved:)` / `.illnessCorrelation` /
    /// `.illnessInsights`) — but `Cache/CacheKey.swift` is a shared chokepoint
    /// owned by the reconcile pass, so this repository reads network-direct for
    /// now (mirrors `LabsRepository`). When the cache keys land, route the reads
    /// through `swr.fetchCachingFirst` — see the reconcile spec.
    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
    }

    /// True when an `HLError` is the server's `403 illness.disabled` envelope
    /// (the user disabled the module, or the operator disabled it server-wide).
    /// Callers map this to the re-enable / disabled surface (no retry, no
    /// outbox).
    ///
    /// **Detection.** The server stamps `meta.errorCode: "illness.disabled"` +
    /// `meta.module: "illness"`. `APIClient.ensureSuccess` only types the
    /// `meta.errorCode == "module.disabled"` shape into
    /// `HLError.moduleDisabled`; the illness-specific `errorCode` falls through
    /// to the generic `HLError.server(403, …)`. Every `/api/illness/*` route's
    /// ONLY documented 403 is the disabled gate, so a 403 here is unambiguous.
    /// We also tolerate the typed `.moduleDisabled("illness")` form defensively
    /// in case the server normalises the errorCode later.
    public nonisolated static func isIllnessDisabled(_ error: Error) -> Bool {
        if case let HLError.moduleDisabled(module) = error {
            return module == "illness"
        }
        if case let HLError.server(status, code, _) = error {
            return status == 403 && (code == nil || code == "illness.disabled")
        }
        return false
    }

    /// True when an `HLError` is the resolve route's `422
    /// illness.episode.chronic-no-resolve` (a `CHRONIC_ONGOING` episode has no
    /// recovery date). Maps to an inline message; the UI also hides the resolve
    /// action for that lifecycle up-front.
    public nonisolated static func isChronicNoResolve(_ error: Error) -> Bool {
        if case let HLError.server(status, code, message) = error {
            return status == 422 &&
                (code == "illness.episode.chronic-no-resolve" ||
                    message.contains("chronic-no-resolve"))
        }
        return false
    }

    /// True when an `HLError` is a `404` (a tombstoned / cross-user episode id).
    /// The derived endpoints tolerate this as "not enough data yet" rather than
    /// surfacing an error.
    public nonisolated static func isNotFound(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 404
        }
        return false
    }

    // MARK: - Reads (SWR cache-first when a coordinator is supplied)

    /// `GET /api/illness/episodes` — the caller's live episodes, newest-first by
    /// onset. `includeResolved=false` hides resolved episodes.
    public func episodes(limit: Int = 100, includeResolved: Bool = true) async throws -> [IllnessEpisodeDTO] {
        let api = api
        let query: [(String, String)] = [
            ("limit", String(limit)),
            ("includeResolved", includeResolved ? "true" : "false")
        ]
        let frozenQuery = query
        let req: APIRequest<[IllnessEpisodeDTO]> = .get("/api/illness/episodes", query: frozenQuery)
        return try await api.send(req)
    }

    /// `GET /api/illness/episodes/{id}` — single episode incl. the decrypted note.
    public func episode(id: String) async throws -> IllnessEpisodeDTO {
        let req: APIRequest<IllnessEpisodeDTO> = .get("/api/illness/episodes/\(id)")
        return try await api.send(req)
    }

    /// `GET /api/illness/episodes/{id}/day-logs?date=` — the day-log for that
    /// date, or `nil` when nothing is logged (pre-fills the log-day sheet). The
    /// route returns `data: IllnessDayLog | null`; `APIClient.send` extracts the
    /// envelope `data`, so an optional decode handles the null.
    public func dayLog(episodeId: String, date: String) async throws -> IllnessDayLogDTO? {
        let req: APIRequest<IllnessDayLogNullable> = .get(
            "/api/illness/episodes/\(episodeId)/day-logs",
            query: [("date", date)]
        )
        return try await api.send(req).dayLog
    }

    /// `GET /api/illness/episodes/{id}/day-logs` (no `date`) — the date-less LIST
    /// (v1.18.3): the episode's full day-log history, newest-first by default
    /// (`sortDir:"asc"` flips to oldest-first), paged via `limit`/`offset` with
    /// `meta.total`. Returns `data: { dayLogs, meta }`; `APIClient.send` strips
    /// the envelope and decodes the ``IllnessDayLogList`` directly.
    public func dayLogs(
        episodeId: String,
        limit: Int = 200,
        offset: Int = 0,
        sortDir: String? = nil
    ) async throws -> IllnessDayLogList {
        var query: [(String, String)] = [
            ("limit", String(limit)),
            ("offset", String(offset))
        ]
        if let sortDir { query.append(("sortDir", sortDir)) }
        let frozenQuery = query
        let req: APIRequest<IllnessDayLogList> = .get(
            "/api/illness/episodes/\(episodeId)/day-logs",
            query: frozenQuery
        )
        return try await api.send(req)
    }

    /// `GET /api/illness/episodes/{id}/correlation` — the coverage-gated
    /// `Derived<T>` for one episode (server-computed). Cache-first with a short
    /// TTL via the coordinator. Render-only; iOS computes NO baseline.
    public func correlation(episodeId: String) async throws -> IllnessCorrelationDTO {
        let req: APIRequest<IllnessCorrelationDTO> = .get("/api/illness/episodes/\(episodeId)/correlation")
        return try await api.send(req)
    }

    /// `GET /api/illness/insights` — cross-episode retrospective summary.
    /// Recovery-gap computation is expensive and opt-in; ordinary callers keep
    /// the explicit `false` default and only the analysis destination requests
    /// it.
    public func insights(
        windowDays: Int? = nil,
        includeRecoveryGap: Bool = false
    ) async throws -> IllnessInsightsDTO {
        var query: [(String, String)] = [
            ("includeRecoveryGap", includeRecoveryGap ? "true" : "false")
        ]
        if let windowDays { query.append(("windowDays", String(windowDays))) }
        let req: APIRequest<IllnessInsightsDTO> = .get("/api/illness/insights", query: query)
        return try await api.send(req)
    }

    // MARK: - Episode writes (optimistic; idempotency-keyed)

    /// `POST /api/illness/episodes`. Returns the created episode. Outbox-backed.
    @discardableResult
    public func createEpisode(_ body: IllnessEpisodeCreate) async throws -> IllnessEpisodeDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<IllnessEpisodeDTO> = try .post("/api/illness/episodes", body: body, idempotencyKey: key)
            return try await api.send(req)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(.createIllnessEpisode, payload: OutboxQueue.Payloads.CreateIllnessEpisode(body: body), key: key)
            throw err
        }
    }

    /// Replay drain for `createIllnessEpisode`.
    public func replayCreateEpisode(_ body: IllnessEpisodeCreate, idempotencyKey: String) async throws {
        let req: APIRequest<IllnessEpisodeDTO> = try .post(
            "/api/illness/episodes", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `PATCH /api/illness/episodes/{id}` partial edit. Returns the updated episode.
    @discardableResult
    public func updateEpisode(id: String, _ patch: IllnessEpisodePatch) async throws -> IllnessEpisodeDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<IllnessEpisodeDTO> = try .patch("/api/illness/episodes/\(id)", body: patch, idempotencyKey: key)
            return try await api.send(req)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(.updateIllnessEpisode, payload: OutboxQueue.Payloads.UpdateIllnessEpisode(id: id, patch: patch), key: key)
            throw err
        }
    }

    /// Replay drain for `updateIllnessEpisode`.
    public func replayUpdateEpisode(id: String, _ patch: IllnessEpisodePatch, idempotencyKey: String) async throws {
        let req: APIRequest<IllnessEpisodeDTO> = try .patch(
            "/api/illness/episodes/\(id)", body: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `DELETE /api/illness/episodes/{id}` (soft, idempotent — a re-delete is a
    /// no-op). v1.18.3 returns `200 { data: { deleted: true }, error: null }`
    /// (was a bare `204`); we decode the tolerant ``DeleteIllnessEpisodeResult``
    /// so the 200-with-body never breaks the call. Undo is now LOSSLESS via
    /// ``restore(id:)`` (the same id + day-logs re-surface) — see the store.
    @discardableResult
    public func deleteEpisode(id: String) async throws -> Bool {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<DeleteIllnessEpisodeResult> = .delete("/api/illness/episodes/\(id)", idempotencyKey: key)
            return try await api.send(req).deleted
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(.deleteIllnessEpisode, payload: OutboxQueue.Payloads.DeleteIllnessEpisode(id: id), key: key)
            throw err
        }
    }

    /// Replay drain for `deleteIllnessEpisode`.
    public func replayDeleteEpisode(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<DeleteIllnessEpisodeResult> = .delete(
            "/api/illness/episodes/\(id)", idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `POST /api/illness/episodes/{id}/restore` (no body) — clears `deletedAt`,
    /// re-surfacing the episode + its day-logs + encrypted note INTACT (a pure
    /// flag flip; nothing is re-created). Idempotent — restoring a live episode
    /// is a no-op. Powers the lossless delete-undo. Returns the restored episode.
    @discardableResult
    public func restore(id: String) async throws -> IllnessEpisodeDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<IllnessEpisodeDTO> = try .post(
                "/api/illness/episodes/\(id)/restore", body: EmptyPayload(), idempotencyKey: key
            )
            return try await api.send(req)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(.restoreIllnessEpisode, payload: OutboxQueue.Payloads.RestoreIllnessEpisode(id: id), key: key)
            throw err
        }
    }

    /// Replay drain for `restoreIllnessEpisode`.
    public func replayRestore(id: String, idempotencyKey: String) async throws {
        let req: APIRequest<IllnessEpisodeDTO> = try .post(
            "/api/illness/episodes/\(id)/restore", body: EmptyPayload(), idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    /// `PATCH /api/illness/episodes/{id}/resolve`. Stamps `resolvedAt` (defaults
    /// to 'now' when the body omits it). A `CHRONIC_ONGOING` episode 422s with
    /// `illness.episode.chronic-no-resolve` (``isChronicNoResolve(_:)``).
    @discardableResult
    public func resolveEpisode(id: String, resolvedAt: String? = nil) async throws -> IllnessEpisodeDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<IllnessEpisodeDTO> = try .patch(
                "/api/illness/episodes/\(id)/resolve", body: IllnessResolveBody(resolvedAt: resolvedAt), idempotencyKey: key
            )
            return try await api.send(req)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .resolveIllnessEpisode,
                payload: OutboxQueue.Payloads.ResolveIllnessEpisode(id: id, resolvedAt: resolvedAt),
                key: key
            )
            throw err
        }
    }

    /// Replay drain for `resolveIllnessEpisode`.
    public func replayResolveEpisode(id: String, resolvedAt: String?, idempotencyKey: String) async throws {
        let req: APIRequest<IllnessEpisodeDTO> = try .patch(
            "/api/illness/episodes/\(id)/resolve",
            body: IllnessResolveBody(resolvedAt: resolvedAt),
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Day-log upsert (optimistic; idempotency-keyed; outbox-backed)

    /// `POST /api/illness/episodes/{id}/day-logs` — upsert on `(episodeId,
    /// date)`: 201 insert / 200 update. Returns the stored day-log either way
    /// (`APIClient.send` decodes the `data` envelope regardless of 200/201).
    @discardableResult
    public func upsertDayLog(episodeId: String, _ body: IllnessDayLogUpsert) async throws -> IllnessDayLogDTO {
        let key = IdempotencyKey()
        do {
            let req: APIRequest<IllnessDayLogDTO> = try .post(
                "/api/illness/episodes/\(episodeId)/day-logs", body: body, idempotencyKey: key
            )
            return try await api.send(req)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .upsertIllnessDayLog,
                payload: OutboxQueue.Payloads.UpsertIllnessDayLog(episodeId: episodeId, body: body),
                key: key
            )
            throw err
        }
    }

    /// Replay drain for `upsertIllnessDayLog`.
    public func replayUpsertDayLog(episodeId: String, _ body: IllnessDayLogUpsert, idempotencyKey: String) async throws {
        let req: APIRequest<IllnessDayLogDTO> = try .post(
            "/api/illness/episodes/\(episodeId)/day-logs", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Outbox enqueue helper

    /// Persist a retriable failed write to the encrypted outbox under its
    /// idempotency key. A persistence failure is logged (sanitized) + swallowed;
    /// the original `HLError` is the one re-thrown (mirrors `LabsRepository`).
    private func enqueue(
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey
    ) async {
        do {
            let data = try encoder.encode(payload)
            try await outbox.enqueue(.init(kind: kind, payload: data, idempotencyKey: key.raw))
        } catch {
            HLLog.outbox.error("Illness outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
