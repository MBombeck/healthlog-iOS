import Foundation
import SwiftData

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the SWR-wrap on `MeasurementsRepository` (W1-1 / R5 #5).
///
/// Covers:
/// - `recent(limit:)` + `series(kind:days:)` hit cache on warm reads, fire
///   network on cold / stale reads.
/// - `create(_:)` invalidates the affected keys (so a follow-up read sees a
///   cold fetch even when the cache was warm).
/// - Outbox-replay path (`replay(_:idempotencyKey:)`) invalidates too — this
///   is the most common write surface for cached data (offline-create then
///   network-replay).
@Suite("MeasurementsRepository SWR-wrap", .serialized)
struct MeasurementsRepositorySWRTests {
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

    private func makeRepoWithCache() throws -> (MeasurementsRepository, SWRCoordinator) {
        let (repo, swr, _) = try makeRepoCacheTriple()
        return (repo, swr)
    }

    private func makeRepoCacheTriple() throws -> (MeasurementsRepository, SWRCoordinator, SWRCache) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true), swr: swr)
        return (repo, swr, cache)
    }

    private func emptySeriesPayload() -> Data {
        Data(#"""
        {"data":{"kind":"weight","points":[],"stats":{"mean":0,"min":0,"max":0,"stdDev":0,"count":0}}}
        """#.utf8)
    }

    private func emptyMeasurementsPayload() -> Data {
        Data(#"""
        {"data":{"measurements":[]}}
        """#.utf8)
    }

    @Test("series(kind:days:) — warm cache returns without network call")
    func seriesUsesCache() async throws {
        let (repo, swr) = try makeRepoWithCache()
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — count only the series
            // endpoint so a parallel suite's request cannot move this counter.
            if req.targets("/api/measurements/series") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, emptySeriesPayload())
        }
        // First call warms the cache.
        _ = try await repo.series(kind: .weight, days: 30)
        // W-PERF-SWR C2 — the write-through is detached, so the warm-cache
        // short-circuit on the second read only holds once the persist lands.
        await swr.drainPendingWrites()
        // Second call inside the staleAfter window (30s for measurementSeries)
        // must hit cache — no network.
        _ = try await repo.series(kind: .weight, days: 30)
        #expect(calls == 1, "second series() within staleAfter must serve cache")
    }

    @Test("recent(limit:) — warm cache short-circuits second call")
    func recentUsesCache() async throws {
        let (repo, swr) = try makeRepoWithCache()
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: count only the recent-list GET — a request from a suite
            // running in parallel must not be attributed to this assertion.
            if req.targets("/api/measurements", method: "GET") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, emptyMeasurementsPayload())
        }
        _ = try await repo.recent(limit: 50)
        // W-PERF-SWR C2 — drain the detached write-through before the warm read.
        await swr.drainPendingWrites()
        // W8-B1 — measurementsRecent now carries a 45s TTL (was staleAfter=0).
        // A second call inside the window short-circuits to cache with no
        // network round-trip — this is the warm-relaunch cache-paint win.
        // Pull-to-refresh bypasses this via the `forceRevalidate` path
        // (covered in SWRCoordinatorTests).
        _ = try await repo.recent(limit: 50)
        #expect(calls == 1, "measurementsRecent within its 45s TTL must serve cache")
    }

    private func makeRepo(cache: SWRCache, online: Bool) throws -> MeasurementsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach(online: online))
        return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true), swr: swr)
    }

    @Test("recent — offline + warm cache serves cache (no network)")
    func recentOfflineServesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        // Pre-warm cache by going online first…
        let onlineRepo = try makeRepo(cache: cache, online: true)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: count only the recent-list GET — a request from a suite
            // running in parallel must not be attributed to this assertion.
            if req.targets("/api/measurements", method: "GET") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, emptyMeasurementsPayload())
        }
        _ = try await onlineRepo.recent(limit: 50)
        #expect(calls == 1)
        // …then re-issue offline. Cache row exists; the offline branch
        // returns cached without firing network regardless of the TTL.
        let offlineRepo = try makeRepo(cache: cache, online: false)
        _ = try await offlineRepo.recent(limit: 50)
        #expect(calls == 1, "offline serve must skip network")
    }

    @Test("replay(_:idempotencyKey:) invalidates cache so next read re-fetches")
    func replayInvalidatesCache() async throws {
        let (repo, swr) = try makeRepoWithCache()
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: this test counts both surfaces it drives — the series GET
            // and the replay POST — and nothing else.
            if req.targets("/api/measurements/series") || req.targets("/api/measurements", method: "POST") {
                calls += 1
            }
            if req.targets("/api/measurements/series") {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, emptySeriesPayload())
            }
            // POST /api/measurements responds with an echo MeasurementWireDTO
            // wrapped in the `{ data, error }` envelope. Built up by hand to
            // stay under SwiftLint's 200-char line cap.
            let echoJSON =
                #"{"data":{"id":"srv-1","userId":null,"type":"WEIGHT","value":80.0,"#
                    + #""measuredAt":"2026-05-15T10:00:00Z","notes":null,"source":"MANUAL","#
                    + #""glucoseContext":null,"externalId":null,"createdAt":null,"updatedAt":null},"#
                    + #""error":null}"#
            let echo = Data(echoJSON.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echo)
        }
        _ = try await repo.series(kind: .weight, days: 30)
        #expect(calls == 1)
        // W-PERF-SWR C2 — drain the detached write-through before the warm hit.
        await swr.drainPendingWrites()
        // Warm hit
        _ = try await repo.series(kind: .weight, days: 30)
        #expect(calls == 1, "second series() within staleAfter should serve cache")
        // Replay simulates outbox-flush: writes a measurement of the same
        // kind. The repository invalidates `.measurementSeries(.weight,
        // days: 30)` (among others), so the next series() must re-fetch.
        let m = Measurement(
            id: "local-1",
            kind: .weight,
            recordedAt: Date(),
            value: .scalar(80.0),
            note: nil,
            source: .manual,
            externalUUID: nil
        )
        _ = try await repo.replay(m, idempotencyKey: "test-key")
        _ = try await repo.series(kind: .weight, days: 30)
        #expect(calls >= 3, "series() after replay must re-fetch (calls: \(calls))")
    }

    // MARK: - AUD-3 D-3 — dashboardSummary invalidation uses the PROFILE timezone

    /// After a write, the repository must invalidate the `.dashboardSummary`
    /// row keyed on the SERVER-PROFILE day — the same key `DashboardStore`
    /// reads. Pre-D-3 it anchored on the device-TZ day, so for a TZ-mismatched
    /// user the invalidation missed the dashboard's real row and the compliance
    /// ring stale-served. This wires a profile zone whose calendar day differs
    /// from the device day at the test instant, seeds that profile-TZ row, runs
    /// a write, and asserts the profile-TZ row was the one dropped.
    @Test("write invalidates dashboardSummary on the profile-TZ day (AUD-3 D-3)")
    func writeInvalidatesProfileTZDashboardSummary() async throws {
        let (repo, _, cache) = try makeRepoCacheTriple()

        // A far-offset zone (UTC+14) whose calendar day differs from UTC's at
        // the test instant — proving the invalidation tracks the PROFILE zone,
        // not the device/UTC day. The repo invalidates against its own `.now`,
        // so the seeded key uses the SAME profile-zone "today".
        let profileZone = TimeZone(identifier: "Pacific/Kiritimati") ?? .gmt
        await repo.setProfileTimeZoneProvider { profileZone }

        let profileDay = MedicationDayKey.string(timeZone: profileZone)
        let utcDay = MedicationDayKey.string(timeZone: .gmt)

        // Seed BOTH the profile-TZ row (dashboard's real key) and, when it
        // differs, the UTC-day row (the pre-D-3 device-anchored key) so the test
        // proves the PROFILE row — not the UTC row — is the one dropped.
        struct Probe: Codable, Sendable { let x: Int }
        let payload = try JSONEncoder.hlDefault.encode(Probe(x: 1))
        try await cache.write(.dashboardSummary(day: profileDay), payload: payload)
        if utcDay != profileDay {
            try await cache.write(.dashboardSummary(day: utcDay), payload: payload)
        }
        #expect(await cache.read(.dashboardSummary(day: profileDay), as: Probe.self) != nil)

        MockURLProtocol.handler = { req in
            let echoJSON =
                #"{"data":{"id":"srv-2","userId":null,"type":"WEIGHT","value":80.0,"#
                    + #""measuredAt":"2026-05-15T10:00:00Z","notes":null,"source":"MANUAL","#
                    + #""glucoseContext":null,"externalId":null,"createdAt":null,"updatedAt":null},"#
                    + #""error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(echoJSON.utf8))
        }

        let m = Measurement(
            id: "local-2", kind: .weight, recordedAt: Date.now, value: .scalar(80.0),
            note: nil, source: .manual, externalUUID: nil
        )
        _ = try await repo.replay(m, idempotencyKey: "tz-key")

        // The PROFILE-TZ row must be invalidated (the dashboard's real key).
        let profileRow: Cached<Probe>? = await cache.read(.dashboardSummary(day: profileDay), as: Probe.self)
        #expect(profileRow == nil, "write must invalidate the profile-TZ dashboardSummary row")
    }
}
