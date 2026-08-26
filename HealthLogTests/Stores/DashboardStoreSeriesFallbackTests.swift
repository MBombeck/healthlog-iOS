import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// DASHBOARD-BUG-FIX-2 — Client-derived tile fallback via per-kind series
/// endpoint. Pins the contract:
///
/// 1. When `/api/measurements?limit=400` returns a page that contains NO
///    rows of a particular kind (e.g. BP / Pulse for HK-heavy users where
///    Steps dominates the page), the dashboard tile state for that kind
///    falls back to `/api/measurements/series?kind=…&days=30` — the same
///    endpoint the chart-detail screen consumes.
///
/// 2. If the series carries points, the per-kind state synthesizes to
///    `.ready` from the series tail — so the tile renders the same value
///    the chart-detail would show on tap.
///
/// 3. If the series is empty, the wide-page-derived `.empty` state stays
///    (no false positives).
///
/// 4. `.bodyTemperature` is server-side series-unsupported (HK write-only)
///    — fallback short-circuits without firing the series call.
@Suite("DashboardStore.refreshMetricStates — series-endpoint fallback", .serialized)
struct DashboardStoreSeriesFallbackTests {
    @Test("unknown weight, steps, and sleep trends derive from bounded visible values")
    func supportedDashboardTrendsDeriveFromVisibleValues() {
        #expect(DashboardStore.dashboardTrend(server: .unknown, kind: .weight, visibleValues: [72.0, 72.4]) == .up)
        #expect(DashboardStore.dashboardTrend(server: .unknown, kind: .steps, visibleValues: [8000, 7500]) == .down)
        #expect(DashboardStore.dashboardTrend(server: .unknown, kind: .sleep, visibleValues: [7.2, 7.2]) == .flat)
    }

    @Test("derived dashboard trend preserves server signal and stays unknown without honest support")
    func dashboardTrendHonestyGuards() {
        #expect(DashboardStore.dashboardTrend(server: .down, kind: .weight, visibleValues: [72.0, 73.0]) == .down)
        #expect(DashboardStore.dashboardTrend(server: .unknown, kind: .weight, visibleValues: [72.0]) == .unknown)
        #expect(DashboardStore.dashboardTrend(server: .unknown, kind: .pulse, visibleValues: [60, 70]) == .unknown)
        #expect(DashboardStore.dashboardTrend(server: .unknown, kind: .sleep, visibleValues: [7.0, .nan]) == .unknown)
    }

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

    /// Empty `/api/measurements?limit=400` response — no rows of any kind.
    /// Forces every kind through the series-fallback path.
    private func emptyMeasurementsPayload() -> Data {
        Data("{\"data\":{\"measurements\":[]}}".utf8)
    }

    /// `/api/measurements/series` reply for `pulse` with two recent points.
    private func pulseSeriesPayload(now: Date) -> Data {
        let p1At = iso(now.addingTimeInterval(-3600))
        let p2At = iso(now.addingTimeInterval(-1800))
        let body = #"{"data":{"kind":"pulse","points":["#
            + #"{"id":"sp1","at":""# + p1At + #"","value":64.0,"secondary":null},"#
            + #"{"id":"sp2","at":""# + p2At + #"","value":68.0,"secondary":null}"#
            + #"],"stats":{"mean":66,"min":64,"max":68,"stdDev":2,"count":2}}}"#
        return Data(body.utf8)
    }

    /// `/api/measurements/series` reply for `bloodPressure` carrying both
    /// systolic + diastolic via the `secondary` field.
    private func bpSeriesPayload(now: Date) -> Data {
        let atIso = iso(now.addingTimeInterval(-7200))
        let body = #"{"data":{"kind":"bloodPressure","points":["#
            + #"{"id":"sb1","at":""# + atIso + #"","value":124.0,"secondary":82.0}"#
            + #"],"stats":{"mean":124,"min":124,"max":124,"stdDev":0,"count":1}}}"#
        return Data(body.utf8)
    }

    /// Empty series response — server returns the shape but with zero points.
    private func emptySeriesPayload(kindKey: String) -> Data {
        Data(("{\"data\":{\"kind\":\"" + kindKey + "\",\"points\":[],\"stats\":{\"mean\":0,\"min\":0,\"max\":0,\"stdDev\":0,\"count\":0}}}")
            .utf8)
    }

    @Test("BP empty in wide page → series fallback synthesizes .ready")
    @MainActor
    func bpEmptyTriggersSeriesFallback() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bpPayload = bpSeriesPayload(now: now)
        let emptyMeasurements = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                // Disambiguate per kind via the query string.
                let kindParam = request.url?.query?.contains("kind=bloodPressure") ?? false
                if kindParam {
                    return (response, bpPayload)
                }
                return (
                    response,
                    emptyMeasurements
                ) // any other kind → empty list (won't match series shape, but the request shouldn't fire)
            }
            return (response, emptyMeasurements)
        }
        await store.refreshMetricStates(
            kinds: [.bloodPressure],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        let bpState = store.metricStates[.bloodPressure]
        guard case let .ready(latest, _) = bpState else {
            Issue.record("Expected .ready for bloodPressure after series fallback, got \(String(describing: bpState))")
            return
        }
        if case let .bloodPressure(s, d) = latest.value {
            #expect(s == 124.0)
            #expect(d == 82.0)
        } else {
            Issue.record("Series-synthesized BP measurement missing paired diastolic, got \(latest.value)")
        }
    }

    @Test("Pulse empty in wide page → series fallback synthesizes .ready with latest scalar")
    @MainActor
    func pulseEmptyTriggersSeriesFallback() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pulsePayload = pulseSeriesPayload(now: now)
        let emptyMeasurements = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                if request.url?.query?.contains("kind=pulse") == true {
                    return (response, pulsePayload)
                }
            }
            return (response, emptyMeasurements)
        }
        await store.refreshMetricStates(
            kinds: [.pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        guard case let .ready(latest, samples) = store.metricStates[.pulse] else {
            Issue.record("Expected .ready for pulse after series fallback, got \(String(describing: store.metricStates[.pulse]))")
            return
        }
        #expect(latest.primaryValue == 68.0, "Latest series point (most recent) must be the synthesized .ready latest")
        #expect(samples.count == 2)
    }

    @Test("series fallback empty leaves the wide-page-derived .empty state alone")
    @MainActor
    func emptySeriesPreservesEmptyState() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let emptyMeasurements = emptyMeasurementsPayload()
        let emptyGlucoseSeries = emptySeriesPayload(kindKey: "glucose")
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                return (response, emptyGlucoseSeries)
            }
            return (response, emptyMeasurements)
        }
        await store.refreshMetricStates(
            kinds: [.glucose],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        // No data anywhere → wide-page yielded .empty(.noData), series
        // returned empty so fallback did not synthesize anything. State
        // remains .empty(.noData) — the canonical "first-time user" copy.
        #expect(store.metricStates[.glucose] == .empty(reason: .noData))
    }

    @Test("bodyTemperature is series-unsupported → no series request fires")
    @MainActor
    func bodyTemperatureSkipsSeriesFallback() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        nonisolated(unsafe) var seriesCallCount = 0
        let emptyMeasurements = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                seriesCallCount += 1
                return (response, emptyMeasurements) // wrong shape, but shouldn't be reached
            }
            return (response, emptyMeasurements)
        }
        await store.refreshMetricStates(
            kinds: [.bodyTemperature],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        #expect(seriesCallCount == 0, "bodyTemperature must NOT trigger a series request (server returns 422 for it)")
    }

    @Test("ready states from wide page are never overwritten by fallback")
    @MainActor
    func readyStatesArePreserved() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Wide page has weight in range → .ready. Series request for weight
        // would synthesize a DIFFERENT latest value (74.0) — we want to
        // verify the wide-page-derived state wins.
        let recentAtIso = iso(now.addingTimeInterval(-86400))
        let widePagePayload =
            Data(("{\"data\":{\"measurements\":[{\"id\":\"w1\",\"type\":\"WEIGHT\",\"value\":72.0,\"measuredAt\":\"" + recentAtIso +
                    "\"}]}}").utf8)
        nonisolated(unsafe) var seriesCallCount = 0
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                seriesCallCount += 1
                let bogus = #"{"data":{"kind":"weight","points":[{"id":"sb1","at":""# + recentAtIso + #"","value":74.0,"secondary":null}],"stats":{"mean":74,"min":74,"max":74,"stdDev":0,"count":1}}}"#
                return (response, Data(bogus.utf8))
            }
            return (response, widePagePayload)
        }
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        guard case let .ready(latest, _) = store.metricStates[.weight] else {
            Issue.record("Expected .ready for weight from wide page, got \(String(describing: store.metricStates[.weight]))")
            return
        }
        #expect(latest.primaryValue == 72.0, "Wide-page-derived .ready must NOT be overwritten by series fallback")
        #expect(seriesCallCount == 0, "Series fallback must NOT fire for kinds that resolved to .ready from the wide page")
    }
}

// swiftlint:enable force_unwrapping
