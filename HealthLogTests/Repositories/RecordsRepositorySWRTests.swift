import Foundation
import SwiftData

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// QOL-OFF-2 — locks the SWR cache-first wiring on the second-tier PHI read
/// surfaces (`LabsRepository`, `AllergiesRepository`, `FamilyHistoryRepository`,
/// `MentalHealthRepository`) added so those screens are READABLE on a cold
/// offline launch instead of rendering the empty "add your first…" state.
///
/// Covers, per repo:
/// - the canonical unfiltered read serves cache on a warm second call (no
///   redundant network round-trip within the TTL),
/// - an offline re-issue serves the cached row without touching the network,
/// - a successful write invalidates the list key so the mutation is never masked
///   by a fresh-enough cached row,
/// - a filtered / paged read bypasses the cache (network-direct — no per-filter
///   cache-key explosion).
@Suite("Records repos SWR cache-first (QOL-OFF-2)", .serialized)
struct RecordsRepositorySWRTests {
    private struct StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
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

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeSWR(cache: SWRCache, online: Bool) -> SWRCoordinator {
        SWRCoordinator(cache: cache, reachability: StubReach(online: online))
    }

    private static func envelope(_ inner: String) -> Data {
        Data(#"{"data":\#(inner),"error":null}"#.utf8)
    }

    // MARK: - Labs

    @Test("labs(limit:) — warm cache short-circuits the second call")
    func labsUsesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — only OUR route counts.
            if req.targets("/api/labs") { calls += 1 }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(#"{"results":[],"meta":{"total":0}}"#)
            )
        }
        _ = try await repo.labs(limit: 500)
        await swr.drainPendingWrites()
        _ = try await repo.labs(limit: 500)
        #expect(calls == 1, "second labs() within the 60s TTL must serve cache")
    }

    @Test("labs(limit:) — offline + warm cache serves cache (no network)")
    func labsOfflineServesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/labs") { calls += 1 }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(#"{"results":[]}"#)
            )
        }
        let online = try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: makeSWR(cache: cache, online: true))
        _ = try await online.labs(limit: 500)
        await makeSWR(cache: cache, online: true).drainPendingWrites()
        #expect(calls == 1)
        let offline = try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: makeSWR(cache: cache, online: false))
        _ = try await offline.labs(limit: 500)
        #expect(calls == 1, "offline serve must skip the network")
    }

    @Test("labs — a filtered read bypasses the cache (network-direct)")
    func labsFilteredBypassesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/labs") { calls += 1 }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(#"{"results":[]}"#)
            )
        }
        _ = try await repo.labs(analyte: "GGT", limit: 500)
        await swr.drainPendingWrites()
        _ = try await repo.labs(analyte: "GGT", limit: 500)
        #expect(calls == 2, "an analyte-filtered read must not be cached")
    }

    @Test("deleteLab invalidates .labsResults so the next read re-fetches")
    func deleteLabInvalidates() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        struct Probe: Codable, Sendable { let x: Int }
        try await cache.write(.labsResults, payload: JSONEncoder.hlDefault.encode(Probe(x: 1)))
        #expect(await cache.read(.labsResults, as: Probe.self) != nil)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(#"{"deleted":true}"#)
            )
        }
        try await repo.deleteLab(id: "lab-1")
        #expect(await cache.read(.labsResults, as: Probe.self) == nil, "deleteLab must invalidate .labsResults")
    }

    // MARK: - Allergies

    @Test("allergies list — warm cache short-circuits; delete invalidates")
    func allergiesCacheAndInvalidate() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try AllergiesRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var listCalls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/allergies", method: "GET") { listCalls += 1 }
            let body = req.httpMethod == "DELETE" ? #"{"deleted":true}"# : "[]"
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(body)
            )
        }
        _ = try await repo.list(includeInactive: true)
        await swr.drainPendingWrites()
        _ = try await repo.list(includeInactive: true)
        #expect(listCalls == 1, "second allergies list within the TTL must serve cache")
        _ = try await repo.delete(id: "a-1")
        _ = try await repo.list(includeInactive: true)
        #expect(listCalls == 2, "delete must invalidate .allergies so the next read re-fetches")
    }

    @Test("allergies — active-only (includeInactive:false) bypasses the cache")
    func allergiesActiveOnlyBypassesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try AllergiesRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/allergies") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.envelope("[]"))
        }
        _ = try await repo.list(includeInactive: false)
        await swr.drainPendingWrites()
        _ = try await repo.list(includeInactive: false)
        #expect(calls == 2, "the active-only variant must stay network-direct")
    }

    // MARK: - Family history

    @Test("family-history list — warm cache short-circuits; delete invalidates")
    func familyHistoryCacheAndInvalidate() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try FamilyHistoryRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var listCalls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/family-history", method: "GET") { listCalls += 1 }
            let body = req.httpMethod == "DELETE" ? #"{"deleted":true}"# : "[]"
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(body)
            )
        }
        _ = try await repo.list()
        await swr.drainPendingWrites()
        _ = try await repo.list()
        #expect(listCalls == 1, "second family-history list within the TTL must serve cache")
        _ = try await repo.delete(id: "f-1")
        _ = try await repo.list()
        #expect(listCalls == 2, "delete must invalidate .familyHistory")
    }

    // MARK: - Mental-health history

    @Test("mental-health history — warm cache short-circuits the second call")
    func mentalHistoryUsesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try MentalHealthRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/mental-health/assessments") { calls += 1 }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(#"{"assessments":[]}"#)
            )
        }
        _ = try await repo.history()
        await swr.drainPendingWrites()
        _ = try await repo.history()
        #expect(calls == 1, "second mental-health history within the TTL must serve cache")
    }

    @Test("mental-health history — an instrument filter bypasses the cache")
    func mentalHistoryFilteredBypassesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = makeSWR(cache: cache, online: true)
        let repo = try MentalHealthRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), swr: swr)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/mental-health/assessments") { calls += 1 }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.envelope(#"{"assessments":[]}"#)
            )
        }
        _ = try await repo.history(instrument: .phq9)
        await swr.drainPendingWrites()
        _ = try await repo.history(instrument: .phq9)
        #expect(calls == 2, "an instrument-filtered history read must not be cached")
    }
}
