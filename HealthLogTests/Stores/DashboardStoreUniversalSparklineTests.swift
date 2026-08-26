import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **V053-D2 regression guard.** Universal sparkline hydration must cover
/// every kind that has data — not just the BP / Pulse pair fixed in
/// v0.5.2-A1. Operator-reported v0.5.2 bug: "in den Karten Compliance und
/// Schritte habe ich keinen Graphen drin". The hydration loop in
/// `refreshMetricStates` post-commit fans across all `.ready` kinds
/// regardless of category (cumulative-stats, per-sample, BP composite).
@Suite("DashboardStore — V053-D2 universal sparkline hydration", .serialized)
@MainActor
struct DashboardStoreUniversalSparklineTests {
    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.3",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func summary(with metrics: [DashboardMetric]) -> DashboardSummary {
        DashboardSummary(
            greeting: Greeting(salutation: "Hi", date: Date(timeIntervalSince1970: 1_700_000_000)),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: metrics,
            lastUpdated: nil
        )
    }

    private func placeholderMetric(_ kind: MetricKind) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.descriptor.title.key,
            latestValue: nil,
            secondaryValue: nil,
            unit: String(localized: kind.descriptor.unitLabel),
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
    }

    @Test("Weight tile sparkline populated when wide page carries weight rows")
    func weightSparklineHydrates() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        store.seedSummaryForTesting(summary(with: [placeholderMetric(.weight)]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = "{\"id\":\"w1\",\"type\":\"WEIGHT\",\"value\":74.0,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400 * 2)))\"}"
        let r2 = "{\"id\":\"w2\",\"type\":\"WEIGHT\",\"value\":73.8,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400)))\"}"
        let r3 = "{\"id\":\"w3\",\"type\":\"WEIGHT\",\"value\":73.6,\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        let payload = "{\"data\":{\"measurements\":[\(r1),\(r2),\(r3)]}}"
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }

        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        guard case .ready = store.metricStates[.weight] else {
            Issue.record("Expected .ready for weight, got \(String(describing: store.metricStates[.weight]))")
            return
        }
        let weight = store.summary?.metrics.first { $0.kind == .weight }
        #expect((weight?.sparkline.count ?? 0) >= 3, "Weight sparkline should carry one point per wide-page row")
    }

    @Test("Glucose tile sparkline populated when wide page carries glucose rows")
    func glucoseSparklineHydrates() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        store.seedSummaryForTesting(summary(with: [placeholderMetric(.glucose)]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = "{\"id\":\"g1\",\"type\":\"BLOOD_GLUCOSE\",\"value\":98,\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        let r2 = "{\"id\":\"g2\",\"type\":\"BLOOD_GLUCOSE\",\"value\":102,\"measuredAt\":\"\(iso(now.addingTimeInterval(-1800)))\"}"
        let payload = "{\"data\":{\"measurements\":[\(r1),\(r2)]}}"
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }

        await store.refreshMetricStates(
            kinds: [.glucose],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        let glucose = store.summary?.metrics.first { $0.kind == .glucose }
        #expect((glucose?.sparkline.count ?? 0) == 2)
    }

    @Test("BodyFat tile sparkline populated (low-frequency manual kind)")
    func bodyFatSparklineHydrates() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        store.seedSummaryForTesting(summary(with: [placeholderMetric(.bodyFat)]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = "{\"id\":\"bf1\",\"type\":\"BODY_FAT\",\"value\":22.1,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400 * 5)))\"}"
        let r2 = "{\"id\":\"bf2\",\"type\":\"BODY_FAT\",\"value\":21.8,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400)))\"}"
        let payload = "{\"data\":{\"measurements\":[\(r1),\(r2)]}}"
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(payload.utf8))
        }

        await store.refreshMetricStates(
            kinds: [.bodyFat],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        let bodyFat = store.summary?.metrics.first { $0.kind == .bodyFat }
        #expect(
            (bodyFat?.sparkline.count ?? 0) >= 1,
            "Even low-frequency manual kinds should get a sparkline when the wide page carries rows"
        )
    }
}

// swiftlint:enable force_unwrapping
