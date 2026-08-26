import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **V052-A1 N2 regression guard.** `ChartDetailStore.dataState` must
/// transition out of `.unknown`/`.loading` when both the `/api/measurements/
/// series` and `/api/measurements?kind=…` paths agree there's no data —
/// otherwise the HeroStrip + ChartCard render endless `ProgressView`s while
/// the FindingsList beneath them already shows "Noch keine Befunde". The
/// store collapses to `.empty(.noData)` so the screen paints its empty-state
/// view instead of spinners-forever.
@Suite("ChartDetailStore — empty-state collapse on fan-out exhaustion", .serialized)
@MainActor
struct ChartDetailStoreEmptyStateTests {
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

    private func makeStore(kind: MetricKind, api: APIClient, heightCm: Double? = nil) throws -> ChartDetailStore {
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let insightsRepo = MetricInsightsRepository(api: api)
        let heightProvider: (@MainActor () -> Double?)? = heightCm.map { cm in
            { @MainActor in cm }
        }
        return ChartDetailStore(
            kind: kind,
            measurementsRepo: measurementsRepo,
            insightsRepo: insightsRepo,
            resolveLocale: { "de" },
            heightCmProvider: heightProvider
        )
    }

    private func emptySeriesPayload(kindKey: String) -> Data {
        Data(("{\"data\":{\"kind\":\"" + kindKey + "\",\"points\":[],\"stats\":{\"mean\":0,\"min\":0,\"max\":0,\"stdDev\":0,\"count\":0}}}")
            .utf8)
    }

    private func emptyMeasurementsPayload() -> Data {
        Data("{\"data\":{\"measurements\":[]}}".utf8)
    }

    @Test("Empty series + empty recent-page → dataState collapses to .empty(.noData) (not stuck .loading)")
    func emptyFanOutCollapsesToEmpty() async throws {
        let api = makeAPIClient()
        let store = try makeStore(kind: .weight, api: api)
        let emptySeries = emptySeriesPayload(kindKey: "weight")
        let emptyMeasurements = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/insights/") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data("{}".utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if path.contains("/api/measurements/series") {
                return (response, emptySeries)
            }
            return (response, emptyMeasurements)
        }
        await store.load()
        // Critical invariant: state must NOT remain pending. The screen's
        // empty-state arms only render on `.empty`.
        #expect(!store.dataState.isPending, "dataState must move out of .unknown/.loading after both fan-out paths confirm no data")
        if case .empty(.noData) = store.dataState {
            // expected
        } else {
            Issue.record("Expected .empty(.noData), got \(store.dataState)")
        }
        #expect(store.recentInRange.isEmpty)
    }

    @Test("Series throws + recent throws → dataState collapses to .empty(.noData) (not stuck spinner)")
    func bothEndpointsFailingCollapsesToEmpty() async throws {
        let api = makeAPIClient()
        let store = try makeStore(kind: .weight, api: api)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
        await store.load()
        // Even though both fetches threw, the screen must NOT stay on a
        // spinner — surface the error banner + an empty-state placeholder
        // instead of an infinite ProgressView (operator screenshot).
        #expect(!store.dataState.isPending, "dataState must collapse after a total fan-out failure")
        if case .empty(.noData) = store.dataState {
            // expected
        } else {
            Issue.record("Expected .empty(.noData) after total failure, got \(store.dataState)")
        }
        #expect(store.error != nil, "An error must be surfaced for the ErrorBanner overlay")
    }

    @Test("bodyTemperature (series-unsupported) + empty recent → dataState resolves to .empty(.noData)")
    func bodyTemperatureCollapsesToEmpty() async throws {
        let api = makeAPIClient()
        let store = try makeStore(kind: .bodyTemperature, api: api)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            // bodyTemperature short-circuits before hitting series at all;
            // only the measurements page request fires.
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        await store.load()
        #expect(!store.dataState.isPending)
        if case .empty(.noData) = store.dataState {
            // expected
        } else {
            Issue.record("Expected .empty(.noData) for bodyTemperature, got \(store.dataState)")
        }
    }

    // MARK: - v0.14 DATA — fix 3: floors (no-series) never perpetual-spins

    @Test("flightsClimbed (no-series) + empty kind-scoped page → settles to .empty, never stuck .loading")
    func floorsNoSeriesSettlesToEmpty() async throws {
        let api = makeAPIClient()
        let store = try makeStore(kind: .flightsClimbed, api: api)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            // No-series kind: only the (now kind-scoped) measurements page fires.
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        await store.load()
        // The operator-reported "Stockwerke perpetual spinner": dataState MUST
        // settle so ChartCard renders the empty card, not an infinite spinner.
        #expect(!store.dataState.isPending, "no-series + empty page must settle, never stay .unknown/.loading")
        if case .empty(.noData) = store.dataState {
            // expected
        } else {
            Issue.record("Expected .empty(.noData) for floors, got \(store.dataState)")
        }
    }

    // MARK: - v0.14 DATA — fix 2: BMI computed series from weight + height

    @Test("BMI derives a chartable series from the weight series + profile height")
    func bmiComputedSeriesFromWeight() async throws {
        let api = makeAPIClient()
        // height 1.80m → BMI = weight / 3.24.
        let store = try makeStore(kind: .bmi, api: api, heightCm: 180)
        let weightSeries = Data(("{\"data\":{\"kind\":\"weight\",\"points\":["
                + "{\"id\":\"w1\",\"at\":\"2026-06-01T08:00:00Z\",\"value\":81.0},"
                + "{\"id\":\"w2\",\"at\":\"2026-06-02T08:00:00Z\",\"value\":80.0}"
                + "],\"stats\":{\"mean\":80.5,\"min\":80,\"max\":81,\"stdDev\":0.5,\"count\":2}}}").utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                return (response, weightSeries)
            }
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        await store.load()
        // BMI must show a CHART (≥2 points) AND resolve to a non-empty state —
        // the operator-reported "BMI no data / no chart" fix.
        #expect(store.chartPoints.count == 2, "BMI must derive one point per weight point")
        // 81 / 1.8² = 25.0, 80 / 1.8² ≈ 24.69 — sanity-check the math.
        let first = try #require(store.chartPoints.first)
        #expect(abs(first.value - (81.0 / (1.8 * 1.8))) < 0.01)
        #expect(!store.dataState.isPending)
    }

    @Test("BMI with no height → empty (cannot derive), but does not spin")
    func bmiNoHeightCollapsesToEmpty() async throws {
        let api = makeAPIClient()
        let store = try makeStore(kind: .bmi, api: api, heightCm: nil)
        let weightSeries = Data(("{\"data\":{\"kind\":\"weight\",\"points\":["
                + "{\"id\":\"w1\",\"at\":\"2026-06-01T08:00:00Z\",\"value\":81.0}"
                + "],\"stats\":{\"mean\":81,\"min\":81,\"max\":81,\"stdDev\":0,\"count\":1}}}").utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                return (response, weightSeries)
            }
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        await store.load()
        #expect(store.chartPoints.isEmpty)
        #expect(!store.dataState.isPending, "no height must settle to empty, never spin")
    }
}

// swiftlint:enable force_unwrapping
