import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.4-BF7 — `PersonalRecordsStore` merge contract tests.
///
/// Pins the "server-records win their metric-type bucket; derived rows
/// fill the gap" semantics. The screen relies on this so the moment the
/// detection worker ships (v1.4.26 / v1.5) the authoritative records
/// take over without an iOS release.
@Suite("PersonalRecordsStore — server + derived merge", .serialized)
@MainActor
struct PersonalRecordsStoreDerivedMergeTests {
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

    @Test("Empty server response surfaces all derived records")
    func emptyServerSurfacesDerived() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let derived = StubDerivedSource(records: [
            makeRecord(id: "client.steps.best", metricType: "ACTIVITY_STEPS")
        ])
        let store = PersonalRecordsStore(repo: repo, derivedSource: derived)
        await store.load()
        #expect(store.records.count == 1)
        #expect(store.records.first?.id == "client.steps.best")
    }

    @Test("Server records win their metric-type bucket — derived suppressed for same type")
    func serverWinsBucket() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":[{
              "id":"server.steps.1","userId":"u1","metricType":"ACTIVITY_STEPS","metricSlot":null,
              "direction":"MAX","value":21000,"unit":"steps",
              "achievedAt":"2026-05-01T10:00:00Z","sourceMeasurementId":null,
              "source":"APPLE_HEALTH","externalId":null,
              "createdAt":"2026-05-01T10:01:00Z"
            }],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let derived = StubDerivedSource(records: [
            makeRecord(id: "client.steps.best", metricType: "ACTIVITY_STEPS")
        ])
        let store = PersonalRecordsStore(repo: repo, derivedSource: derived)
        await store.load()
        // Derived source got the "excluding ACTIVITY_STEPS" hint and
        // filters its own list against it.
        #expect(derived.lastExcluded == ["ACTIVITY_STEPS"])
        #expect(store.records.map(\.id) == ["server.steps.1"])
    }

    @Test("Server failure still surfaces derived records, clearing the error")
    func serverFailureKeepsDerived() async {
        MockURLProtocol.handler = { req in
            // Surface a 500 — repo will throw a `.server` HLError.
            let body = Data(#"{"data":null,"error":"boom"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let derived = StubDerivedSource(records: [
            makeRecord(id: "client.steps.best", metricType: "ACTIVITY_STEPS")
        ])
        let store = PersonalRecordsStore(repo: repo, derivedSource: derived)
        await store.load()
        #expect(store.records.map(\.id) == ["client.steps.best"])
        #expect(store.error == nil)
    }

    @Test("No derived source — store behaves exactly like v0.5.3")
    func noDerivedSourceBackcompat() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":[],"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = PersonalRecordsRepository(api: makeAPI())
        let store = PersonalRecordsStore(repo: repo)
        await store.load()
        #expect(store.records.isEmpty)
        #expect(store.error == nil)
    }

    // MARK: - Fixtures

    private func makeRecord(id: String, metricType: String) -> PersonalRecordDTO {
        PersonalRecordDTO(
            id: id,
            userId: "u1",
            metricType: metricType,
            metricSlot: nil,
            direction: .max,
            value: 18500,
            unit: "steps",
            achievedAt: Date(timeIntervalSince1970: 1_716_000_000),
            sourceMeasurementId: nil,
            source: "TEST",
            externalId: nil,
            createdAt: Date(timeIntervalSince1970: 1_716_000_000)
        )
    }

    /// Records the exclusion-set passed by the store so tests can pin
    /// the contract.
    private final class StubDerivedSource: PersonalRecordsDerivedSource, @unchecked Sendable {
        let records: [PersonalRecordDTO]
        private(set) var lastExcluded: Set<String> = []
        private(set) var lastFilter: String?

        init(records: [PersonalRecordDTO]) {
            self.records = records
        }

        func derivedRecords(
            metricTypeFilter: String?,
            excluding serverMetricTypes: Set<String>
        ) async -> [PersonalRecordDTO] {
            lastFilter = metricTypeFilter
            lastExcluded = serverMetricTypes
            return records.filter { !serverMetricTypes.contains($0.metricType) }
        }
    }
}

// swiftlint:enable force_unwrapping
