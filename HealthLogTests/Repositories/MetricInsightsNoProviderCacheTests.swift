import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.10 W-INSIGHTSDATA — pins that the server's NO-KEY FALLBACK body
/// (`hasProvider:false` + a non-empty localized hint) can never masquerade as
/// the day's ready assessment in the Berlin-day SWR cache.
///
/// Regression context: server v1.12.1 consent enforcement made the per-metric
/// status family fail closed to exactly this body for accounts with no
/// consent receipt on file. The hint's non-empty `text` satisfied
/// `hasReadyText`, was written through the daily key, and then SERVED from
/// cache for the rest of the Berlin day — so the metric sub-page kept showing
/// the stale hint even after the server-side consent state recovered.
@Suite("MetricInsightsRepository — no-provider bodies bypass the daily cache", .serialized)
struct MetricInsightsNoProviderCacheTests {
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

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() {
            lock.withLock { value += 1 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

    private func makeStubClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func noProviderBody() -> Data {
        Data(#"{"data":{"hasProvider":false,"text":"Kein KI-Schlüssel hinterlegt.","cached":true,"updatedAt":null}}"#.utf8)
    }

    private func readyBody(text: String) -> Data {
        Data(#"{"data":{"hasProvider":true,"text":"\#(text)","cached":false,"updatedAt":"2026-06-11T08:00:00Z"}}"#.utf8)
    }

    @Test("a no-provider hint is not cached as the day's prose — the next read refetches")
    func noProviderBodyIsNotCached() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        let api = makeStubClient()
        let repo = MetricInsightsRepository(api: api, swr: coordinator)

        let counter = RequestCounter()
        MockURLProtocol.handler = { req in
            counter.bump()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                noProviderBody()
            )
        }

        let first = try await repo.fetchAssessment(metric: .bloodPressure, locale: "de")
        #expect(first?.hasProvider == false)

        // The hint must NOT have been written through the daily key: a second
        // read goes back to the network (2 requests) instead of serving the
        // poisoned row from cache (which would leave it at 1).
        _ = try await repo.fetchAssessment(metric: .bloodPressure, locale: "de")
        #expect(counter.count == 2)
    }

    @Test("a pre-poisoned cached hint row is skipped — the network's recovered prose wins")
    func poisonedCacheRowSelfHeals() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        let api = makeStubClient()
        let repo = MetricInsightsRepository(api: api, swr: coordinator)

        // Seed TODAY's key with the no-key hint an older build wrote through.
        let poisoned = MetricStatusDTO(hasProvider: false, text: "Kein KI-Schlüssel hinterlegt.", cached: true, updatedAt: nil)
        try await cache.write(
            .insightStatus(kind: .bloodPressure, locale: "de", day: BerlinDayKey.string()),
            payload: JSONEncoder.hlDefault.encode(poisoned)
        )

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                readyBody(text: "Dein Blutdruck liegt stabil im Zielbereich.")
            )
        }

        let result = try await repo.fetchAssessment(metric: .bloodPressure, locale: "de")
        #expect(result?.hasProvider == true)
        #expect(result?.text == "Dein Blutdruck liegt stabil im Zielbereich.")
    }
}

// swiftlint:enable force_unwrapping
