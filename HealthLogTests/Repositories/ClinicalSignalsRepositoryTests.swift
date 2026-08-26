import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v1.25 (GH iOS #38) — locks the wire contracts for the three read-only
/// "clinical signals" awareness reads (server `release/v1.25.0`):
///   - `GET /api/insights/health-status`       (`InsightsHealthStatusDTO`)
///   - `GET /api/insights/breathing-screening` (`InsightsBreathingScreeningDTO`)
///   - `GET /api/insights/labs-changes`        (`InsightsLabsChangesDTO`)
///
/// Source of truth: `src/lib/openapi/routes/insights-signals.ts` +
/// `src/lib/insights/{health-status,breathing-screening,labs-changes}.ts`.
///
/// Covers, per the project rule (real `APIClient` + stubbed `URLProtocol`, no
/// mock server): the exact server shape decodes; `present`/has-content drives the
/// card self-suppression; the type tokens resolve to `MetricKind`; a `404`
/// (route absent) → `nil` (graceful self-suppress); the store hydrates all three.
@Suite("ClinicalSignals — v1.25 wire contracts + self-suppression", .serialized)
struct ClinicalSignalsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - health-status

    @Test("health-status — decodes deviations + shifts; tokens resolve to MetricKind")
    func decodesHealthStatus() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/insights/health-status") == true)
            let body = Data(#"""
            {"data":{
              "present":true,
              "deviations":[
                {"type":"RESTING_HEART_RATE","value":72,"center":58,"low":50,"high":66,"direction":"above"}
              ],
              "shifts":[
                {"metric":"WEIGHT","breakDate":"2026-06-10","beforeMean":80.1,"afterMean":82.4,"direction":"up"}
              ],
              "generatedAt":"2026-06-28T06:00:00.000Z"
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchHealthStatus())
        #expect(dto.present)
        #expect(dto.hasContent)
        #expect(dto.generatedAt != nil)

        let deviation = try #require(dto.deviations.first)
        #expect(deviation.type == "RESTING_HEART_RATE")
        #expect(deviation.value == 72)
        #expect(deviation.low == 50)
        #expect(deviation.high == 66)
        #expect(deviation.isAbove)
        // Token resolves to the iOS metric via ServerMeasurementType.metricKind.
        #expect(deviation.metricKind == .restingHeartRate)

        let shift = try #require(dto.shifts.first)
        #expect(shift.metric == "WEIGHT")
        #expect(shift.breakDate == "2026-06-10")
        #expect(shift.isUp)
        #expect(shift.metricKind == .weight)
    }

    @Test("health-status — present:false → no content (card self-suppresses)")
    func healthStatusAbsentSelfSuppresses() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"present":false,"deviations":[],"shifts":[],"generatedAt":"2026-06-28T06:00:00.000Z"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchHealthStatus())
        #expect(!dto.hasContent)
    }

    @Test("health-status — unknown type token decodes (metricKind nil), never crashes")
    func healthStatusTolerantUnknownToken() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"present":true,"deviations":[
              {"type":"FUTURE_VITAL_X","value":1,"center":0,"low":-1,"high":1,"direction":"above"}
            ],"shifts":[]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchHealthStatus())
        let deviation = try #require(dto.deviations.first)
        #expect(deviation.type == "FUTURE_VITAL_X")
        #expect(deviation.metricKind == nil)
    }

    // MARK: - breathing-screening

    @Test("breathing-screening — decodes nights/trend/events/classification")
    func decodesBreathing() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/insights/breathing-screening") == true)
            let body = Data(#"""
            {"data":{
              "present":true,"nights":21,"recentMeanIndex":3.4,"trend":"up",
              "eventCount":2,"classification":"elevated","generatedAt":"2026-06-28T06:00:00.000Z"
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchBreathingScreening())
        #expect(dto.hasContent)
        #expect(dto.nights == 21)
        #expect(dto.recentMeanIndex == 3.4)
        #expect(dto.trend == "up")
        #expect(dto.eventCount == 2)
        #expect(dto.isElevated)
    }

    @Test("breathing-screening — null trend/classification + no data → no content")
    func breathingNullsSelfSuppress() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"present":false,"nights":0,"recentMeanIndex":null,"trend":null,
              "eventCount":0,"classification":null,"generatedAt":"2026-06-28T06:00:00.000Z"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchBreathingScreening())
        #expect(!dto.hasContent)
        #expect(dto.trend == nil)
        #expect(dto.classification == nil)
        #expect(dto.recentMeanIndex == nil)
    }

    // MARK: - labs-changes

    @Test("labs-changes — decodes per-analyte delta + status")
    func decodesLabsChanges() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/insights/labs-changes") == true)
            let body = Data(#"""
            {"data":{
              "present":true,"latestDate":"2026-06-20","previousDate":"2026-01-05",
              "changes":[
                {"analyte":"HbA1c","unit":"%","latest":5.6,"previous":5.9,"delta":-0.3,"direction":"down","status":"in-range"},
                {"analyte":"LDL","unit":"mg/dL","latest":130,"previous":118,"delta":12,"direction":"up","status":"above"}
              ],
              "generatedAt":"2026-06-28T06:00:00.000Z"
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchLabsChanges())
        #expect(dto.hasContent)
        #expect(dto.latestDate == "2026-06-20")
        #expect(dto.previousDate == "2026-01-05")
        #expect(dto.changes.count == 2)

        let hba1c = try #require(dto.changes.first { $0.analyte == "HbA1c" })
        #expect(hba1c.delta == -0.3)
        #expect(hba1c.direction == "down")
        #expect(hba1c.status == "in-range")

        let ldl = try #require(dto.changes.first { $0.analyte == "LDL" })
        #expect(ldl.delta == 12)
        #expect(ldl.status == "above")
    }

    @Test("labs-changes — fewer than two panels (present:false) → no content")
    func labsChangesAbsentSelfSuppresses() async throws {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"present":false,"latestDate":null,"previousDate":null,"changes":[]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(await repo.fetchLabsChanges())
        #expect(!dto.hasContent)
    }

    // MARK: - graceful 404 + store

    @Test("404 (route absent on an older server) → nil for each read")
    func routeAbsentIsNil() async {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(await repo.fetchHealthStatus() == nil)
        #expect(await repo.fetchBreathingScreening() == nil)
        #expect(await repo.fetchLabsChanges() == nil)
    }

    @MainActor
    @Test("store — load hydrates all three reads")
    func storeLoadHydratesAll() async {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        let store = ClinicalSignalsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let json = if path.hasSuffix("/insights/health-status") {
                #"{"data":{"present":true,"deviations":[{"type":"PULSE","value":90,"center":70,"low":60,"high":80,"direction":"above"}],"shifts":[]},"error":null}"#
            } else if path.hasSuffix("/insights/breathing-screening") {
                #"{"data":{"present":true,"nights":14,"recentMeanIndex":2.1,"trend":"stable","eventCount":0,"classification":"not-elevated"},"error":null}"#
            } else {
                #"{"data":{"present":true,"latestDate":"2026-06-20","previousDate":"2026-01-05","changes":[{"analyte":"GGT","latest":40,"previous":52,"delta":-12}]},"error":null}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        #expect(!store.hasSettledOnce)
        await store.load()
        #expect(store.hasSettledOnce)
        #expect(store.healthStatus?.hasContent == true)
        #expect(store.breathing?.hasContent == true)
        #expect(store.labsChanges?.hasContent == true)
    }

    @MainActor
    @Test("store — all routes absent settle with no content; clearOnLogout wipes")
    func storeEmptyAndClear() async {
        let repo = ClinicalSignalsRepository(api: makeAPI())
        let store = ClinicalSignalsStore(repo: repo)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        await store.load()
        #expect(store.hasSettledOnce)
        #expect(store.healthStatus == nil)
        #expect(store.breathing == nil)
        #expect(store.labsChanges == nil)
        store.clearOnLogout()
        #expect(!store.hasSettledOnce)
    }
}

// swiftlint:enable force_unwrapping
