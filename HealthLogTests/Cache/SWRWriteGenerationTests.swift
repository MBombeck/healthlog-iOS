import Foundation
@testable import HealthLog
import Testing

/// Build 273 (A9) — a revalidation that was in flight when an optimistic
/// write-through landed must not persist its (older) payload over the written
/// one. Only the session epoch guarded the disk write; per key nothing moved.
/// Scenario: foreground GET in flight → "Taken" POST lands and writes through →
/// GET completes and persisted "pending" → next offline cold launch showed the
/// dose as open with an enabled button.
@Suite("SWR — write-through wins over an in-flight revalidation")
struct SWRWriteGenerationTests {
    private struct Payload: Codable, Equatable, Sendable {
        let id: String
        let value: Int
    }

    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(true)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }

        func confirmedReachable() async -> Bool {
            true
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("disk keeps the written value after the older fetch completes")
    func writeThroughSurvivesInFlightRevalidation() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let key = CacheKey.measurementsRecent(limit: 400)
        try await cache.write(
            key,
            payload: JSONEncoder.hlDefault.encode(Payload(id: "stale", value: 0)),
            at: Date().addingTimeInterval(-3600)
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        let gate = Gate()

        let fetchTask = Task {
            try await coordinator.fetchCachingFirst(key, decoding: Payload.self, forceRevalidate: true) {
                await gate.wait()
                return Payload(id: "server-before-write", value: 1)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        await coordinator.writeThrough(key, value: Payload(id: "written", value: 2))
        await gate.open()
        _ = try await fetchTask.value
        try await Task.sleep(for: .milliseconds(300))

        let onDisk: Cached<Payload>? = await cache.read(key, as: Payload.self)
        #expect(onDisk?.value.id == "written")
    }
}
