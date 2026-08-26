import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// DASHBOARD-BUG-FIX-2 — pins the contract that:
///
/// 1. `MeasurementsStore.load()` now defaults to limit=400, NOT limit=50.
///    The 50-row default starved every downstream consumer that filters
///    by kind (briefing-input digest, TrendObservationCard series,
///    LocalDoctorReport rows) — for HK-heavy users 50 rows is sub-day
///    coverage.
///
/// 2. The wider request still flows through `/api/measurements?limit=…`
///    with the new limit, observable in the network handler.
///
/// 3. Briefing-input consumers (anything reading `measurementsStore.recent`)
///    get the wider window post-load.
@Suite("MeasurementsStore.load — briefing-input default limit", .serialized)
struct MeasurementsStoreBriefingInputTests {
    @MainActor
    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
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

    /// Build a `/api/measurements` reply with N rows of a given kind, all
    /// timestamped within the last 24h so they survive any future
    /// in-range filter at the consumer site.
    private func payload(rowCount: Int, now: Date) -> Data {
        var rows: [String] = []
        for i in 0 ..< rowCount {
            let at = iso(now.addingTimeInterval(-Double(i) * 60))
            rows.append("{\"id\":\"m\(i)\",\"type\":\"WEIGHT\",\"value\":\(72 + Double(i) * 0.01),\"measuredAt\":\"\(at)\"}")
        }
        return Data(("{\"data\":{\"measurements\":[" + rows.joined(separator: ",") + "]}}").utf8)
    }

    @Test("load() default limit is 400 (the wider briefing-input window)")
    @MainActor
    func defaultLimitIs400() async throws {
        let api = makeAPIClient()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        nonisolated(unsafe) var observedLimit: String?
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            // Capture the `limit=` query parameter from the recent-page request.
            // W1 Fix 2 fires a parallel series-hydration fetch
            // (`/api/measurements/series?kind=&days=`) that carries no `limit`,
            // so only record requests that actually have one — otherwise the
            // series request clobbers the observation back to nil.
            if let comps = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
               let limitValue = comps.queryItems?.first(where: { $0.name == "limit" })?.value
            {
                observedLimit = limitValue
            }
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        _ = now
        await store.load()
        #expect(observedLimit == "400", "MeasurementsStore.load() must request limit=400 by default — observed \(observedLimit ?? "nil")")
    }

    @Test("load(limit:) honours an explicit smaller limit")
    @MainActor
    func explicitLimitHonored() async throws {
        let api = makeAPIClient()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        nonisolated(unsafe) var observedLimit: String?
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            // Only record the recent-page request (the series-hydration fetch
            // carries no `limit`; see defaultLimitIs400 for the rationale).
            if let comps = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
               let limitValue = comps.queryItems?.first(where: { $0.name == "limit" })?.value
            {
                observedLimit = limitValue
            }
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        await store.load(limit: 50)
        #expect(observedLimit == "50", "Explicit limit must override the 400 default — observed \(observedLimit ?? "nil")")
    }

    @Test("load() populates store.recent with the page rows in payload order")
    @MainActor
    func loadPopulatesRecent() async throws {
        let api = makeAPIClient()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = payload(rowCount: 25, now: now)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        await store.load()
        #expect(store.recent.count == 25, "Briefing-input window should reflect the 25-row response — got \(store.recent.count)")
        #expect(store.recent.first?.kind == .weight)
    }
}

// swiftlint:enable force_unwrapping
