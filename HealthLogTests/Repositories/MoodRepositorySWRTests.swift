import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.3 E3 — locks the SWR-wrap on `MoodRepository.recent(days:)`.
///
/// The Stimmung card lagged the web because `MoodRepository.recent` was a direct
/// network fetch with no SWR cache — freshness was entirely driven by the store's
/// 60s gate + an explicit pull-to-refresh. The repo now routes through the
/// `.moodEntries(days:)` SWR row (cache-first, 60s TTL) so a foreground bounce
/// paints from disk and revalidates in the background.
///
/// Covers:
/// - a warm read inside the `staleAfter` window serves cache (no second network).
/// - distinct `days` windows are distinct cache rows (no cross-window collision).
/// - with NO coordinator wired (unit-test default) every call hits the network.
@Suite("MoodRepository SWR-wrap (E3)", .serialized)
struct MoodRepositorySWRTests {
    private struct StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(online)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.3",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func onePageBody() -> Data {
        Data(#"""
        {"data":{"entries":[
          {"id":"srv-mood-1","mood":"GUT","tags":[],"moodLoggedAt":"2026-06-04T08:00:00.000Z","source":"MANUAL","note":null}
        ],"meta":{"total":1,"limit":500,"offset":0}}}
        """#.utf8)
    }

    @Test("recent(days:) — warm cache serves the second call without network")
    func warmCacheServesSecondCall() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { [body = onePageBody()] req in
            if req.targets("/api/mood-entries") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let first = try await repo.recent(days: 365)
        #expect(first.count == 1)
        // The revalidation cache write is detached (W-PERF-SWR) — drain it so the
        // warm read below sees the persisted row deterministically (no race).
        await swr.drainPendingWrites()
        // Second read inside the 60s `.moodEntries` TTL must serve cache.
        let second = try await repo.recent(days: 365)
        #expect(second.count == 1)
        #expect(calls == 1, "second recent(days:) within staleAfter must serve cache")
    }

    @Test("recent(days:) — distinct day windows are distinct cache rows")
    func distinctWindowsDistinctRows() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { [body = onePageBody()] req in
            if req.targets("/api/mood-entries") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.recent(days: 365)
        _ = try await repo.recent(days: 30)
        #expect(calls == 2, "a different day-window is a different key → its own fetch")
    }

    @Test("recent(days:) — no coordinator wired → direct fetch each call")
    func noCoordinatorDirectFetch() async throws {
        let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { [body = onePageBody()] req in
            if req.targets("/api/mood-entries") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.recent(days: 365)
        _ = try await repo.recent(days: 365)
        #expect(calls == 2, "without SWR every call hits the network (unit-test default)")
    }
}

// swiftlint:enable force_unwrapping
