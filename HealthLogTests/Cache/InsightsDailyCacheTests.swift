import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

// W3 (v0.11 Wave #22) — pins the daily-cache + prefetch substrate for the
// server-generated Insights content.
//
// The server regenerates per-metric assessments + the comprehensive digest +
// the advisor briefing ~1×/Berlin-day; iOS mirrors that by anchoring the cache
// key to the Berlin calendar day. These tests lock:
//   - the Berlin-day discriminator (flips at local midnight, bounded ceiling),
//   - that yesterday's cached assessment is served on the `.cached` arm within
//     the same Berlin day (no redundant network),
//   - that a Berlin-day rollover is a structural cache-miss that refetches the
//     freshly-generated content,
//   - the prefetch warm path (gated, fans out, re-entry-guarded).
//
// All network goes through a real `APIClient` + `MockURLProtocol` stub
// URLSession (never a mock server), per PROJECT_GUIDE.md.

// MARK: - Shared helpers

private func makeStubClient(keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
    let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        cfAccessClientID: nil,
        cfAccessClientToken: nil,
        bundleID: "dev.healthlog.app",
        appVersion: "0.1.0",
        buildNumber: "1"
    )
    return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
}

/// Atomic request counter for the Sendable `MockURLProtocol.handler` closure.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ path: String) {
        lock.withLock { paths.append(path) }
    }

    var all: [String] {
        lock.withLock { paths }
    }

    func count(matching needle: String) -> Int {
        lock.withLock { paths.filter { $0.contains(needle) }.count }
    }

    var total: Int {
        lock.withLock { paths.count }
    }
}

private func statusBody(text: String) -> Data {
    Data(#"{"data":{"hasProvider":true,"text":"\#(text)","cached":true,"updatedAt":"2026-06-02T08:00:00Z"}}"#.utf8)
}

// MARK: - BerlinDayKey

@Suite("BerlinDayKey — daily discriminator")
struct BerlinDayKeyTests {
    @Test("string flips at Berlin local midnight, stable within the day")
    func dayStringRollover() throws {
        let iso = ISO8601DateFormatter()
        // 2026-06-02 23:30 Berlin (UTC+2 in June) == 2026-06-02 21:30 UTC.
        let lateNight = try #require(iso.date(from: "2026-06-02T21:30:00Z"))
        // 2026-06-03 00:30 Berlin == 2026-06-02 22:30 UTC.
        let afterMidnight = try #require(iso.date(from: "2026-06-02T22:30:00Z"))
        let earlierSameDay = try #require(iso.date(from: "2026-06-02T07:00:00Z"))

        #expect(BerlinDayKey.string(for: lateNight) == "2026-06-02")
        #expect(BerlinDayKey.string(for: earlierSameDay) == "2026-06-02")
        #expect(BerlinDayKey.string(for: afterMidnight) == "2026-06-03")
        // Rollover proven: same instant-cluster, different day strings.
        #expect(BerlinDayKey.string(for: lateNight) != BerlinDayKey.string(for: afterMidnight))
    }

    @Test("secondsUntilNextMidnight is bounded to (0, 24h]")
    func midnightCeilingBounded() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-02T10:00:00Z"))
        let secs = BerlinDayKey.secondsUntilNextMidnight(from: now)
        #expect(secs > 0)
        #expect(secs <= 24 * 60 * 60)
    }
}

// MARK: - CacheKey day-anchoring

@Suite("CacheKey — insightStatus day anchoring")
struct InsightStatusCacheKeyTests {
    @Test("Same kind+locale, different Berlin day → different persistentHash")
    func dayDifferentiatedHash() {
        let today = CacheKey.insightStatus(kind: .bloodPressure, locale: "de", day: "2026-06-02").persistentHash
        let tomorrow = CacheKey.insightStatus(kind: .bloodPressure, locale: "de", day: "2026-06-03").persistentHash
        let sameAgain = CacheKey.insightStatus(kind: .bloodPressure, locale: "de", day: "2026-06-02").persistentHash
        #expect(today != tomorrow)
        #expect(today == sameAgain)
    }

    @Test("Canonical string embeds kind, locale + day")
    func canonicalShape() {
        let key = CacheKey.insightStatus(kind: .pulse, locale: "en", day: "2026-06-02")
        #expect(key.canonicalString == "insightStatus:pulse:en:2026-06-02")
    }

    @Test("insightsTargets + insightStatus carry non-negative staleAfter")
    func staleAfterNonNegative() {
        #expect(CacheKey.insightsTargets.staleAfter >= 0)
        #expect(CacheKey.insightStatus(kind: .weight, locale: "de", day: "2026-06-02").staleAfter >= 0)
    }
}

// MARK: - Day-key staleness through the repo (real APIClient + stub URLSession)

@Suite("MetricInsightsRepository — Berlin-day SWR staleness", .serialized)
struct MetricInsightsDailyCacheTests {
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

    /// Yesterday's cache under the OLD Berlin-day key is a structural miss for
    /// today's key → the repo refetches the freshly-generated assessment.
    @Test("Day rollover: yesterday's cached row is a miss → refetches today")
    func rolloverRefetches() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // Pre-seed the cache under YESTERDAY's day key with stale text.
        let yesterday = BerlinDayKey.string(for: Date().addingTimeInterval(-24 * 60 * 60))
        let staleDTO = MetricStatusDTO(hasProvider: true, text: "GESTERN", cached: true, updatedAt: nil)
        try await cache.write(
            .insightStatus(kind: .bloodPressure, locale: "de", day: yesterday),
            payload: JSONEncoder.hlDefault.encode(staleDTO)
        )

        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(req.url!.path)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, statusBody(text: "HEUTE"))
        }

        let api = makeStubClient()
        let repo = MetricInsightsRepository(api: api, swr: coordinator)
        let result = try await repo.fetch(metric: .bloodPressure, locale: "de")

        // Today's key missed → network fetched the fresh assessment.
        #expect(result?.text == "HEUTE")
        #expect(log.count(matching: "blood-pressure-status") == 1)
    }

    /// A cached row under TODAY's day key is served from cache — no network.
    @Test("Same Berlin day: today's cached row serves from cache (no fetch)")
    func sameDayServesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let today = BerlinDayKey.string()
        let cachedDTO = MetricStatusDTO(hasProvider: true, text: "CACHED-TODAY", cached: true, updatedAt: nil)
        // Write 1s ago — well within the 24h within-day ceiling → fresh.
        try await cache.write(
            .insightStatus(kind: .bloodPressure, locale: "de", day: today),
            payload: JSONEncoder.hlDefault.encode(cachedDTO),
            at: Date().addingTimeInterval(-1)
        )

        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(req.url!.path)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                statusBody(text: "SHOULD-NOT-FETCH")
            )
        }

        let api = makeStubClient()
        let repo = MetricInsightsRepository(api: api, swr: coordinator)
        let result = try await repo.fetch(metric: .bloodPressure, locale: "de")

        #expect(result?.text == "CACHED-TODAY")
        #expect(log.total == 0, "within-day cache hit must not hit the network")
    }

    /// Cold cache + online → fetch + write-through under today's key, so the
    /// next read of the same day serves from cache.
    @Test("Cold cache: fetches + writes through today's day key")
    func coldFetchWritesThrough() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(req.url!.path)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, statusBody(text: "FRESH"))
        }

        let api = makeStubClient()
        let repo = MetricInsightsRepository(api: api, swr: coordinator)
        let first = try await repo.fetch(metric: .bloodPressure, locale: "de")
        #expect(first?.text == "FRESH")
        #expect(log.count(matching: "blood-pressure-status") == 1)

        // Write-through proven: today's key now holds the fresh value.
        let peeked: Cached<MetricStatusDTO>? = await coordinator.peek(
            .insightStatus(kind: .bloodPressure, locale: "de", day: BerlinDayKey.string()),
            as: MetricStatusDTO.self
        )
        #expect(peeked?.value.text == "FRESH")
    }
}

// MARK: - Prefetch warm path

@Suite("InsightsPrefetchService — warm path", .serialized)
struct InsightsPrefetchServiceTests {
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(true)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    private func makeService(shouldWarm: @escaping @Sendable () async -> Bool, log: RequestLog) async throws -> InsightsPrefetchService {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        let api = makeStubClient()
        let metricRepo = MetricInsightsRepository(api: api, swr: coordinator)
        let targetsRepo = InsightsTargetsRepository(api: api, swr: coordinator)
        let insightsRepo = InsightsRepository(api: api)
        return InsightsPrefetchService(
            metricInsightsRepo: metricRepo,
            targetsRepo: targetsRepo,
            insightsRepo: insightsRepo,
            shouldWarm: shouldWarm,
            resolveLocale: { "de" }
        )
    }

    @Test("shouldWarm == false → no fetch fires (standalone / backend-down)")
    func gatedWarmFiresNothing() async throws {
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(req.url!.path)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":{}}"#.utf8))
        }
        let service = try await makeService(shouldWarm: { false }, log: log)
        await service.warmAndAwait()
        #expect(log.total == 0, "a gated warm must never fire a doomed fetch")
    }

    @Test("shouldWarm == true → warms targets + comprehensive + briefing + status")
    func openWarmFansOut() async throws {
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(req.url!.path)
            let path = req.url!.path
            let body = if path.contains("targets") {
                #"{"data":{"targets":[],"pageSummary":{"targetsMetThisWeek":0,"totalTargets":0,"streakHighlight":null},"bpDiastolic":null,"profile":null}}"#
            } else if path.contains("-status") {
                #"{"data":{"hasProvider":true,"text":"X","cached":true,"updatedAt":null}}"#
            } else {
                // comprehensive + generate (briefing) — minimal valid envelope.
                #"{"data":{}}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let service = try await makeService(shouldWarm: { true }, log: log)
        await service.warmAndAwait()

        #expect(log.count(matching: "/api/insights/targets") == 1)
        #expect(log.count(matching: "/api/insights/comprehensive") >= 1)
        #expect(log.count(matching: "/api/insights/generate") >= 1)
        // The four deployed status endpoints (BP / weight / pulse / bmi) warm
        // — `.bmi` added in W22-audit so its assessment paints cache-first too.
        #expect(log.count(matching: "blood-pressure-status") == 1)
        #expect(log.count(matching: "weight-status") == 1)
        #expect(log.count(matching: "pulse-status") == 1)
        #expect(log.count(matching: "bmi-status") == 1)
    }

    @Test("Re-entry guard: a second warm while one is running is a no-op")
    func reentryGuardCollapses() async throws {
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(req.url!.path)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":{}}"#.utf8))
        }
        let service = try await makeService(shouldWarm: { true }, log: log)
        // Two concurrent awaited warms — the re-entry guard collapses the second.
        async let a: Void = service.warmAndAwait()
        async let b: Void = service.warmAndAwait()
        _ = await (a, b)
        // Both warms fan out the same key set; the SWR single-flight + re-entry
        // guard mean the comprehensive endpoint is hit at most twice (one per
        // distinct fan-out that actually ran), never 2× the full fan-out.
        #expect(log.count(matching: "/api/insights/comprehensive") <= 1)
    }
}
