import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract for `GET /api/insights/correlations`
/// (server v1.10.0, `src/app/api/insights/correlations/route.ts`, envelope
/// `CorrelationDiscoveryResponseEnvelope`).
///
/// Covers:
/// - decode of a populated discovery response (`discovered` pairs + the
///   `pairsTested / fdrQ / minPairs` honest-footer fields)
/// - feature-off / route-absent (`404` / `422`) → `nil` → block hides
///   GRACEFULLY (operator-gated surface)
/// - HONEST-ONLY: an empty `discovered` array decodes + self-suppresses
///   (the store's `presentable` is empty, the block hides) — never fabricated
/// - the store's strongest-first ordering + non-causal direction/strength
///   derivation
@Suite("CorrelationsDiscovery — wire contract + operator-gated + honest-only", .serialized)
struct CorrelationsDiscoveryRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.12.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("fetch — decodes a populated discovery response (pairs + footer fields)")
    func fetchPopulated() async throws {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/insights/correlations") == true)
            let body = Data(#"""
            {"data":{
              "discovered":[
                {"behaviour":"TIME_IN_DAYLIGHT","outcome":"SLEEP_DURATION","n":34,
                 "r":0.41,"pValue":0.012,"qValue":0.06,
                 "interpretation":"On days with more time in daylight, sleep duration the next day tended to be longer.",
                 "lagDays":1},
                {"behaviour":"MOOD","outcome":"HEART_RATE_VARIABILITY","n":28,
                 "r":-0.33,"pValue":0.04,"qValue":0.09,
                 "interpretation":"Lower mood days tended to precede lower HRV the next day.",
                 "lagDays":1}
              ],
              "pairsTested":42,"fdrQ":0.1,"minPairs":20
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch())
        #expect(dto.pairsTested == 42)
        #expect(dto.fdrQ == 0.1)
        #expect(dto.minPairs == 20)
        #expect(dto.discovered.count == 2)
        let daylight = try #require(dto.discovered.first { $0.behaviour == "TIME_IN_DAYLIGHT" })
        #expect(daylight.outcome == "SLEEP_DURATION")
        #expect(daylight.n == 34)
        #expect(daylight.r == 0.41)
        #expect(daylight.pValue == 0.012)
        #expect(daylight.qValue == 0.06)
        #expect(daylight.lagDays == 1)
        #expect(daylight.direction == .positive)
        #expect(daylight.strength == .moderate)
        let mood = try #require(dto.discovered.first { $0.behaviour == "MOOD" })
        // Sign of r drives direction — descriptive, never causal.
        #expect(mood.direction == .negative)
        #expect(mood.strength == .moderate)
    }

    @Test("fetch — empty discovered array decodes (honest 'nothing defensible')")
    func fetchEmptyDiscovered() async throws {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"discovered":[],"pairsTested":42,"fdrQ":0.1,"minPairs":20},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch())
        #expect(dto.discovered.isEmpty)
        // pairsTested still present for the honest footer even with no pairs.
        #expect(dto.pairsTested == 42)
    }

    @Test("fetch — 404 (route absent) → nil → block hides gracefully")
    func fetch404IsNil() async throws {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch() == nil)
    }

    @Test("fetch — 422 (operator-gated surface off) → nil → block hides, no error")
    func fetch422IsNil() async throws {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch() == nil)
    }

    @Test("fetch — 403 + assistant.disabled.correlations → nil (P10 graceful hide)")
    func fetch403AssistantDisabledIsNil() async throws {
        // v0141 W-DATAPARITY (P10): `requireAssistantSurface("correlations")`
        // answers a disabled surface with `403` +
        // `errorCode: "assistant.disabled.correlations"`. `correlations` is not a
        // known iOS `FeatureFlag` surface, so `APIClient` surfaces it as
        // `HLError.server(403, "assistant.disabled.correlations")` (NOT the typed
        // `assistantDisabled`) — the repository now folds it into the hide arm.
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Correlations disabled by operator","errorCode":"assistant.disabled.correlations"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(try await repo.fetch() == nil)
    }

    @Test("fetch — a genuine 403 WITHOUT an assistant.disabled code still throws")
    func fetchGenuineForbiddenStillThrows() async {
        // Only `assistant.disabled.*` 403s hide; a real auth 403 must surface so
        // the caller does not mistake a permission failure for an empty block.
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"Forbidden"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        await #expect(throws: HLError.self) {
            _ = try await repo.fetch()
        }
    }

    @MainActor
    @Test("store — gated-off (nil) → presentable empty + block self-suppresses")
    func storeGatedOffSelfSuppresses() async {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let store = CorrelationsDiscoveryStore(repo: repo, patterns: PatternsRepository(api: makeAPI()))
        await store.load()
        #expect(store.response == nil)
        #expect(store.presentable.isEmpty)
        #expect(store.hasContent == false)
    }

    @MainActor
    @Test("store — orders strongest association first (|r| descending)")
    func storeOrdersStrongestFirst() async {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "discovered":[
                {"behaviour":"MOOD","outcome":"HEART_RATE_VARIABILITY","n":28,
                 "r":-0.22,"pValue":0.04,"qValue":0.09,"interpretation":"a","lagDays":1},
                {"behaviour":"TIME_IN_DAYLIGHT","outcome":"SLEEP_DURATION","n":34,
                 "r":0.55,"pValue":0.001,"qValue":0.03,"interpretation":"b","lagDays":1}
              ],
              "pairsTested":42,"fdrQ":0.1,"minPairs":20
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = CorrelationsDiscoveryStore(repo: repo, patterns: PatternsRepository(api: makeAPI()))
        await store.load()
        #expect(store.hasContent)
        // |0.55| > |-0.22| → daylight leads.
        #expect(store.presentable.first?.behaviour == "TIME_IN_DAYLIGHT")
        #expect(store.presentable.last?.behaviour == "MOOD")
    }

    @Test("block — headline is descriptive, never causal")
    func headlineDescriptiveNeverCausal() {
        let positive = DiscoveredCorrelation(
            behaviour: "TIME_IN_DAYLIGHT", outcome: "SLEEP_DURATION", n: 34,
            r: 0.41, pValue: 0.012, qValue: 0.06, interpretation: "", lagDays: 1
        )
        let headline = InsightsCorrelationsDiscoveryBlock.headline(for: positive)
        // No causal verbs — only "tends to go with" / "geht einher mit".
        #expect(!headline.lowercased().contains("verbessert"))
        #expect(!headline.lowercased().contains("improves"))
        #expect(!headline.lowercased().contains("causes"))
        // Locale-resolved (host may run de) — assert the verbatim EN-or-DE form.
        #expect([
            "More time in daylight tends to go with more sleep duration the next day",
            "Mehr Zeit im Tageslicht geht tendenziell mit mehr Schlafdauer am Folgetag einher"
        ].contains(headline))
    }

    @Test("block — stat line mirrors server n + r (no fabrication)")
    func statLineFromServer() {
        let pair = DiscoveredCorrelation(
            behaviour: "MOOD", outcome: "HEART_RATE_VARIABILITY", n: 28,
            r: -0.33, pValue: 0.04, qValue: 0.09, interpretation: "", lagDays: 1
        )
        // Pin a POSIX locale for a deterministic decimal separator (production
        // uses `.current`, so a de-DE device correctly renders "-0,33" — L10N-5).
        let line = InsightsCorrelationsDiscoveryBlock.statLine(for: pair, locale: Locale(identifier: "en_US_POSIX"))
        // n + r come straight from the server; r formatted to 2 dp.
        #expect(line.contains("28"))
        #expect(line.contains("-0.33"))
    }
}

// swiftlint:enable force_unwrapping
