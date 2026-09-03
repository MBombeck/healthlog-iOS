import Foundation

/// Single-event-per-state ladder a `SWRCoordinator.observe(...)` stream emits.
///
/// Typical happy-path sequence:
///   `.cached(value, age) → .fresh(value)`
///
/// Cold-launch sequence (no cached row yet):
///   `.empty → .fresh(value)`
///
/// Offline / network-fail sequence:
///   `.cached(value, age) → .failed(.network, lastKnown: value)`
///   (or `.empty → .failed(...)` if no cache existed)
public enum SWRState<T: Sendable>: Sendable {
    case empty
    case cached(T, age: TimeInterval)
    case fresh(T)
    case failed(HLError, lastKnown: T?)
}

/// **21-03 (D-14-06-C)** — who asked for a revalidation.
///
/// Deliberately a separate axis from `forceRevalidate`. That flag answers
/// "revalidate even though the cached row is still fresh"; this one answers
/// "is a human watching this happen right now". Overloading the first to mean
/// the second would have made the sharing contract depend on cache staleness,
/// which is not what the operator's symptom is about.
public enum RefreshIntent: Sendable {
    /// Foreground passes, scene-phase hooks, prefetches, background
    /// revalidations. Attaches to an in-flight winner for however long it
    /// takes — the collapse that keeps N identical revalidations to one
    /// round-trip.
    case system
    /// A pull-to-refresh, or any other refresh a person just asked for.
    /// Attaches only for ``SWRCoordinator/userInitiatedAttachBound``.
    case userInitiated
}

/// Orchestrator for SWR observe + revalidate.
///
/// Lives on `AppContainer`. Reads from `SWRCache`, calls the caller's
/// `fetch` closure for revalidation, writes back to the cache on success.
/// Single-flight per key — concurrent observers of the same key collapse
/// into one network call.
///
/// **Stores adopt by pattern:**
/// ```
/// for await state in coordinator.observe(.dashboardSummary, decoding: DashboardSummary.self,
///                                        fetch: { try await repo.summary() }) {
///     switch state { … }
/// }
/// ```
public actor SWRCoordinator {
    /// Cache resolution state — exactly one of the two inits seeds it, so the
    /// "neither task nor resolved value" shape is unrepresentable (replaces a
    /// former optional pair + force-unwrap). `.pending` holds the deferred
    /// `Task<SWRCache, Never>` (production: SwiftData `ModelContainer` open
    /// happens off the launch-tick, PA5 Bottleneck #1); the moment its value
    /// lands we flip to `.resolved` so the closure-captured task can be
    /// released and we keep only the resolved actor reference. Tests seed
    /// `.resolved` directly via `init(cache:reachability:)`.
    private enum CacheState {
        case pending(Task<SWRCache, Never>)
        case resolved(SWRCache)
    }

    private var cacheState: CacheState
    private let reachability: ReachabilityProviding
    /// W8-B2 — single-flight registry. Concurrent revalidations of the SAME
    /// key (e.g. the Dashboard + Insights pull-to-refresh fan-outs both
    /// hitting `dashboardSummary`/`measurementsRecent`, or two observers of
    /// one key on the same screen) collapse into ONE network round-trip: the
    /// first caller runs the fetch + write-through, later callers await that
    /// shared task and reuse its result. The boxed Task is generic-erased to
    /// `Any` since the dict spans key types; the value cast back is safe
    /// because the key→type mapping is structurally fixed per `CacheKey` case.
    private var inflight: [String: Task<any Sendable, Error>] = [:]

    /// b177 W-SYNCPROGRESS — observers of the live in-flight revalidation
    /// count. The sync-status footer aggregates this with the outbox backlog
    /// so a pull-to-refresh can show an HONEST "N ausstehend" quantity (the
    /// number of distinct keys currently being fetched — no invented
    /// percentages, spec §4.5). Continuations receive the current count on
    /// registration and on every insert/removal in the single-flight registry.
    private var inflightObservers: [UUID: AsyncStream<Int>.Continuation] = [:]

    /// **v0.13 WS Item 2 — cross-user / cross-server stale-write guard.**
    /// Monotonic session token bumped on every `invalidateAll()` (logout,
    /// account-delete, switch-server). A revalidation captures the epoch
    /// *before* its `fetch()`; the write-through re-checks it *after* the
    /// fetch resumes on the actor and drops the write if the epoch moved —
    /// so a pre-logout fetch issued against the OLD user/server can never
    /// land its stale payload back into the cache AFTER the purge.
    /// Cancellation alone is insufficient: an already-resumed continuation
    /// would still run its `cache.write` before observing cancellation.
    private(set) var sessionEpoch: Int = 0

    /// **W-PERF-SWR C2 — non-blocking write-through.** Handles for the
    /// fire-and-forget cache persists kicked by `fetchAndWriteThrough`. The
    /// on-screen repaint no longer awaits the SwiftData `save()` flush (~10-50
    /// ms): the fresh value is returned to the store IMMEDIATELY and the disk
    /// persist runs on a detached low-priority task whose error is logged, not
    /// awaited. The in-memory store already holds the fresh value, so the only
    /// thing the detached write buys is *cold-read* correctness — a later cold
    /// read still sees the persisted row once the task lands.
    ///
    /// Tracked here (rather than truly fire-and-forget) for two reasons:
    /// (1) `invalidateAll()` can cancel still-pending persists so a logout
    /// boundary doesn't race a late write landing a previous-user row, and
    /// (2) tests can deterministically drain them via `drainPendingWrites()`
    /// to assert the read-after-write contract without timing flakiness.
    var pendingWrites: [UUID: Task<Void, Never>] = [:]

    /// Build 273 (A9) — per-key write generation. `writeThrough` and
    /// `invalidate(_:)` bump it; a revalidation captures it before its fetch and
    /// persists to disk only if nothing newer was written for that key in the
    /// meantime. The session epoch guarded logout; nothing guarded a foreground
    /// GET that landed after an optimistic "Taken" write-through and persisted
    /// the pre-POST list — the next offline cold launch then showed the dose
    /// as open with an enabled button.
    var writeGenerations: [String: Int] = [:]

    /// Re-entrancy guard for single-flight. Holds the set of key-hashes whose
    /// `revalidateSingleFlight` is currently executing **on the present task's
    /// own call-stack**. Carried as a `@TaskLocal` so it follows structured
    /// child tasks (`async let`, `withTaskGroup`) and the `Task {}` the
    /// single-flight winner spawns for its `fetch`.
    ///
    /// **Why this exists (W25 deflake / cold-launch deadlock fix):** the
    /// `observe(_:fetch:)` ladder's `fetch` closure is allowed to itself route
    /// back through `fetchCachingFirst(sameKey)` → `revalidateSingleFlight`
    /// for the *same* key (the `MeasurementsStore.load()` →
    /// `repo.recent(limit:)` path does exactly this for
    /// `.measurementsRecent(limit:)`). Without this guard, that nested call
    /// finds the *ancestor's* in-flight task already registered and awaits it
    /// — but the ancestor cannot finish until its `fetch` (the nested call)
    /// returns. Result: a self-deadlock that only fires on a genuinely empty +
    /// online cold cache (warm/seeded caches short-circuit before
    /// `revalidateSingleFlight` and never re-enter). The guard makes a
    /// re-entrant call for a key already on the current stack run its `fetch`
    /// directly instead of awaiting its own ancestor, while still collapsing
    /// genuinely concurrent observers (separate task stacks) into one round-trip.
    @TaskLocal private static var keysOnStack: Set<String> = []

    /// Test/legacy init — accepts a fully constructed `SWRCache` (e.g.
    /// in-memory container). Existing unit tests rely on this synchronous
    /// shape; production callers should prefer `init(cacheTask:)`.
    public init(cache: SWRCache, reachability: ReachabilityProviding) {
        cacheState = .resolved(cache)
        self.reachability = reachability
    }

    /// Production init — defers `SWRCache` resolution until the first read.
    /// `AppContainer` kicks the `ModelContainer` open onto a detached
    /// high-priority task; we await it lazily on first use so app launch
    /// no longer pays for the SwiftData open inside `applicationDidFinish-
    /// LaunchingWithOptions` (PA5 Bottleneck #1, saves 30-80 ms cold).
    public init(cacheTask: Task<SWRCache, Never>, reachability: ReachabilityProviding) {
        cacheState = .pending(cacheTask)
        self.reachability = reachability
    }

    /// Single-flight resolve of the deferred cache. First call awaits the
    /// open; subsequent calls return the memoised reference without hopping.
    private func cache() async -> SWRCache {
        switch cacheState {
        case let .resolved(cache):
            return cache
        case let .pending(task):
            let value = await task.value
            cacheState = .resolved(value)
            return value
        }
    }

    /// **v0.12 W8-4** — Sweep cached snapshots older than `maxAge`. Resolves
    /// the deferred cache (single-flight) and forwards to
    /// `SWRCache.sweepOlderThan`. Best-effort: errors are swallowed + logged so
    /// the BGTask path never fails on a cache-maintenance hiccup. Returns the
    /// number of rows dropped for the caller's breadcrumb.
    @discardableResult
    public func sweepOlderThan(_ maxAge: TimeInterval, now: Date = .now) async -> Int {
        let cache = await cache()
        do {
            return try await cache.sweepOlderThan(maxAge, now: now)
        } catch {
            HLLog.cache.error(
                "SWR cache sweep failed: \(error.localizedDescription, privacy: .private)"
            )
            return 0
        }
    }

    /// **AUD-8 H-1 default cap.** The hard upper bound on persisted cache rows.
    /// 30 days of daily-keyed insight/metric rows for ~25 metrics × multiple
    /// periods is low-thousands; 4000 leaves generous headroom for an engaged
    /// user while guaranteeing the SQLite can't grow without bound (which would
    /// blow the ≤100 ms cache-paint budget).
    public static let defaultMaxRows = 4000

    /// **AUD-8 H-1** — enforce the hard row-count cap (evict the oldest rows
    /// beyond `maxRows`). Best-effort, off the hot path. Returns the number of
    /// rows evicted.
    @discardableResult
    public func sweepKeepingNewest(maxRows: Int = SWRCoordinator.defaultMaxRows) async -> Int {
        let cache = await cache()
        do {
            return try await cache.sweepKeepingNewest(maxRows: maxRows)
        } catch {
            HLLog.cache.error(
                "SWR cache cap sweep failed: \(error.localizedDescription, privacy: .private)"
            )
            return 0
        }
    }

    /// **AUD-8 H-1** — the foreground / cold-launch maintenance pass: age-sweep
    /// AND row-count cap, in one call. Wired off the hot path (detached
    /// `.utility`) so it never depends on a BGProcessingTask wake — the cache
    /// stays bounded even with Background-App-Refresh disabled. Returns the
    /// total rows dropped (age + cap).
    @discardableResult
    public func foregroundMaintenanceSweep(
        maxAge: TimeInterval = 30 * 24 * 60 * 60,
        maxRows: Int = SWRCoordinator.defaultMaxRows,
        now: Date = .now
    ) async -> Int {
        let aged = await sweepOlderThan(maxAge, now: now)
        let capped = await sweepKeepingNewest(maxRows: maxRows)
        return aged + capped
    }

    /// Subscribe to a key.
    ///
    /// - Parameters:
    ///   - key: cache key (see `CacheKey`).
    ///   - decoding: the target value type. Must round-trip via the unified
    ///     `JSONEncoder.hlDefault` / `JSONDecoder.hlDefault`.
    ///   - fetch: async closure that produces a fresh value from the server.
    ///     Throws `HLError`; non-HLError surfaced as `.failed(.unknown(...))`.
    ///   - forceRevalidate: when `true`, the staleness short-circuit is
    ///     bypassed — a fresh-enough cached row still triggers a network
    ///     revalidation (`.cached → .fresh`). This is the explicit
    ///     pull-to-refresh path (W8-B1); the offline-serve guard still
    ///     applies so a forced refresh while offline serves cache rather
    ///     than erroring.
    ///   - intent: **21-03 (D-14-06-C)** — who asked. `.system` keeps today's
    ///     single-flight semantics exactly: attach to an in-flight winner for
    ///     however long it takes, so N identical background revalidations stay
    ///     one round-trip. `.userInitiated` attaches only for
    ///     ``userInitiatedAttachBound`` and then issues its own request. This
    ///     is deliberately NOT folded into `forceRevalidate`: "revalidate even
    ///     though the cache is fresh" and "a human is watching this happen" are
    ///     different questions and the second one is the one D-14-06-C is about.
    public func observe<T: Codable & Sendable>(
        _ key: CacheKey,
        decoding _: T.Type,
        forceRevalidate: Bool = false,
        intent: RefreshIntent = .system,
        fetch: @escaping @Sendable () async throws -> T
    ) -> AsyncStream<SWRState<T>> {
        AsyncStream<SWRState<T>> { [weak self] continuation in
            let task = Task {
                guard let self else {
                    continuation.finish()
                    return
                }
                // Resolve cache lazily — first observe pays the SwiftData
                // open if AppContainer's detached open hasn't finished yet.
                // Subsequent calls hit the memoised reference.
                let cache = await self.resolveCache()

                // 1. Synchronous emit from cache.
                //
                // **21-02 — the decode does not happen on the cache actor.**
                // `SWRCache` is a `@ModelActor` with a serial executor, and
                // 21-01 measured the consequence: across an eight-surface
                // foreground fan-out, ZERO pairs of distinct keys ever decoded
                // at the same instant, and 99% of a small surface's first
                // paint was spent waiting for other keys' decodes. The fetch
                // must stay on the actor (SwiftData confines the
                // `ModelContext`, and a `CachedSnapshot` must never cross the
                // boundary); the decode need not. `readPayload` hands back
                // `Data` + `Date` — both `Sendable` — and `decodeOffActor`
                // turns them into `T` on this stream's own task.
                let raw: Cached<Data>? = await cache.readPayload(key)
                let cached: Cached<T>? = await Self.decodeOffActor(raw, key: key, as: T.self)
                if let cached {
                    let age = Date().timeIntervalSince(cached.updatedAt)
                    continuation.yield(.cached(cached.value, age: age))
                } else {
                    continuation.yield(.empty)
                }

                // 2. Skip revalidation if offline AND we have cache.
                let isOnline = await self.reachabilityIsOnline()
                if cached != nil, !isOnline {
                    continuation.finish()
                    return
                }

                // 3. Skip revalidation if cache is fresh-enough — unless the
                //    caller explicitly forced a revalidation (pull-to-refresh).
                if !forceRevalidate, let cached, !cached.isStale(per: key) {
                    continuation.yield(.fresh(cached.value))
                    continuation.finish()
                    return
                }

                // 4. Fetch + write-through, single-flighted (W8-B2) so
                //    concurrent observers / pull-to-refresh fan-outs hitting
                //    the same key collapse into one network round-trip.
                do {
                    let fresh = try await self.revalidateSingleFlight(
                        key,
                        cache: cache,
                        intent: intent,
                        fetch: fetch
                    )
                    continuation.yield(.fresh(fresh))
                } catch let err as HLError {
                    continuation.yield(.failed(err, lastKnown: cached?.value))
                } catch {
                    continuation.yield(.failed(.unknown(String(describing: error)), lastKnown: cached?.value))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// **21-02 — decode a cached payload off every actor.**
    ///
    /// `nonisolated` **and** `async`, and both words are load-bearing. Under
    /// SE-0338 a non-actor-isolated `async` function runs on the generic
    /// concurrent executor rather than inheriting its caller's actor, so the
    /// `JSONDecoder.decode` inside runs on the cooperative pool no matter who
    /// called it — not on `SWRCache`'s serial executor (which is the
    /// contention this plan removes) and not on `SWRCoordinator`'s either
    /// (which would merely relocate it, and is the mistake this shape is
    /// written to avoid).
    ///
    /// That makes the fix depend on an isolation default. Enabling the
    /// `NonisolatedNonsendingByDefault` upcoming feature, or writing
    /// `nonisolated(nonsending)` here, would silently reinstate the
    /// serialization — which is precisely why
    /// `SWRCacheContentionTests.slowDecodeOfOneKeyMustNotDelayAnotherKeysFirstPaint`
    /// exists and asserts the ordering rather than the implementation.
    ///
    /// A `nil` payload stays `nil`, and a decode failure becomes `nil` — the
    /// same cache-miss the in-actor decode produced, mapped to the same
    /// `.empty` emission, so the ladder's contract is unchanged.
    private nonisolated static func decodeOffActor<T: Decodable & Sendable>(
        _ raw: Cached<Data>?,
        key: CacheKey,
        as _: T.Type
    ) async -> Cached<T>? {
        guard let raw else { return nil }
        guard let value: T = SWRCache.decodePayload(raw.value, key: key, as: T.self) else { return nil }
        return Cached(value: value, updatedAt: raw.updatedAt)
    }

    /// W8-B2 — single-flight fetch + write-through for one key. Concurrent
    /// callers for the same key share one network round-trip: the first
    /// registers an in-flight task, later callers await it. The result is
    /// written through the cache once (by the winner) so the observe ladder
    /// sees it on its next pass. Throws the underlying fetch error to ALL
    /// waiters (so each observer reports `.failed` with its own `lastKnown`).
    ///
    /// **21-03 (D-14-06-C) — the sharing contract now depends on who asked.**
    /// 14-06 measured the operator's *"das Runterziehen bringt keine Lösung …
    /// ich habe gewartet"*: the winner is an unstructured `Task`, a cancelled
    /// foreground pass does not cancel the fetch it started, and a pull
    /// arriving while that fetch flies issues **no request of its own** — it
    /// inherits the winner's full latency with no timeout. On a slow request
    /// that is indistinguishable, from the user's side, from a pull that did
    /// nothing.
    ///
    /// A `.system` caller still attaches for however long it takes; that is
    /// the collapse protecting the server from N identical round-trips and it
    /// is unchanged. A `.userInitiated` caller attaches for at most
    /// ``userInitiatedAttachBound`` and then issues its own request. The winner
    /// is **never cancelled on one caller's behalf** — it is still serving its
    /// other waiters. If both land, last-writer-wins through the existing cache
    /// write path, which is the rule the cache already applies to any two
    /// revalidations.
    private func revalidateSingleFlight<T: Codable & Sendable>(
        _ key: CacheKey,
        cache: SWRCache,
        intent: RefreshIntent = .system,
        fetch: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let hash = key.persistentHash
        // v0.13 WS Item 2 — capture the session epoch BEFORE the fetch so the
        // write-through can detect an intervening `invalidateAll()` (logout /
        // switch-server) and drop a now-stale write.
        let epoch = sessionEpoch
        // Re-entrancy short-circuit (W25): if this key is already being
        // fetched on the present task's own call-stack, awaiting the
        // registered in-flight task would mean awaiting our own ancestor —
        // a self-deadlock. Run the fetch directly + write-through instead.
        // Genuinely concurrent callers (separate task stacks) don't carry the
        // key in `keysOnStack`, so they still collapse into the shared task.
        if Self.keysOnStack.contains(hash) {
            return try await fetchAndWriteThrough(key, cache: cache, epoch: epoch, fetch: fetch)
        }
        if let existing = inflight[hash] {
            // Lose the race → await the winner's result. A `.system` caller
            // waits for however long that takes; a `.userInitiated` one waits
            // only for the bound, because a human is watching.
            let value: (any Sendable)?
            switch intent {
            case .system:
                value = try await existing.value
                Self.logRefresh(mode: "attached", key: key)
            case .userInitiated:
                if let landed = try await Self.attach(to: existing, within: Self.userInitiatedAttachBound) {
                    value = landed
                    Self.logRefresh(mode: "attached", key: key)
                } else {
                    // The bound expired. The winner keeps running for its other
                    // waiters — cancelling a shared task on one caller's behalf
                    // would make this pull the cause of somebody else's failure.
                    Self.logRefresh(mode: "issued", key: key)
                    return try await fetchAndWriteThrough(key, cache: cache, epoch: epoch, fetch: fetch)
                }
            }
            // Forced unwrap-as: the key→type mapping is structurally fixed,
            // so the boxed `Any` is always this call's `T`.
            guard let typed = value as? T else {
                throw HLError.unknown("SWR single-flight type mismatch for \(key.canonicalString)")
            }
            return typed
        }
        Self.logRefresh(mode: "winner", key: key)
        // Tag this key as on-stack for the duration of the winner's fetch so a
        // nested `revalidateSingleFlight(sameKey)` reached from inside `fetch`
        // takes the re-entrancy short-circuit above instead of deadlocking.
        let task = Task<any Sendable, Error> { [self] in
            try await Self.$keysOnStack.withValue(Self.keysOnStack.union([hash])) {
                try await fetchAndWriteThrough(key, cache: cache, epoch: epoch, fetch: fetch)
            }
        }
        inflight[hash] = task
        broadcastInflightCount()
        defer {
            inflight[hash] = nil
            broadcastInflightCount()
        }
        let value = try await task.value
        // Safe cast: same structural key→type invariant as above.
        guard let typed = value as? T else {
            throw HLError.unknown("SWR single-flight type mismatch for \(key.canonicalString)")
        }
        return typed
    }

    /// b177 W-SYNCPROGRESS — live stream of the in-flight revalidation count.
    /// Yields the current count immediately on registration, then once per
    /// insert/removal in the single-flight registry. Mirrors the
    /// `OutboxQueue.changes` continuation pattern (register on the actor,
    /// remove on termination).
    public var inflightCounts: AsyncStream<Int> {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        let id = UUID()
        // Task inherits the actor's isolation, so `register` runs on this
        // actor — no extra await hop needed.
        Task { registerInflightObserver(id: id, continuation: continuation) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeInflightObserver(id) }
        }
        return stream
    }

    private func registerInflightObserver(id: UUID, continuation: AsyncStream<Int>.Continuation) {
        inflightObservers[id] = continuation
        continuation.yield(inflight.count)
    }

    private func removeInflightObserver(_ id: UUID) {
        inflightObservers[id] = nil
    }

    private func broadcastInflightCount() {
        let count = inflight.count
        for c in inflightObservers.values {
            c.yield(count)
        }
    }

    // Fetch a fresh value and write it through the cache (best-effort — a
    // cache-write failure is logged, not propagated, so the caller still
    // receives the fresh value). Single shared site for both the
    // single-flight winner and the re-entrant short-circuit (W25).
    //
    // **v0.13 WS Item 2 — epoch guard.** This is an actor-isolated instance
    // method (was `static`) so that after `fetch()` resumes it can compare
    // the captured `epoch` against the live `sessionEpoch`. If an
    // `invalidateAll()` ran during the fetch (user logout / switch-server),
    // the fresh payload belongs to the OLD session and must NOT repopulate
    // the just-purged cache — we skip the write but still return the value
    // to the in-flight observer (which is finishing its own stream; a
    // post-purge re-observe under the new session re-fetches cleanly).

    // W-PERF-SWR C2 — fire-and-forget persist of an already-encoded payload.
    // Re-checks the session epoch on the actor before writing (a logout between
    // scheduling and execution drops the stale write) and logs — never
    // propagates — a write failure. Registered in `pendingWrites` so
    // `invalidateAll()` can cancel + drain it (and tests can await it).

    // Actor-isolated epoch check — used by the detached persist task to confirm
    // no `invalidateAll()` fenced the session after the write was scheduled.

    /// Remove a settled persist handle. Called once the detached write finishes
    /// (success, drop, or failure) so `pendingWrites` doesn't accumulate.
    func finishPendingWrite(_ id: UUID) {
        pendingWrites[id] = nil
    }

    /// **Test-only** — await every in-flight detached cache persist, so a test
    /// can assert the read-after-write contract (a subsequent cold read sees the
    /// persisted value) without depending on scheduler timing. Production code
    /// never needs this: the in-memory store already holds the fresh value.
    func drainPendingWrites() async {
        // Snapshot, then await — new writes scheduled during the drain are
        // picked up on the next snapshot pass until none remain.
        while !pendingWrites.isEmpty {
            let handles = Array(pendingWrites.values)
            for handle in handles {
                await handle.value
            }
        }
    }

    /// Actor-isolated accessor — opens up `cache()` to the AsyncStream
    /// builder closure (which can't directly call private actor methods).
    private func resolveCache() async -> SWRCache {
        await cache()
    }

    /// Actor-isolated reachability hop — kept here so the stream closure
    /// doesn't need to capture `reachability` directly.
    private func reachabilityIsOnline() async -> Bool {
        await reachability.isCurrentlyOnline()
    }

    /// Write-through helper — used by optimistic-write paths and by the
    /// cache-invalidator on mutation.
    public func writeThrough(_ key: CacheKey, value: some Codable & Sendable) async {
        bumpWriteGeneration(key)
        do {
            let payload = try JSONEncoder.hlDefault.encode(value)
            try await cache().write(key, payload: payload)
        } catch {
            // Cache keys are enum-shaped canonical paths (no user data) — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.warning("Cache writeThrough failed for \(key.canonicalString, privacy: .public)")
        }
    }

    /// Cache-only peek. Returns the stored value (with age) when present,
    /// `nil` on miss / decode-failure / schema-mismatch. **Does not** kick
    /// any revalidation — exposed so actor-style callers (e.g.
    /// `MeasurementsRepository`) can implement their own cache-first ladders
    /// without subscribing to the full SWR observe stream. Subscribers that
    /// want the observe-ladder (`.empty → .cached → .fresh`) keep using
    /// `observe(_:decoding:fetch:)`.
    public func peek<T: Codable & Sendable>(
        _ key: CacheKey,
        as _: T.Type
    ) async -> Cached<T>? {
        await cache().read(key, as: T.self)
    }

    /// Actor-friendly single-value SWR. Returns one `T` value to the caller
    /// after applying the standard ladder:
    ///   1. If a non-stale cached row exists, return it immediately (kicks
    ///      no network — caller can `Task.detached` a follow-up revalidate
    ///      if desired).
    ///   2. If a stale-but-existing cached row exists AND we're offline,
    ///      return that row (best-effort offline serve).
    ///   3. Otherwise call `fetch`, write the fresh value back through the
    ///      cache, return the fresh value.
    ///
    /// **Used by `MeasurementsRepository` (W1-1)** so chart-detail tap-load
    /// hits cached values instead of cold network round-trips. The repo is
    /// itself an actor and can't subscribe to `observe`'s AsyncStream from
    /// its method body, so this single-value shape is the right adapter.
    ///
    /// Fresh writes go through the cache so future calls (including the
    /// observe-ladder used by stores) see them too — no double-write needed
    /// at the call-site.
    ///
    /// `forceRevalidate: true` bypasses the fresh-enough cache short-circuit
    /// (explicit pull-to-refresh, W8-B1) — the offline-serve fallback still
    /// applies so a forced refresh while offline serves stale cache.
    public func fetchCachingFirst<T: Codable & Sendable>(
        _ key: CacheKey,
        decoding _: T.Type,
        forceRevalidate: Bool = false,
        fetch: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let resolved = await cache()
        let cached: Cached<T>? = await resolved.read(key, as: T.self)
        // Serve fresh-enough cache without touching the network — unless the
        // caller forced a revalidation.
        if !forceRevalidate, let cached, !cached.isStale(per: key) {
            return cached.value
        }
        // Stale-but-existing cache + offline → best-effort serve.
        let isOnline = await reachability.isCurrentlyOnline()
        if let cached, !isOnline {
            return cached.value
        }
        // Network path, single-flighted (W8-B2) so it shares a round-trip
        // with any concurrent observe()/fetchCachingFirst of the same key.
        // Write-through happens inside the single-flight so the observe
        // ladder emits `.cached(...)` to other subscribers on their next pass.
        return try await revalidateSingleFlight(key, cache: resolved, fetch: fetch)
    }

    /// Drop one or more keys from the cache.
    public func invalidate(_ keys: [CacheKey]) async {
        for key in keys {
            bumpWriteGeneration(key)
        }
        do {
            try await cache().invalidate(keys)
        } catch {
            HLLog.cache.warning("Cache invalidate failed")
        }
    }

    /// Drop every row — called on logout + account-deletion + switch-server.
    ///
    /// **v0.13 WS Items 2 + 3.** This is a cross-user / cross-server security
    /// boundary, not best-effort hygiene:
    ///
    /// - **Item 2:** bump `sessionEpoch` and cancel + clear the in-flight
    ///   single-flight registry FIRST, so a revalidation past its `fetch()` drops
    ///   its write-through via the epoch guard and no new waiter latches onto a
    ///   pre-purge task. The epoch guard (not cancellation) is the authoritative
    ///   drop.
    /// - **Item 3:** the SwiftData delete is escalated instead of swallowed —
    ///   retry once, then recreate the store (delete SQLite + rebuild container)
    ///   so a previous account's rows can't paint as the new user's data.
    public func invalidateAll() async {
        // Item 2 — fence the session BEFORE the purge.
        sessionEpoch &+= 1
        for task in inflight.values {
            task.cancel()
        }
        inflight.removeAll()
        broadcastInflightCount()
        // W-PERF-SWR C2 + W-RECONCILE M-1 — cancel AND drain detached persists.
        // Cancellation alone races: a persist already past its `epochIsCurrent`
        // check is mid-`await cache.write` and would serialize on the `SWRCache`
        // actor AFTER the purge, re-inserting a stale-session row. Awaiting every
        // pending write BEFORE the purge makes the order deterministic — losers
        // drop on the bumped epoch, winners finish here — closing the bleed window.
        let drainingWrites = Array(pendingWrites.values)
        pendingWrites.removeAll()
        for task in drainingWrites {
            task.cancel()
        }
        for task in drainingWrites {
            await task.value
        }

        let cache = await cache()
        do {
            try await cache.invalidateAll()
            return
        } catch {
            HLLog.cache.warning("Cache invalidateAll failed — retrying once")
        }
        // Item 3 — retry once.
        do {
            try await cache.invalidateAll()
            return
        } catch {
            HLLog.cache.error(
                "Cache invalidateAll retry failed — recreating store: \(LogSanitizer.redact(String(describing: error)))"
            )
        }
        // Item 3 escalation — delete the on-disk store file and rebuild the
        // container so no previous-account row can survive into the next
        // session. `makeWithRecovery` wipes the `Cache/` directory on a failed
        // open and falls back to in-memory, so the resolved cache is always a
        // clean, empty store afterwards.
        if let storeURL = try? SWRCache.persistentStoreURL() {
            let dir = storeURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }
        let rebuilt = SWRCache.makeWithRecovery()
        cacheState = .resolved(rebuilt)
    }
}

// `ReachabilityProviding` is defined in `Services/Reachability.swift`. Tests
// inject a deterministic stub via that protocol.
