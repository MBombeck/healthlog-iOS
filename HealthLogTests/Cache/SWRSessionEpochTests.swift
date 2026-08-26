import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// **v0.13 WS Item 2 — SWR in-flight revalidation post-purge leak.**
///
/// `invalidateAll()` (logout / switch-server) purges the cache, but an
/// in-flight revalidation issued against the OLD user/server resolves its
/// `fetch()` and then write-throughs its payload — landing stale data back
/// into the just-purged cache AFTER the purge. The fix captures a session
/// epoch before `fetch()` and re-checks it before `cache.write()`; a write
/// whose epoch moved is dropped. These tests prove the drop.
@Suite("SWR session-epoch post-invalidate guard")
struct SWRSessionEpochTests {
    private struct Payload: Codable, Equatable {
        let id: String
        let value: Int
    }

    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(online)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    /// Two-phase gate: the fetch signals it has started, then suspends until
    /// the test releases it. Lets the test interleave `invalidateAll()`
    /// strictly between fetch-start and fetch-resume.
    private actor Gate {
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var started = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        func signalStarted() {
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
        }

        func awaitStarted() async {
            if started { return }
            await withCheckedContinuation { startedContinuation = $0 }
        }

        func release() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func awaitRelease() async {
            if released { return }
            await withCheckedContinuation { releaseContinuation = $0 }
        }
    }

    @Test("In-flight write-through resolving AFTER invalidateAll does NOT repopulate the cache")
    func staleWriteDroppedAfterInvalidate() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let gate = Gate()

        // Kick off a revalidation on an empty (cold) cache → network path.
        // The fetch signals start, then suspends until the test releases it.
        let fetchTask = Task {
            try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
                await gate.signalStarted()
                await gate.awaitRelease()
                return Payload(id: "stale-old-user", value: 1)
            }
        }

        // Wait until the fetch is genuinely in-flight.
        await gate.awaitStarted()

        // User logs out / switches server mid-fetch.
        await coordinator.invalidateAll()

        // Now let the in-flight fetch resume + attempt its write-through.
        await gate.release()
        _ = try await fetchTask.value

        // The stale payload must NOT have landed in the purged cache.
        let peeked: Cached<Payload>? = await coordinator.peek(.healthScore, as: Payload.self)
        #expect(peeked == nil, "a pre-invalidate fetch must not repopulate the cache after the purge")
    }

    @Test("Normal revalidation (no intervening invalidate) still writes through")
    func normalWriteStillLands() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let value = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            Payload(id: "fresh", value: 7)
        }
        #expect(value == Payload(id: "fresh", value: 7))

        // No invalidate happened → the write-through persisted. W-PERF-SWR C2 —
        // the persist is detached, so drain it before asserting the row landed.
        await coordinator.drainPendingWrites()
        let peeked: Cached<Payload>? = await coordinator.peek(.healthScore, as: Payload.self)
        #expect(peeked?.value == Payload(id: "fresh", value: 7), "uninterrupted revalidation must write through normally")
    }

    /// W-RECONCILE M-1 — `invalidateAll()` now DRAINS (awaits) pending detached
    /// writes before purging, instead of only cancelling. This locks that the
    /// drain completes (no hang) and that a write-through landed BEFORE the
    /// invalidate is gone after the purge — the cache is empty, with no late
    /// re-insertion racing the purge.
    @Test("invalidateAll drains pending writes then purges — no stale row survives")
    func invalidateDrainsThenPurges() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // A completed revalidation schedules a detached persist into pendingWrites.
        _ = try await coordinator.fetchCachingFirst(.healthScore, decoding: Payload.self) {
            Payload(id: "old-user", value: 1)
        }
        // Logout: the drain must await the pending persist, then purge. If the
        // drain deadlocked this await would never return.
        await coordinator.invalidateAll()

        let peeked: Cached<Payload>? = await coordinator.peek(.healthScore, as: Payload.self)
        #expect(peeked == nil, "the purge must win — no previous-user row survives the drain+purge ordering")
    }
}
