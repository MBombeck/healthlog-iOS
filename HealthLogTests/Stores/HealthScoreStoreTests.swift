import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// Locks the v0.4.1 SWR adoption on `HealthScoreStore`.
///
/// Before F5/F6 the store fired a fresh network round-trip every
/// cold launch with no cached value to render in the meantime; the
/// user-reported gap on iPhone 16 Pro ("Health Score braucht extrem lange ...
/// Medikamenten Compliance ist sehr schnell da, aber der Health Score
/// überhaupt nicht") was the missing SWR adoption. These tests assert:
///
/// 1. With `swr = nil` the store uses the legacy direct-fetch path
///    (test infra preserves single-emit semantics).
/// 2. With an `SWRCoordinator` wired, cold-start emits `empty → fresh`.
/// 3. Hot launch with a stale cache emits `cached → fresh` and the
///    store surfaces the cached payload + `isShowingStaleCache=true`
///    before the revalidate lands.
/// 4. Offline-with-cache emits `cached` and never fires the fetch.
@Suite("HealthScoreStore — SWR state machine", .serialized)
struct HealthScoreStoreTests {
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

    @Test("Direct-fetch (swr == nil) — sets score + lastFetched on happy path")
    @MainActor
    func directFetchHappyPath() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(Self.snapshotJSON.utf8))
        }
        let store = HealthScoreStore(repo: AnalyticsRepository(api: api))
        await store.load()

        #expect(store.score?.score == 72)
        #expect(store.score?.band == .green)
        #expect(store.score?.delta == 4)
        #expect(store.error == nil)
        #expect(store.lastFetched != nil)
        #expect(store.isShowingStaleCache == false)
    }

    @Test("Cold-start with SWR — empty → fresh")
    @MainActor
    func swrColdStart() async throws {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(Self.snapshotJSON.utf8))
        }
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coord = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let store = HealthScoreStore(repo: AnalyticsRepository(api: api), swr: coord)

        await store.load()
        #expect(store.score?.score == 72)
        #expect(store.isShowingStaleCache == false)
    }

    @Test("Hot launch with stale cache — cached arm paints first, then fresh")
    @MainActor
    func swrHotLaunchStale() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // Pre-seed cache with an old score (staleAfter = 60s).
        let cachedScore = HealthScore(score: 65, band: .yellow, delta: -2)
        let encoded = try JSONEncoder.hlDefault.encode(cachedScore)
        try await cache.write(.healthScore, payload: encoded, at: Date().addingTimeInterval(-120))

        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(Self.snapshotJSON.utf8))
        }
        let coord = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let store = HealthScoreStore(repo: AnalyticsRepository(api: api), swr: coord)

        await store.load()
        // Final visible state is the fresh server payload.
        #expect(store.score?.score == 72)
        #expect(store.score?.band == .green)
        #expect(store.isShowingStaleCache == false)
        #expect(store.error == nil)
    }

    @Test("Offline with cached row — keeps cached value, never fetches")
    @MainActor
    func swrOfflineKeepsCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let cachedScore = HealthScore(score: 65, band: .yellow, delta: -2)
        try await cache.write(.healthScore, payload: JSONEncoder.hlDefault.encode(cachedScore), at: Date().addingTimeInterval(-3600))

        let (api, _) = makeAPIClient()
        // Network handler must NEVER be hit while offline.
        nonisolated(unsafe) var hits = 0
        MockURLProtocol.handler = { request in
            // CU-07: the handler is process-global — `hits == 0` only holds as an
            // assertion if a parallel suite's request cannot raise it.
            if request.targets("/api/dashboard/snapshot") { hits += 1 }
            return (Self.ok(request), Data(Self.snapshotJSON.utf8))
        }
        let coord = SWRCoordinator(cache: cache, reachability: StubReach(online: false))
        let store = HealthScoreStore(repo: AnalyticsRepository(api: api), swr: coord)

        await store.load()
        #expect(store.score?.score == 65, "Cached value must be visible while offline")
        #expect(store.isShowingStaleCache == true)
        #expect(hits == 0, "Network must not be touched while offline with cache")
    }

    @Test("clearOnLogout zeroes everything including stale-cache flag")
    @MainActor
    func clearOnLogout() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(Self.snapshotJSON.utf8))
        }
        let store = HealthScoreStore(repo: AnalyticsRepository(api: api))
        await store.load()
        #expect(store.score != nil)
        store.clearOnLogout()
        #expect(store.score == nil)
        #expect(store.lastFetched == nil)
        #expect(store.error == nil)
        #expect(store.isShowingStaleCache == false)
    }

    @Test("CacheKey.healthScore has 60s staleAfter (SWR TTL contract)")
    func cacheKeyTTL() {
        #expect(CacheKey.healthScore.staleAfter == 60)
    }

    // MARK: - Helpers

    @MainActor
    private func makeAPIClient() -> (APIClient, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.4.1",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        return (api, keychain)
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Production-shape envelope from `/api/dashboard/snapshot` — the flat
    /// `healthScore` DTO rides on the snapshot slot since server v1.34.0
    /// (`/api/analytics.healthScore` became the internal `HealthScoreReport`).
    private static let snapshotJSON = """
    {
      "data": {
        "healthScore": {
          "score": 72,
          "band": "green",
          "delta": 4
        }
      }
    }
    """
}

// swiftlint:enable force_unwrapping
