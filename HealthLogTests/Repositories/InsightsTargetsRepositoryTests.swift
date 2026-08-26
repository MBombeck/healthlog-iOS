import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract + SWR ladder for `GET /api/insights/targets`
/// (server v1.4.36 W1).
///
/// Covers:
/// - happy-path full envelope decode with targets + pageSummary + bpDiastolic
/// - empty `targets[]` decodes cleanly
/// - SWR cache fresh → no second network call
/// - SWR stale-on-error returns last-known snapshot
@Suite("InsightsTargetsRepository — wire contract", .serialized)
struct InsightsTargetsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    @Test("fetch — decodes the full envelope (targets + pageSummary + bpDiastolic)")
    func fetchFullEnvelope() async throws {
        let repo = InsightsTargetsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "targets":[{
                "type":"WEIGHT","label":"Gewicht",
                "current":80.0,"average30":81.2,"trend":"down","unit":"kg",
                "range":{"min":70,"max":80},
                "classification":{"category":"target","color":"#00ff00"},
                "source":"WITHINGS",
                "daysInRange7d":5,"daysLogged7d":7,
                "daysInRange30d":18,"daysLogged30d":28,
                "lastMetGoalAt":"2026-05-15","streakDays":3,
                "insufficientData":false,
                "consistency7d":["in","in","near","in","out","in","in"]
              }],
              "pageSummary":{
                "targetsMetThisWeek":1,"totalTargets":4,
                "streakHighlight":{"metric":"WEIGHT","days":3}
              },
              "bpDiastolic":{"current":78,"average30":82,"range":{"min":60,"max":80}},
              "profile":{"heightCm":180,"age":42,"gender":"male","glucoseUnit":"mmol/L"}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let response = try await repo.fetch()
        #expect(response.targets.count == 1)
        let weight = response.targets[0]
        #expect(weight.type == "WEIGHT")
        #expect(weight.current == 80.0)
        #expect(weight.trend == .down)
        #expect(weight.consistency7d.count == 7)
        #expect(weight.consistency7d[0] == .inBand)
        #expect(weight.consistency7d[2] == .nearBand)
        #expect(weight.consistency7d[4] == .outBand)
        #expect(response.pageSummary.targetsMetThisWeek == 1)
        #expect(response.bpDiastolic?.current == 78)
    }

    @Test("fetch — empty targets[] decodes cleanly")
    func fetchEmptyTargets() async throws {
        let repo = InsightsTargetsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "targets":[],
              "pageSummary":{"targetsMetThisWeek":0,"totalTargets":0,"streakHighlight":null},
              "bpDiastolic":null,"profile":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let response = try await repo.fetch()
        #expect(response.targets.isEmpty)
        #expect(response.pageSummary.totalTargets == 0)
        #expect(response.bpDiastolic == nil)
    }

    @Test("fetch — cache fresh on second call within TTL")
    func cacheFresh() async throws {
        let repo = InsightsTargetsRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — only OUR route counts.
            if req.targets("/api/insights/targets") { calls += 1 }
            let body = Data(#"""
            {"data":{
              "targets":[],
              "pageSummary":{"targetsMetThisWeek":0,"totalTargets":0,"streakHighlight":null},
              "bpDiastolic":null,"profile":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.fetch()
        _ = try await repo.fetch()
        #expect(calls == 1)
    }

    @Test("fetch — stale snapshot returned on subsequent 500")
    func fetchStaleOnError() async throws {
        let clockBox = ClockBoxTargets(now: Date(timeIntervalSinceReferenceDate: 0))
        let repo = InsightsTargetsRepository(
            api: makeAPI(),
            cacheTTL: 60,
            clock: { clockBox.now }
        )
        nonisolated(unsafe) var phase = 0
        MockURLProtocol.handler = { req in
            // CU-07: only OUR route advances the phase machine.
            if req.targets("/api/insights/targets") { phase += 1 }
            if phase == 1 {
                let body = Data(#"""
                {"data":{
                  "targets":[{
                    "type":"WEIGHT","label":"Gewicht",
                    "current":80,"average30":81,"trend":"down","unit":"kg",
                    "range":{"min":70,"max":80},
                    "classification":null,"source":"WITHINGS",
                    "daysInRange7d":5,"daysLogged7d":7,
                    "daysInRange30d":18,"daysLogged30d":28,
                    "lastMetGoalAt":null,"streakDays":2,
                    "insufficientData":false,
                    "consistency7d":[null,null,null,null,null,null,null]
                  }],
                  "pageSummary":{"targetsMetThisWeek":1,"totalTargets":1,"streakHighlight":null},
                  "bpDiastolic":null,"profile":null
                },"error":null}
                """#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let first = try await repo.fetch()
        #expect(first.targets.count == 1)
        clockBox.now = clockBox.now.addingTimeInterval(120)
        let stale = try await repo.fetch()
        #expect(stale.targets.count == 1, "stale slot returned on 500")
    }

    @Test("invalidateCache — wipes the snapshot so next fetch hits the wire")
    func invalidateCacheWipesSnapshot() async throws {
        // V0.5.2 R2 / H1: logout must reach the per-repo actor cache so
        // the next user never sees the previous user's targets payload.
        let repo = InsightsTargetsRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — only OUR route counts.
            if req.targets("/api/insights/targets") { calls += 1 }
            let body = Data(#"""
            {"data":{
              "targets":[],
              "pageSummary":{"targetsMetThisWeek":0,"totalTargets":0,"streakHighlight":null},
              "bpDiastolic":null,"profile":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.fetch()
        _ = try await repo.fetch() // warm
        #expect(calls == 1, "warm read must not re-fire")
        await repo.invalidateCache()
        _ = try await repo.fetch()
        #expect(calls == 2, "post-invalidate fetch must round-trip again")
    }

    @MainActor
    @Test("InsightsTargetsStore — load mirrors targets and lookup by type works")
    func storeLoadAndLookup() async {
        let repo = InsightsTargetsRepository(api: makeAPI())
        let store = InsightsTargetsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "targets":[{
                "type":"WEIGHT","label":"Gewicht",
                "current":80,"average30":81,"trend":"down","unit":"kg",
                "range":{"min":70,"max":80},
                "classification":null,"source":"WITHINGS",
                "daysInRange7d":5,"daysLogged7d":7,
                "daysInRange30d":18,"daysLogged30d":28,
                "lastMetGoalAt":null,"streakDays":2,
                "insufficientData":false,
                "consistency7d":[null,null,null,null,null,null,null]
              }],
              "pageSummary":{"targetsMetThisWeek":1,"totalTargets":1,"streakHighlight":null},
              "bpDiastolic":null,"profile":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        #expect(store.targets.count == 1)
        #expect(store.target(forType: "WEIGHT")?.current == 80)
        #expect(store.target(forType: "UNKNOWN") == nil)
    }
}

/// Mutable clock-holder for deterministic TTL drift.
private final class ClockBoxTargets: @unchecked Sendable {
    var now: Date
    init(now: Date) {
        self.now = now
    }
}

// swiftlint:enable force_unwrapping
