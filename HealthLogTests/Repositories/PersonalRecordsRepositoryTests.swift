import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract + SWR ladder for `GET /api/personal-records`
/// (server v1.4.25 W8d, schema-only release).
///
/// Covers:
/// - empty array decodes (production state until detection worker ships)
/// - happy-path multi-row decode
/// - SWR cache fresh → no second network call
/// - metricType filter as query param
@Suite("PersonalRecordsRepository — wire contract", .serialized)
struct PersonalRecordsRepositoryTests {
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

    @Test("list — empty array decodes (current prod state)")
    func emptyListDecodes() async throws {
        let repo = PersonalRecordsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let records = try await repo.list()
        #expect(records.isEmpty)
    }

    @Test("list — multi-row decode with MAX + MIN directions")
    func multiRowDecode() async throws {
        let repo = PersonalRecordsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":[
              {
                "id":"pr1","userId":"u1","metricType":"VO2_MAX","metricSlot":null,
                "direction":"MAX","value":42.5,"unit":"ml/kg/min",
                "achievedAt":"2026-05-01T10:00:00Z","sourceMeasurementId":"m1",
                "source":"APPLE_HEALTH","externalId":null,
                "createdAt":"2026-05-01T10:01:00Z"
              },
              {
                "id":"pr2","userId":"u1","metricType":"RESTING_HEART_RATE","metricSlot":null,
                "direction":"MIN","value":48.0,"unit":"bpm",
                "achievedAt":"2026-04-20T07:30:00Z","sourceMeasurementId":null,
                "source":"WITHINGS","externalId":"with:xyz",
                "createdAt":"2026-04-20T07:31:00Z"
              }
            ],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let records = try await repo.list()
        #expect(records.count == 2)
        #expect(records[0].metricType == "VO2_MAX")
        #expect(records[0].direction == .max)
        #expect(records[0].value == 42.5)
        #expect(records[1].direction == .min)
        #expect(records[1].source == "WITHINGS")
    }

    @Test("list — second call within TTL hits cache")
    func listCacheHit() async throws {
        let repo = PersonalRecordsRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/personal-records") { calls += 1 }
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.list()
        _ = try await repo.list()
        #expect(calls == 1)
    }

    @Test("list — metricType filter scopes the cache key separately")
    func listFilterSeparatesCache() async throws {
        let repo = PersonalRecordsRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/personal-records") { calls += 1 }
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.list() // all
        _ = try await repo.list(metricType: "VO2_MAX") // filtered — fresh slot
        _ = try await repo.list(metricType: "VO2_MAX") // warm
        #expect(calls == 2, "different filters get separate cache slots")
    }

    @Test("invalidateCache — wipes the per-filter slots so next reads hit the wire")
    func invalidateCacheWipesSlots() async throws {
        // V0.5.2 R2 / H1: logout must reach the per-repo actor cache so
        // the next user never sees the previous user's PRs.
        let repo = PersonalRecordsRepository(api: makeAPI())
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/personal-records") { calls += 1 }
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.list()
        _ = try await repo.list(metricType: "VO2_MAX") // second slot
        #expect(calls == 2)
        _ = try await repo.list() // warm
        #expect(calls == 2, "warm read must not re-fire")
        await repo.invalidateCache()
        _ = try await repo.list()
        _ = try await repo.list(metricType: "VO2_MAX")
        #expect(calls == 4, "both slots must drop on invalidate")
    }

    @MainActor
    @Test("PersonalRecordsStore — load mirrors records + hasRecords flag")
    func storeLoadMirrors() async {
        let repo = PersonalRecordsRepository(api: makeAPI())
        let store = PersonalRecordsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":[{
              "id":"pr1","userId":"u1","metricType":"VO2_MAX","metricSlot":null,
              "direction":"MAX","value":42.5,"unit":"ml/kg/min",
              "achievedAt":"2026-05-01T10:00:00Z","sourceMeasurementId":null,
              "source":"APPLE_HEALTH","externalId":null,
              "createdAt":"2026-05-01T10:01:00Z"
            }],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        #expect(store.records.count == 1)
        #expect(store.hasRecords)
        #expect(store.error == nil)
    }
}

// swiftlint:enable force_unwrapping
