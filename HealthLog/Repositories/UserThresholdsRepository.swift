import Foundation

/// Wraps `GET / PUT /api/user/thresholds` (server route at
/// `src/app/api/user/thresholds/route.ts`).
///
/// The route backs the editable half of the personal-targets surface — the
/// per-user `{ min, max }` band override per metric (`User.thresholdsJson`).
/// The read-only `GET /api/insights/targets` view (current value + trend +
/// consistency strip) is computed *from* these overrides, so a successful
/// PUT here invalidates the targets cache and the next targets fetch surfaces
/// the new band.
///
/// **Cache strategy:** small payload, low write rate (the operator edits a
/// target on the rare "my doctor changed my range" event). In-memory snapshot
/// per repo instance, 5-minute TTL — mirrors `SourcePriorityRepository`.
///
/// **Write path (server-first + optimistic + outbox):** `update(_:)` PUTs the
/// partial patch with an explicit `Idempotency-Key`. On a *retriable* network
/// failure (offline / 5xx / 429) the patch lands on the `OutboxQueue` under
/// the `updateThresholds` kind with the *same* key, and the error re-throws so
/// the calling store can roll back the optimistic UI + surface the banner.
/// `OutboxReplayService` drains it on the next reachability / foreground tick,
/// reusing the persisted key so server-side dedup catches the
/// replay-after-original-actually-succeeded race.
public actor UserThresholdsRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private var cached: UserThresholdsResponseDTO?
    private var cachedAt: Date?

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        cacheTTL: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    /// Reads the current effective + override map. Cache fresh → return.
    /// Stale or absent → network. Network fails with stale present →
    /// return stale. Network fails with no cache → throw.
    public func fetch() async throws -> UserThresholdsResponseDTO {
        if let cached, let cachedAt, clock().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        do {
            let req: APIRequest<UserThresholdsResponseDTO> = .get("/api/user/thresholds")
            let payload = try await api.send(req)
            cached = payload
            cachedAt = clock()
            return payload
        } catch {
            if let stale = cached {
                HLLog.api.warning(
                    "UserThresholdsRepository.fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// Persists a partial threshold patch. Optimistic + outbox-backed:
    /// on retriable failure the patch is enqueued for replay and the error
    /// re-throws. Returns the merged-override echo so the caller learns what
    /// the server actually persisted.
    @discardableResult
    public func update(_ patch: ThresholdsUpdatePayload) async throws -> UserThresholdsUpdateEchoDTO {
        try await update(patch, idempotencyKey: IdempotencyKey())
    }

    /// Replay-friendly overload — accepts the explicit key so an outbox
    /// replay can reuse it. Same server route; the only difference is the
    /// wire-side `Idempotency-Key` header.
    @discardableResult
    public func update(
        _ patch: ThresholdsUpdatePayload,
        idempotencyKey: IdempotencyKey
    ) async throws -> UserThresholdsUpdateEchoDTO {
        do {
            return try await put(patch, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(patch, idempotencyKey: idempotencyKey)
            throw err
        }
    }

    /// Outbox-replay entry point. Re-issues the PUT with the persisted key,
    /// no enqueue-on-failure (the replay loop owns the retry bookkeeping).
    @discardableResult
    public func replayUpdate(
        _ patch: ThresholdsUpdatePayload,
        idempotencyKey: String
    ) async throws -> UserThresholdsUpdateEchoDTO {
        try await put(patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// Test hook — drop the cached snapshot.
    public func invalidateCache() {
        cached = nil
        cachedAt = nil
    }

    // MARK: - Private

    private func put(
        _ patch: ThresholdsUpdatePayload,
        idempotencyKey: IdempotencyKey
    ) async throws -> UserThresholdsUpdateEchoDTO {
        let req: APIRequest<UserThresholdsUpdateEchoDTO> = try .put(
            "/api/user/thresholds",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        let echoed = try await api.send(req)
        // A successful write makes the in-memory snapshot stale — the next
        // `fetch()` must re-pull so the effective map reflects the merge.
        invalidateCache()
        return echoed
    }

    private func enqueue(_ patch: ThresholdsUpdatePayload, idempotencyKey: IdempotencyKey) async {
        do {
            let payload = try encoder.encode(OutboxQueue.Payloads.UpdateThresholds(patch: patch))
            try await outbox.enqueue(.init(
                kind: .updateThresholds,
                payload: payload,
                idempotencyKey: idempotencyKey.raw
            ))
        } catch {
            // Compounded failure (network + persistence) — log sanitized;
            // the original retriable error still re-throws to the caller.
            HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
