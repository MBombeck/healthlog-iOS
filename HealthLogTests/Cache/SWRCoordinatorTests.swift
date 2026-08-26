import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// Locks the state-machine sequences `SWRCoordinator.observe(...)` emits.
///
/// Pre-v0.4.0 every store cold-started from in-memory `nil` → grey skeleton
/// for the full network round-trip (A2-Audit §1). SWR pattern guarantees:
///   - hot launch with cached row → cached → fresh
///   - cold launch                → empty → fresh
///   - offline with cached row    → cached → finish (no revalidation)
///   - revalidation failure       → cached (or empty) → failed(lastKnown:)
@Suite("SWRCoordinator state stream")
struct SWRCoordinatorTests {
    private struct Payload: Codable, Equatable {
        let id: String
        let value: Int
    }

    /// Deterministic in-memory reachability stub.
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { c in c.yield(online)
                    c.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    @Test("Cold-start: empty → fresh")
    func coldStart() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        var sequence: [String] = []
        let stream = await coordinator.observe(.userProfile, decoding: Payload.self) {
            Payload(id: "u1", value: 1)
        }
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["empty", "fresh(u1)"])
    }

    @Test("Hot launch: cached → fresh (stale cache → revalidate)")
    func hotLaunchStaleCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // Pre-seed cache with an old payload.
        let oldPayload = Payload(id: "old", value: 1)
        let encoded = try JSONEncoder.hlDefault.encode(oldPayload)
        try await cache.write(.healthScore, payload: encoded, at: Date().addingTimeInterval(-120))
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        var sequence: [String] = []
        let stream = await coordinator.observe(.healthScore, decoding: Payload.self) {
            Payload(id: "new", value: 2)
        }
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(old)", "fresh(new)"])
    }

    @Test("Fresh cache: cached → fresh from cache (no fetch)")
    func freshCacheServesFromCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // healthScore staleAfter = 60s. Write 1s ago is fresh.
        let payload = Payload(id: "cached", value: 1)
        try await cache.write(.healthScore, payload: JSONEncoder.hlDefault.encode(payload), at: Date().addingTimeInterval(-1))
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // Fetch closure asserts it is NEVER called (cache is fresh).
        let counter = Counter()
        let stream = await coordinator.observe(.healthScore, decoding: Payload.self) {
            counter.increment()
            return Payload(id: "should-not-fetch", value: 99)
        }
        var sequence: [String] = []
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(cached)", "fresh(cached)"])
        #expect(counter.value == 0, "fetch must NOT be called on fresh cache")
    }

    @Test("Offline with cache: cached → finish (no revalidation)")
    func offlineSkipsFetch() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let payload = Payload(id: "offline-cache", value: 1)
        try await cache.write(
            .dashboardSummary(day: "2026-06-06"),
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-3600)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: false))

        let counter = Counter()
        let stream = await coordinator.observe(.dashboardSummary(day: "2026-06-06"), decoding: Payload.self) {
            counter.increment()
            return Payload(id: "must-not-happen", value: 99)
        }
        var sequence: [String] = []
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(offline-cache)"])
        #expect(counter.value == 0, "fetch must NOT run while offline")
    }

    @Test("Revalidation failure: cached → failed(lastKnown:)")
    func revalidationFailurePreservesLastKnown() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let oldPayload = Payload(id: "old", value: 1)
        try await cache.write(.healthScore, payload: JSONEncoder.hlDefault.encode(oldPayload), at: Date().addingTimeInterval(-120))
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        var sawCached = false
        var failedLastKnownId: String?
        let stream = await coordinator.observe(.healthScore, decoding: Payload.self) {
            throw HLError.server(status: 500, code: "BOOM", message: "x")
        }
        for await state in stream {
            switch state {
            case let .cached(value, _): sawCached = value.id == "old"
            case let .failed(_, lastKnown): failedLastKnownId = lastKnown?.id
            default: break
            }
        }
        #expect(sawCached)
        #expect(failedLastKnownId == "old")
    }

    // MARK: - forceRevalidate (W8-B1)

    @Test("Fresh cache + forceRevalidate: cached → fresh from network (TTL bypassed)")
    func forceRevalidateBypassesFreshCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // dashboardSummary TTL is 45s. A 1s-old write is well within the
        // window, so a non-forced observe would short-circuit to cache.
        let payload = Payload(id: "cached", value: 1)
        try await cache.write(
            .dashboardSummary(day: "2026-06-06"),
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-1)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let counter = Counter()
        var sequence: [String] = []
        let stream = await coordinator.observe(
            .dashboardSummary(day: "2026-06-06"),
            decoding: Payload.self,
            forceRevalidate: true
        ) {
            counter.increment()
            return Payload(id: "forced", value: 2)
        }
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(cached)", "fresh(forced)"])
        #expect(counter.value == 1, "forceRevalidate must hit the network even on fresh cache")
    }

    @Test("Fresh cache, no force: served from cache within TTL (no network)")
    func freshCacheWithinTTLServesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // 1s-old dashboardSummary is inside the 45s TTL → cache-served.
        let payload = Payload(id: "warm", value: 1)
        try await cache.write(
            .dashboardSummary(day: "2026-06-06"),
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-1)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let counter = Counter()
        var sequence: [String] = []
        let stream = await coordinator.observe(.dashboardSummary(day: "2026-06-06"), decoding: Payload.self) {
            counter.increment()
            return Payload(id: "should-not-fetch", value: 99)
        }
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(warm)", "fresh(warm)"])
        #expect(counter.value == 0, "within-TTL bounce must NOT hit the network")
    }

    @Test("forceRevalidate while offline still serves cache (no throw)")
    func forceRevalidateOfflineServesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let payload = Payload(id: "offline-warm", value: 1)
        try await cache.write(
            .dashboardSummary(day: "2026-06-06"),
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-1)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: false))

        let counter = Counter()
        var sequence: [String] = []
        let stream = await coordinator.observe(
            .dashboardSummary(day: "2026-06-06"),
            decoding: Payload.self,
            forceRevalidate: true
        ) {
            counter.increment()
            return Payload(id: "must-not-happen", value: 99)
        }
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        #expect(sequence == ["cached(offline-warm)"])
        #expect(counter.value == 0, "forced refresh while offline must not fetch")
    }

    @Test("fetchCachingFirst + forceRevalidate: fresh cache routes through fetch")
    func fetchCachingFirstForceBypassesFreshCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let payload = Payload(id: "warm", value: 1)
        try await cache.write(
            .measurementsRecent(limit: 400),
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-1)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let counter = Counter()
        let result = try await coordinator.fetchCachingFirst(
            .measurementsRecent(limit: 400),
            decoding: Payload.self,
            forceRevalidate: true
        ) {
            counter.increment()
            return Payload(id: "forced", value: 2)
        }
        #expect(result.id == "forced")
        #expect(counter.value == 1, "forceRevalidate must hit the network even on fresh cache")
    }

    // MARK: - single-flight (W8-B2)

    @Test("Concurrent observers of the same key collapse to one fetch")
    func singleFlightCollapsesConcurrentObservers() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // Cold cache → both observers reach the fetch step concurrently.
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let counter = Counter()
        /// A fetch that blocks briefly so the second observer enters the
        /// revalidate step while the first is still in-flight.
        @Sendable func fetch() async throws -> Payload {
            counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return Payload(id: "shared", value: 1)
        }

        async let a: [String] = drain(coordinator.observe(.dashboardSummary(day: "2026-06-06"), decoding: Payload.self, fetch: fetch))
        async let b: [String] = drain(coordinator.observe(.dashboardSummary(day: "2026-06-06"), decoding: Payload.self, fetch: fetch))
        let (seqA, seqB) = await (a, b)

        #expect(seqA.contains("fresh(shared)"))
        #expect(seqB.contains("fresh(shared)"))
        #expect(counter.value == 1, "two concurrent observers of one key must share a single network fetch")
    }

    @Test("Concurrent fetchCachingFirst of the same key collapse to one fetch")
    func singleFlightCollapsesConcurrentFetchCachingFirst() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let counter = Counter()
        @Sendable func fetch() async throws -> Payload {
            counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return Payload(id: "shared", value: 7)
        }

        async let a = try coordinator.fetchCachingFirst(.measurementsRecent(limit: 400), decoding: Payload.self, fetch: fetch)
        async let b = try coordinator.fetchCachingFirst(.measurementsRecent(limit: 400), decoding: Payload.self, fetch: fetch)
        let (ra, rb) = try await (a, b)

        #expect(ra.value == 7)
        #expect(rb.value == 7)
        #expect(counter.value == 1, "two concurrent fetchCachingFirst of one key must share a single fetch")
    }

    /// Drains an observe stream into its label sequence (test helper).
    private func drain(_ stream: AsyncStream<SWRState<Payload>>) async -> [String] {
        var sequence: [String] = []
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
        }
        return sequence
    }

    // MARK: - fetchCachingFirst (W1-1)

    @Test("fetchCachingFirst — fresh cache returns cached, never calls fetch")
    func fetchCachingFirstHitsCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let payload = Payload(id: "cached", value: 1)
        try await cache.write(
            .healthScore,
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-1)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let counter = Counter()
        let result = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            counter.increment()
            return Payload(id: "should-not-fetch", value: 99)
        }
        #expect(result.id == "cached")
        #expect(counter.value == 0, "fetch must NOT be called on fresh cache")
    }

    @Test("fetchCachingFirst — stale cache + online routes through fetch + writes back")
    func fetchCachingFirstRevalidates() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let payload = Payload(id: "old", value: 1)
        try await cache.write(
            .healthScore,
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-120)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let result = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            Payload(id: "fresh", value: 2)
        }
        #expect(result.id == "fresh")
        // The revalidation cache write-back is detached (W-PERF-SWR) — drain it
        // before peeking so the assertion is deterministic (no race).
        await coordinator.drainPendingWrites()
        // Write-back: a subsequent fetch with a fetch-closure that throws
        // returns the just-cached value (proving the cache was written).
        let cached: Cached<Payload>? = await coordinator.peek(.healthScore, as: Payload.self)
        #expect(cached?.value.id == "fresh")
    }

    @Test("fetchCachingFirst — offline + stale cache serves cache (no throw)")
    func fetchCachingFirstOfflineServesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let payload = Payload(id: "offline-cache", value: 1)
        try await cache.write(
            .healthScore,
            payload: JSONEncoder.hlDefault.encode(payload),
            at: Date().addingTimeInterval(-3600)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: false))

        let counter = Counter()
        let result = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            counter.increment()
            return Payload(id: "must-not-happen", value: 99)
        }
        #expect(result.id == "offline-cache")
        #expect(counter.value == 0, "fetch must NOT be called while offline")
    }

    @Test("fetchCachingFirst — cold (no cache) calls fetch and writes back")
    func fetchCachingFirstCold() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let result = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            Payload(id: "cold-fetch", value: 42)
        }
        #expect(result.id == "cold-fetch")
        // W-PERF-SWR C2 — the cache write-through is now DETACHED (the fresh
        // value returns before the disk flush), so drain the pending persists
        // before asserting the row landed for a cold read-back.
        await coordinator.drainPendingWrites()
        let cached: Cached<Payload>? = await coordinator.peek(.healthScore, as: Payload.self)
        #expect(cached?.value.value == 42)
    }

    @Test("Epoch mismatch drops persistence but still yields the fetched fresh value")
    func epochMismatchStillYieldsFreshToConsumer() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let gate = FetchGate()
        let stream = await coordinator.observe(.healthScore, decoding: Payload.self) {
            await gate.enterAndWaitForRelease()
            return Payload(id: "old-account", value: 1)
        }
        let drainTask = Task { await drain(stream) }
        await gate.waitUntilEntered()

        await coordinator.invalidateAll()
        await gate.release()
        let sequence = await drainTask.value

        #expect(sequence == ["empty", "fresh(old-account)"])
        let cached: Cached<Payload>? = await coordinator.peek(.healthScore, as: Payload.self)
        #expect(cached == nil, "epoch mismatch must still prevent stale cache persistence")
    }

    private actor FetchGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWaitForRelease() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    /// Atomic counter for Sendable closure capture in fetch-call accounting.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int {
            lock.withLock { _value }
        }

        @discardableResult
        func increment() -> Int {
            lock.withLock { _value += 1
                return _value
            }
        }
    }
}
