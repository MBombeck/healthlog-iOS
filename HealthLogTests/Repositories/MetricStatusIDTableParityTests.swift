import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0141 W-DATAPARITY (P2) — locks the twelve registry ids the stale
/// `metricStatusIDTable` was missing, so the "Einschätzung / KI-Befund" block
/// self-suppressed on those metric pages even though the operator has the data.
/// Every id is VERIFIED present in the server `METRIC_STATUS_IDS` registry
/// (`src/lib/insights/metric-status-registry.ts`).
@Suite("MetricInsights — P2 metricStatusIDTable parity", .serialized)
struct MetricStatusIDTableParityTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("each newly-added kind maps to its exact server registry id")
    func newIdsResolveToRegistryIds() {
        let table = MetricInsightsRepository.metricStatusIDTable
        #expect(table[.stairAscentSpeed] == "STAIR_ASCENT_SPEED")
        #expect(table[.stairDescentSpeed] == "STAIR_DESCENT_SPEED")
        #expect(table[.sixMinuteWalk] == "SIX_MINUTE_WALK_DISTANCE")
        #expect(table[.cardioRecovery] == "CARDIO_RECOVERY")
        #expect(table[.dayStrain] == "DAY_STRAIN")
        #expect(table[.energyExpenditureKJ] == "ENERGY_EXPENDITURE_KJ")
        #expect(table[.averageHeartRate] == "AVERAGE_HEART_RATE")
        #expect(table[.maxHeartRate] == "MAX_HEART_RATE")
        #expect(table[.painNRS] == "PAIN_NRS")
        #expect(table[.gripStrength] == "GRIP_STRENGTH")
        #expect(table[.waistCircumference] == "WAIST_CIRCUMFERENCE")
        #expect(table[.waistToHeight] == "WAIST_TO_HEIGHT")
    }

    @Test("a stubbed metric-status response for STAIR_ASCENT_SPEED renders the assessment")
    func stairAscentAssessmentRenders() async throws {
        let repo = MetricInsightsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            // The generic metric-status route carries the registry id in `metric`.
            #expect(req.url?.path.hasSuffix("/insights/metric-status") == true)
            let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains { $0.name == "metric" && $0.value == "STAIR_ASCENT_SPEED" })
            let body = Data(#"""
            {"data":{"hasProvider":true,"text":"Deine Treppen-Aufstiegsgeschwindigkeit ist stabil.","cached":false,"updatedAt":"2026-07-01T08:00:00.000Z"},"error":null}
            """#.utf8)
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }
        let dto = try #require(try await repo.fetchAssessment(metric: .stairAscentSpeed, locale: "de"))
        #expect(dto.hasProvider)
        #expect(dto.text == "Deine Treppen-Aufstiegsgeschwindigkeit ist stabil.")
    }
}

// swiftlint:enable force_unwrapping
