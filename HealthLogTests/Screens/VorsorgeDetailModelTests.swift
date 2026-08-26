import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **W-VORSORGE-DETAIL (b244) — the detail model's per-arm load.**
///
/// Real `APIClient` + `MockURLProtocol` (PROJECT_GUIDE.md anti-pattern: no mock server)
/// so a schema drift would actually break the test. `.serialized` because the
/// assertions depend on the process-global `MockURLProtocol.handler`
/// (audit-v0162 H2). The metric arm reads through the real `MeasurementsRepository`;
/// the screening arm through a real `MentalHealthStore` + `MentalHealthRepository`.
@Suite("Vorsorge detail model", .serialized)
@MainActor
struct VorsorgeDetailModelTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.0.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeModel(row: MeasurementReminderRow, api: APIClient) throws -> VorsorgeDetailModel {
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let mhStore = try MentalHealthStore(
            repository: MentalHealthRepository(api: api, outbox: OutboxQueue(inMemory: true))
        )
        return VorsorgeDetailModel(row: row, measurementsRepo: repo, mentalHealthStore: mhStore)
    }

    private func row(type: String?) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: "r1",
            label: "Reminder",
            measurementType: type,
            intervalDays: 30,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: nil,
            nextDueAt: nil,
            lastSatisfiedAt: nil,
            enabled: true
        )
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - Metric arm

    @Test("metric arm loads the linked metric's readings into chart points")
    func metricArmLoadsPoints() async throws {
        let api = makeAPI()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = "{\"data\":{\"measurements\":[" +
            "{\"id\":\"w2\",\"type\":\"WEIGHT\",\"value\":81.0,\"measuredAt\":\"\(iso(now))\"}," +
            "{\"id\":\"w1\",\"type\":\"WEIGHT\",\"value\":80.0,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400)))\"}]}}"
        let payload = Data(body.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let model = try makeModel(row: row(type: "WEIGHT"), api: api)
        #expect(model.arm == .metric(.weight))
        await model.load()

        #expect(model.points.count == 2)
        // Oldest → newest.
        #expect(model.points.map(\.value) == [80.0, 81.0])
        #expect(model.yDomain == nil) // metric: auto axis
        #expect(!model.isLoading)
    }

    @Test("metric arm swallows a 500 — no chart, no throw")
    func metricArmServerError() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let model = try makeModel(row: row(type: "WEIGHT"), api: api)
        await model.load()
        #expect(model.points.isEmpty)
        #expect(!model.isLoading)
    }

    // MARK: - Screening arm

    @Test("screening arm loads the severity-band history + a fixed 0…maxScore domain")
    func screeningArmLoadsPointsAndDomain() async throws {
        let api = makeAPI()
        let body = #"""
        {"data":{"assessments":[
          {"id":"a2","instrument":"PHQ9","locale":"de","version":"standard","totalScore":12,
           "severityBand":"moderate","item9Flagged":false,"crisisShownAt":null,
           "takenAt":"2026-06-28T08:00:00.000Z","createdAt":"2026-06-28T08:00:00.000Z"},
          {"id":"a1","instrument":"PHQ9","locale":"de","version":"standard","totalScore":6,
           "severityBand":"mild","item9Flagged":false,"crisisShownAt":null,
           "takenAt":"2026-06-14T08:00:00.000Z","createdAt":"2026-06-14T08:00:00.000Z"}
        ]}}
        """#
        let payload = Data(body.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let model = try makeModel(row: row(type: "PHQ9_SCORE"), api: api)
        #expect(model.arm == .screening(.phq9))
        await model.load()

        #expect(model.points.count == 2)
        #expect(model.points.map(\.value) == [6.0, 12.0]) // oldest → newest
        #expect(model.yDomain == 0 ... 27) // PHQ-9 maxScore
        #expect(model.screeningRows.count == 2)
        #expect(!model.isLoading)
    }

    // MARK: - Free-text arm

    @Test("free-text arm resolves to no chart")
    func freeTextArmHasNoChart() async throws {
        let api = makeAPI()
        let model = try makeModel(row: row(type: nil), api: api)
        #expect(model.arm == .freeText)
        await model.load()
        #expect(model.points.isEmpty)
        #expect(model.yDomain == nil)
    }

    @Test("free-text arm makes NO network call (no fabricated series)")
    func freeTextArmMakesNoNetworkCall() async throws {
        let api = makeAPI()
        let hits = HitBox()
        MockURLProtocol.handler = { req in
            hits.record()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let model = try makeModel(row: row(type: nil), api: api)
        await model.load()
        #expect(model.points.isEmpty)
        #expect(hits.hitCount == 0, "the free-text arm must not hit the network — there is no metric to chart")
    }

    /// Thread-safe hit counter for the no-network assertion (the handler runs on
    /// a URLSession queue).
    private final class HitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var hitCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
