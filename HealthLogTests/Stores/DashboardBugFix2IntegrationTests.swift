import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// DASHBOARD-BUG-FIX-2 — integration coverage exercising the full chain:
///
/// 1. Dashboard: empty `/api/measurements` → wide-page derive yields
///    `.empty` for every kind → series fallback fires per kind →
///    populated series synthesizes `.ready` → tile renders the data.
///
/// 2. Briefing input: `MeasurementsStore.load()` populates `recent`,
///    downstream consumers (`OnDeviceBriefingHero`) filter by kind and
///    see real numbers, NOT the empty digest copy.
///
/// These tests stitch together the unit-level fixes from
/// `DashboardStoreSeriesFallbackTests` + `MeasurementsStoreBriefingInputTests`
/// against a single shared `MockURLProtocol` to mirror the real cold-launch
/// HTTP traffic the operator's iPhone produces.
@Suite("DASHBOARD-BUG-FIX-2 — integration", .serialized)
struct DashboardBugFix2IntegrationTests {
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

    @Test("Cold-launch operator profile: wide page empty for BP, series fills the tile")
    @MainActor
    func operatorProfileEndToEnd() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Simulate the operator's HK-heavy profile: wide page is dominated by
        // Steps + Pulse-stream samples that pushed BP off the 400-row window.
        // For the test we elide that and just return empty — the trigger for
        // the series fallback is the .empty state, regardless of what made it
        // empty (steps-flood vs. legitimately-no-data).
        let widePagePayload = Data("{\"data\":{\"measurements\":[]}}".utf8)
        let bpAt = iso(now.addingTimeInterval(-3600))
        let bpSeriesBody = #"{"data":{"kind":"bloodPressure","points":["#
            + #"{"id":"bp1","at":""# + bpAt + #"","value":127.0,"secondary":84.0}"#
            + #"],"stats":{"mean":127,"min":127,"max":127,"stdDev":0,"count":1}}}"#
        let bpSeriesPayload = Data(bpSeriesBody.utf8)
        let pulseAt = iso(now.addingTimeInterval(-1800))
        let pulseSeriesBody = #"{"data":{"kind":"pulse","points":["#
            + #"{"id":"p1","at":""# + pulseAt + #"","value":71.0,"secondary":null}"#
            + #"],"stats":{"mean":71,"min":71,"max":71,"stdDev":0,"count":1}}}"#
        let pulseSeriesPayload = Data(pulseSeriesBody.utf8)
        let emptySeries = Data(
            "{\"data\":{\"kind\":\"weight\",\"points\":[],\"stats\":{\"mean\":0,\"min\":0,\"max\":0,\"stdDev\":0,\"count\":0}}}"
                .utf8
        )
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                let query = request.url?.query ?? ""
                if query.contains("kind=bloodPressure") {
                    return (response, bpSeriesPayload)
                }
                if query.contains("kind=pulse") {
                    return (response, pulseSeriesPayload)
                }
                return (response, emptySeries)
            }
            return (response, widePagePayload)
        }
        await store.refreshMetricStates(
            kinds: [.bloodPressure, .pulse, .weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        // BP fallback: tile should now render the BP data the ChartDetail
        // also shows on tap.
        let bpState = store.metricStates[.bloodPressure]
        guard case let .ready(bpLatest, _) = bpState else {
            Issue.record("Expected .ready BP after integration fallback, got \(String(describing: bpState))")
            return
        }
        if case let .bloodPressure(s, d) = bpLatest.value {
            #expect(s == 127.0)
            #expect(d == 84.0)
        } else {
            Issue.record("BP integration fallback synthesized non-BP value: \(bpLatest.value)")
        }
        // Pulse fallback: same shape.
        let pulseState = store.metricStates[.pulse]
        guard case let .ready(pulseLatest, _) = pulseState else {
            Issue.record("Expected .ready pulse after integration fallback, got \(String(describing: pulseState))")
            return
        }
        #expect(pulseLatest.primaryValue == 71.0)
        // Weight: wide page empty + series empty → stays .empty(.noData) —
        // the canonical first-time-user copy. No false-positive synthesis.
        #expect(store.metricStates[.weight] == .empty(reason: .noData))
    }

    @Test("Briefing input: load() populates recent so digestMeasurements emits real count")
    @MainActor
    func briefingInputReceivesRealMeasurements() async throws {
        let api = makeAPIClient()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Build a 7-day digest payload — diverse kinds so the briefing's
        // per-kind filters (TrendObservationCard for weight, BP, etc.)
        // see something.
        let rows = (0 ..< 30).map { i -> String in
            let at = iso(now.addingTimeInterval(-Double(i) * 3600))
            return "{\"id\":\"m\(i)\",\"type\":\"WEIGHT\",\"value\":\(72 + Double(i) * 0.01),\"measuredAt\":\"\(at)\"}"
        }
        let payload = Data(("{\"data\":{\"measurements\":[" + rows.joined(separator: ",") + "]}}").utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }
        // Pre-fix: nobody called load() → store.recent stays [].
        #expect(store.recent.isEmpty, "Pre-load sanity: recent must start empty")
        await store.load()
        // Post-fix: recent carries the page → briefing input is real.
        #expect(store.recent.count == 30, "Briefing-input page should reflect the 30-row response")
        // Drill into the digest path: the prompt builder collapses any
        // non-empty array into "<count> Messungen erfasst", which is the
        // exact pre-LLM signal the operator was missing.
        let prompt = OnDeviceBriefingPrompt.build(
            measurements: store.recent,
            healthScore: nil,
            locale: Locale(identifier: "de_DE")
        )
        #expect(
            prompt.contains("30 Messungen erfasst"),
            "Briefing prompt must contain the real count, not 'keine Messungen im Zeitfenster'. Got prompt: \(prompt)"
        )
    }

    @Test("Briefing input regression guard: empty store yields the 'keine Messungen' digest line")
    @MainActor
    func emptyStoreStillYieldsEmptyDigest() {
        // Verifies the prompt builder's empty-arm still fires when no
        // measurements flow — this is the OLD behaviour the operator saw,
        // pinned here so a regression that silently switches the digest
        // copy doesn't slip through.
        let prompt = OnDeviceBriefingPrompt.build(
            measurements: [],
            healthScore: nil,
            locale: Locale(identifier: "de_DE")
        )
        #expect(prompt.contains("(keine Messungen im Zeitfenster)"))
    }
}

// swiftlint:enable force_unwrapping
