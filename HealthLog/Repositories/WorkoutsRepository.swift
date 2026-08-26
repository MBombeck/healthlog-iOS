import Foundation

protocol WorkoutBatchUploading: Sendable {
    func uploadBatch(
        _ workouts: [WorkoutIngestDTO],
        ownerUserID: String
    ) async throws -> WorkoutBatchResponseDTO
}

/// Wraps `GET /api/workouts` and `GET /api/workouts/{id}` (server
/// v1.4.32, route at `src/app/api/workouts/route.ts`).
///
/// The list path runs the cross-source canonical-row picker server-
/// side, so the iOS client never sees twin workouts (Apple Watch +
/// Withings publishing the same session collapse to one row). The
/// per-user source ladder lives behind `/api/auth/me/source-priority`
/// and governs which source wins each cluster.
///
/// **SWR / Stale-while-revalidate:** in-memory keyed cache with a 60-
/// second TTL. Two arms:
///   1. cache fresh → return immediately, no network
///   2. cache stale (or absent) → fire a network read; on success
///      replace the cache slot; on failure return the stale snapshot
///      if one exists, otherwise throw.
///
/// Page-cache key is built from the full query tuple (limit, offset,
/// since, until, sportType) so different views sharing the repo don't
/// step on each other's slices.
///
/// **Detail path (`workout(id:)`):** separate cache slot keyed on the
/// workout id. Same TTL.
public actor WorkoutsRepository: WorkoutBatchUploading {
    private let api: APIClientProtocol
    /// Outbox-Mandate (audit v0.14.8 C4.1): a retriably-failed batch upload
    /// enrolls here with its already-used idempotency key so replay fires on
    /// reachability/foreground (not just the next HK observer wakeup) and the
    /// server's 24h `(userId, key, method, path)` dedup stays effective
    /// across app restarts. Mirrors the `CycleRepository` posture 1:1.
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private struct CachedList {
        let payload: WorkoutListResponseDTO
        let cachedAt: Date
    }

    private struct CachedDetail {
        let payload: WorkoutListEntryDTO
        let cachedAt: Date
    }

    private var listCache: [String: CachedList] = [:]
    private var detailCache: [String: CachedDetail] = [:]

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        cacheTTL: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    /// Lists workouts. `limit` defaults to the server's own default (50)
    /// + the server clamps to 200 max. `since` / `until` are ISO-8601
    /// inclusive; nil means open-ended.
    ///
    /// SWR ladder: cache fresh → return. Cache stale → network. Network
    /// fails with stale present → return stale + log. Network fails
    /// with no cache → throw.
    public func list(
        limit: Int = 50,
        offset: Int = 0,
        since: Date? = nil,
        until: Date? = nil,
        sportType: String? = nil
    ) async throws -> WorkoutListResponseDTO {
        let key = Self.cacheKey(limit: limit, offset: offset, since: since, until: until, sportType: sportType)
        if let entry = listCache[key], clock().timeIntervalSince(entry.cachedAt) < cacheTTL {
            return entry.payload
        }
        do {
            var query: [(String, String)] = [
                ("limit", String(limit)),
                ("offset", String(offset))
            ]
            if let since {
                query.append(("since", ISO8601DateFormatter.fractional.string(from: since)))
            }
            if let until {
                query.append(("until", ISO8601DateFormatter.fractional.string(from: until)))
            }
            if let sportType {
                query.append(("sportType", sportType))
            }
            let req: APIRequest<WorkoutListResponseDTO> = .get("/api/workouts", query: query)
            let payload = try await api.send(req)
            listCache[key] = CachedList(payload: payload, cachedAt: clock())
            return payload
        } catch {
            if let stale = listCache[key]?.payload {
                HLLog.api.warning(
                    "WorkoutsRepository.list fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// Fetches a single workout by id. SWR with the same 60s TTL.
    public func workout(id: String) async throws -> WorkoutListEntryDTO {
        if let entry = detailCache[id], clock().timeIntervalSince(entry.cachedAt) < cacheTTL {
            return entry.payload
        }
        do {
            let req: APIRequest<WorkoutListEntryDTO> = .get("/api/workouts/\(id)")
            let payload = try await api.send(req)
            detailCache[id] = CachedDetail(payload: payload, cachedAt: clock())
            return payload
        } catch {
            if let stale = detailCache[id]?.payload {
                HLLog.api.warning(
                    "WorkoutsRepository.workout(id:) fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// **v1.15 W-WORKOUT — workout ingest.** POSTs a batch of HK-sourced
    /// workouts to `POST /api/workouts/batch` (server schema
    /// `createBatchWorkoutSchema`). The `Idempotency-Key` header replays
    /// the cached envelope on retry (24h window) and the server's
    /// `@@unique([userId, source, externalId])` index upserts re-posted
    /// rows to `duplicate` rather than inserting twins — so a doubly-
    /// delivered observer wakeup is idempotent on both layers.
    ///
    /// On a successful POST the read-side caches are invalidated so the
    /// next `list()` goes to the wire and the freshly-ingested workouts
    /// surface immediately in the UI rather than serving a stale slice.
    ///
    /// **Outbox enrollment (audit v0.14.8 C4.1).** On a retriable failure
    /// (`shouldPersistToOutbox`) the batch enqueues as `.uploadWorkoutBatch`
    /// carrying the SAME idempotency key that was just used on the wire, then
    /// rethrows (CycleRepository pattern). Replay re-POSTs under that
    /// persisted key on the next reachability/foreground edge — instead of
    /// waiting for the next HK observer fire. The importer additionally keeps
    /// its anchor on failure, so a dead-lettered outbox row can never lose
    /// data: the next sweep re-fetches and the externalId UPSERT dedupes
    /// whichever path lands second.
    ///
    /// The caller chunks to the server's 100-workout batch cap; this
    /// method posts whatever it's handed (`api.send` throws on a non-2xx).
    public func uploadBatch(_ workouts: [WorkoutIngestDTO]) async throws -> WorkoutBatchResponseDTO {
        try await uploadBatch(workouts, authLease: nil)
    }

    /// Account-leased upload used by long-running HealthKit history work. The
    /// owner is captured before any suspension and is carried into durable
    /// recovery; it is never re-resolved from a possibly different login.
    public func uploadBatch(
        _ workouts: [WorkoutIngestDTO],
        ownerUserID: String
    ) async throws -> WorkoutBatchResponseDTO {
        let lease = try await outbox.captureAuthLease(requiringOwner: ownerUserID)
        return try await uploadBatch(workouts, authLease: lease)
    }

    private func uploadBatch(
        _ workouts: [WorkoutIngestDTO],
        authLease: OutboxQueue.AuthLease?
    ) async throws -> WorkoutBatchResponseDTO {
        let idempotencyKey = IdempotencyKey()
        do {
            return try await postBatch(workouts, idempotencyKey: idempotencyKey, authLease: authLease)
        } catch let err as HLError where err.shouldPersistToOutbox {
            try await enqueue(
                .uploadWorkoutBatch,
                OutboxQueue.Payloads.UploadWorkoutBatch(workouts: workouts),
                idempotencyKey,
                authLease: authLease
            )
            throw err
        }
    }

    // MARK: - Outbox replay path

    /// Replays a persisted `.uploadWorkoutBatch` op under its persisted
    /// idempotency key (24h server-side envelope dedup; externalId UPSERT
    /// dedupes beyond that window). Called by `OutboxReplayService.dispatch`.
    @discardableResult
    public func replayUploadBatch(
        _ workouts: [WorkoutIngestDTO],
        idempotencyKey: String
    ) async throws -> WorkoutBatchResponseDTO {
        try await postBatch(workouts, idempotencyKey: IdempotencyKey(raw: idempotencyKey), authLease: nil)
    }

    /// Account-leased replay path. The captured bearer is pinned into the
    /// request so APIClient's one-shot 401 retry cannot rebuild A's workout
    /// envelope with a replacement account's credential.
    @discardableResult
    public func replayUploadBatch(
        _ workouts: [WorkoutIngestDTO],
        idempotencyKey: String,
        authLease: OutboxQueue.AuthLease
    ) async throws -> WorkoutBatchResponseDTO {
        try await postBatch(
            workouts,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey),
            authLease: authLease
        )
    }

    /// Test hook: drop all cached entries so the next read goes to the wire.
    public func invalidateCache() {
        listCache.removeAll()
        detailCache.removeAll()
    }

    // MARK: - Private request helpers

    /// Single wire path shared by the optimistic POST and the outbox replay —
    /// guarantees both legs send the identical body + encoder, differing only
    /// in where the idempotency key comes from (fresh vs persisted).
    private func postBatch(
        _ workouts: [WorkoutIngestDTO],
        idempotencyKey: IdempotencyKey,
        authLease: OutboxQueue.AuthLease?
    ) async throws -> WorkoutBatchResponseDTO {
        let payload = WorkoutBatchPayload(workouts: workouts)
        let base: APIRequest<WorkoutBatchResponseDTO> = try .post(
            HealthIngestRoute.workoutsBatch,
            body: payload,
            encoder: .hlBatch,
            idempotencyKey: idempotencyKey
        )
        if let authLease {
            try await outbox.validateAuthLease(authLease)
        }
        let pinnedHeaders: [String: String] = if let authorizationHeader = authLease?.authorizationHeader {
            ["Authorization": authorizationHeader]
        } else {
            base.extraHeaders
        }
        let req = APIRequest<WorkoutBatchResponseDTO>(
            method: base.method,
            path: base.path,
            query: base.query,
            body: base.body,
            extraHeaders: pinnedHeaders,
            idempotencyKey: base.idempotencyKey,
            maxRetries: base.maxRetries,
            failFast: base.failFast,
            streaming: base.streaming,
            // A captured bearer belongs to one account generation. A 401 is
            // retained for a later pass; it must never refresh or log out the
            // process-global session that may now belong to another account.
            allowsAuthenticationRecovery: authLease == nil
        )
        let response: WorkoutBatchResponseDTO
        do {
            response = try await api.send(req)
        } catch {
            // A failed/401 request is also a suspension boundary. Prefer the
            // stale-lease verdict when the session changed while APIClient was
            // retrying; otherwise the original transport/server error stands.
            if let authLease {
                try await outbox.validateAuthLease(authLease)
            }
            throw error
        }
        if let authLease {
            try await outbox.validateAuthLease(authLease)
        }
        // The ingest mutated the server-side list; drop the read caches so
        // the next `list()` / `workout(id:)` re-fetches the new rows.
        invalidateCache()
        return response
    }

    /// Payload-encode errors throw (the DTOs are our own Codable structs).
    /// A SwiftData enqueue failure is surfaced as `.notPersisted`: at that
    /// point neither the server nor the durable retry queue owns the write,
    /// so reporting only the original transport error would falsely imply the
    /// repository's documented retry guarantee still holds.
    private func enqueue(
        _ kind: OutboxQueue.Operation.Kind,
        _ payload: some Encodable & Sendable,
        _ key: IdempotencyKey,
        authLease: OutboxQueue.AuthLease?
    ) async throws {
        let data = try encoder.encode(payload)
        do {
            let operation = OutboxQueue.Operation(
                kind: kind,
                payload: data,
                idempotencyKey: key.raw,
                ownerUserID: authLease?.ownerUserID
            )
            if let authLease {
                try await outbox.enqueue(operation, requiring: authLease)
            } else {
                try await outbox.enqueue(operation)
            }
        } catch {
            HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
            throw HLError.notPersisted(String(describing: error))
        }
    }

    private static func cacheKey(
        limit: Int,
        offset: Int,
        since: Date?,
        until: Date?,
        sportType: String?
    ) -> String {
        let s = since.map { ISO8601DateFormatter.fractional.string(from: $0) } ?? ""
        let u = until.map { ISO8601DateFormatter.fractional.string(from: $0) } ?? ""
        return "\(limit)|\(offset)|\(s)|\(u)|\(sportType ?? "")"
    }
}
