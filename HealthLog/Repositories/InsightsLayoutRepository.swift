import Foundation

/// Wraps `GET / PUT / DELETE /api/insights/layout` (server v1.5.5, spec in
/// `.planning/v080-marathon/SERVER-RESPONSE-v155.md`).
///
/// The route makes the Insights tile order + visibility **server-first** so
/// the layout syncs across the operator's devices — replacing the prior
/// iOS-local `@AppStorage` persistence (`InsightsTileCatalogue`).
///
/// **Cache strategy:** small payload, low write rate (the operator reorders
/// or hides a tile rarely). In-memory snapshot per repo instance, 5-minute
/// TTL — mirrors `UserThresholdsRepository`. The store keeps its own
/// instant-paint copy in `UserDefaults` for cold-launch before the GET lands.
///
/// **Write path (server-first + optimistic + outbox):** `put(_:)` PUTs the
/// full (server-filtered) layout with an explicit `Idempotency-Key`. On a
/// *retriable* network failure (offline / 5xx / 429) the layout lands on the
/// `OutboxQueue` under the `updateInsightsLayout` kind with the *same* key,
/// and the error re-throws so the store can roll the optimistic UI back +
/// surface the banner. `OutboxReplayService` drains it on the next
/// reachability / foreground tick, reusing the persisted key so server-side
/// dedup catches the replay-after-original-actually-succeeded race.
///
/// **Sections (A1, v1.15.11 layout v2):** the server layout carries a second
/// customizable dimension, `sections[]` (web overview blocks). **Parity Build 4
/// · 4.5 — iOS now renders AND edits them** (`InsightsLayout+Sections`,
/// `InsightsLayoutStore.reorderSections/toggleSectionVisible`, the "Overview
/// sections" list on `SettingsInsightsCustomizationScreen`); before that it did
/// neither, which left the whole web arrangement surface unreachable from the
/// phone. The earlier verbatim-echo workaround (every PUT had
/// to re-send the GET's sections, else the server filled section DEFAULTS) is
/// GONE: server v1.16.13/1.16.14 (GH #19) now MERGE-preserves the stored
/// sections on a PUT that omits the field, so a tiles-only iOS PUT no longer
/// resets the web arrangement. iOS writes a plain `filteringForServer()` PUT —
/// no donor GET, no cache backfill. `sections` still round-trip through the
/// mutation helpers when a layout already carries them (harmless), but a
/// sections-less layout is now sent as-is.
///
/// **422 unknown-id handling:** a PUT carrying a tile id outside the server
/// catalogue returns HTTP 422 (`HLError.server(status: 422, …)`). The store
/// pre-filters via `InsightsLayout.filteringForServer()` so this should never
/// fire in practice; if it does it is NON-retriable (a body fix won't come
/// from a retry), so it is NOT enqueued — it re-throws straight to the store
/// which rolls back and keeps the known-good order.
public actor InsightsLayoutRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    private var cached: InsightsLayout?
    private var cachedAt: Date?
    /// **CU-20 (#69)** — last `updatedAt` seen from `/api/insights/layout`.
    /// Cleared by ``reset()``, whose DELETE response carries no token
    /// (`api/insights/layout/route.ts:232-245`); the next write is then
    /// unconditional rather than guarded by a token the reset invalidated.
    private var baseUpdatedAt: String?

    /// Test/diagnostic accessor for the currently held concurrency token.
    public func currentLayoutToken() -> String? {
        baseUpdatedAt
    }

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

    /// Reads the current layout. Cache fresh → return. Stale or absent →
    /// network. Network fails with stale present → return stale. Network
    /// fails with no cache → throw. The decoded server layout is reconciled
    /// (`reconciled()`) so unknown ids never reach the render path.
    public func fetch() async throws -> InsightsLayout {
        if let cached, let cachedAt, clock().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        do {
            let req: APIRequest<InsightsLayout> = .get("/api/insights/layout")
            let fetched = try await api.send(req)
            // CU-20 — take the token off the RAW response: `reconciled()`
            // rebuilds the layout and must not be relied on to carry it.
            baseUpdatedAt = fetched.updatedAt
            let payload = fetched.reconciled()
            cached = payload
            cachedAt = clock()
            return payload
        } catch {
            if let stale = cached {
                HLLog.api.warning(
                    "InsightsLayoutRepository.fetch failed; returning stale cache: \(String(describing: error), privacy: .private)"
                )
                return stale
            }
            throw error
        }
    }

    /// Persists the full layout. Optimistic + outbox-backed: on a retriable
    /// failure the layout is enqueued for replay and the error re-throws. A
    /// 422 (unknown id) is non-retriable and re-throws without enqueueing.
    /// Returns the reconciled server echo so the store learns what persisted.
    @discardableResult
    public func update(_ layout: InsightsLayout) async throws -> InsightsLayout {
        try await update(layout, idempotencyKey: IdempotencyKey())
    }

    @discardableResult
    public func update(
        _ layout: InsightsLayout,
        idempotencyKey: IdempotencyKey
    ) async throws -> InsightsLayout {
        do {
            return try await put(layout, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Server merge-preserves stored sections on a partial PUT (GH #19,
            // v1.16.13+), so the replay payload no longer needs a sections echo.
            await enqueue(
                layout.filteringForServer(),
                idempotencyKey: idempotencyKey
            )
            throw err
        }
    }

    /// Resets to server defaults via DELETE. Returns the reconciled echo (the
    /// server's resolved default layout). DELETE is not outbox-backed — a
    /// reset is an explicit, idempotent-on-the-server action the operator can
    /// simply retry; queuing it would risk replaying a reset after a later
    /// re-customisation.
    @discardableResult
    public func reset() async throws -> InsightsLayout {
        let req: APIRequest<InsightsLayout> = .delete("/api/insights/layout")
        let echoed = try await api.send(req).reconciled()
        cached = echoed
        cachedAt = clock()
        // CU-20 — the DELETE reset takes no token AND returns none
        // (`route.ts:232-245` responds with the bare defaults). Keeping the old
        // one would send a token for a row that was just rewritten, so the next
        // guarded PUT would 409 on a change the user just made themselves.
        // Drop it: the next write is unconditional and re-seeds a fresh token
        // from its own echo.
        baseUpdatedAt = nil
        return echoed
    }

    /// Outbox-replay entry point. Re-issues the PUT with the persisted key,
    /// no enqueue-on-failure (the replay loop owns retry bookkeeping).
    @discardableResult
    public func replayUpdate(
        _ layout: InsightsLayout,
        idempotencyKey: String
    ) async throws -> InsightsLayout {
        try await put(layout, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// Test hook — drop the cached snapshot.
    public func invalidateCache() {
        cached = nil
        cachedAt = nil
    }

    // MARK: - Private

    private func put(
        _ layout: InsightsLayout,
        idempotencyKey: IdempotencyKey
    ) async throws -> InsightsLayout {
        // A1 (v1.15.11 layout v2) — the verbatim-section echo workaround is
        // GONE (GH #19). Server v1.16.13/1.16.14 MERGE-preserves the stored
        // sections on a PUT that omits the field, so a tiles-only iOS PUT no
        // longer resets the operator's WEB section arrangement. Send a plain
        // `filteringForServer()` body: no donor GET, no cache backfill. A
        // layout that already carries sections still emits them (harmless).
        let payload = layout.filteringForServer()
        return try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.insightsLayout,
            token: baseUpdatedAt
        ) { token in
            let req: APIRequest<InsightsLayout> = try .put(
                "/api/insights/layout",
                body: OptimisticWriteBody(payload: payload, baseUpdatedAt: token),
                idempotencyKey: idempotencyKey
            )
            let raw = try await api.send(req)
            baseUpdatedAt = raw.updatedAt
            let echoed = raw.reconciled()
            cached = echoed
            cachedAt = clock()
            return echoed
        } reread: {
            // The PUT is a full replace, so the user's layout is still what we
            // want to send; only the token needs refreshing. Drop the LOCAL
            // snapshot first — the client-side TTL cache would otherwise hand
            // back the very token we just conflicted on. (The 300 s SERVER-side
            // cache on this route cannot be bypassed from the client at all,
            // which is exactly why the retry above is bounded.)
            invalidateCache()
            // `fetch()` returns the RECONCILED layout (which does not carry the
            // token); it refreshes `baseUpdatedAt` off the raw response as a
            // side effect, so read the token from there.
            _ = try await fetch()
            return baseUpdatedAt
        }
    }

    private func enqueue(_ layout: InsightsLayout, idempotencyKey: IdempotencyKey) async {
        do {
            let payload = try encoder.encode(OutboxQueue.Payloads.UpdateInsightsLayout(layout: layout))
            try await outbox.enqueue(.init(
                kind: .updateInsightsLayout,
                payload: payload,
                idempotencyKey: idempotencyKey.raw
            ))
        } catch {
            HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
