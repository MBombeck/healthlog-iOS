import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **V052-A1 B2 regression guard.** When the wide `/api/measurements?limit=400`
/// page already carries enough rows for BP / Pulse to derive `.ready` directly
/// (no series-fallback needed), the per-kind sparkline must still be hydrated
/// from those samples so the tile renders the same chart `ChartDetail` would
/// show on tap. Pre-fix the hydration only fired from the series-fallback
/// arm — meaning BP + Pulse with data in the wide page rendered a value but
/// no sparkline (operator-reported "tile ohne Chart" symptom).
@Suite("DashboardStore — sparkline hydration from wide-page .ready states", .serialized)
@MainActor
struct DashboardStoreSparklineHydrationTests {
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
            sparkline: [], // intentionally empty — operator-reported pre-fix state
            updatedAt: nil
        )
    }

    @Test("BP tile sparkline populated when wide page carries paired SYS/DIA rows")
    func bpSparklineHydratesFromWidePage() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        store.seedSummaryForTesting(summary(with: [placeholderMetric(.bloodPressure)]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        /// BP is encoded server-side as TWO paired rows per reading
        /// (`BLOOD_PRESSURE_SYS` + `BLOOD_PRESSURE_DIA` with matching
        /// `measuredAt`). The repo pairs them client-side into a single
        /// `MeasurementValue.bloodPressure` row. Three readings = six wire
        /// rows; the hydrated sparkline must carry three (post-pairing)
        /// values, one per reading.
        func pair(id: String, at: Date, sys: Double, dia: Double) -> String {
            let atISO = iso(at)
            let sysRow = "{\"id\":\"\(id)-s\",\"type\":\"BLOOD_PRESSURE_SYS\",\"value\":\(sys),\"measuredAt\":\"\(atISO)\"}"
            let diaRow = "{\"id\":\"\(id)-d\",\"type\":\"BLOOD_PRESSURE_DIA\",\"value\":\(dia),\"measuredAt\":\"\(atISO)\"}"
            return sysRow + "," + diaRow
        }
        let p1 = pair(id: "b1", at: now.addingTimeInterval(-86400 * 3), sys: 124, dia: 81)
        let p2 = pair(id: "b2", at: now.addingTimeInterval(-86400 * 2), sys: 122, dia: 79)
        let p3 = pair(id: "b3", at: now.addingTimeInterval(-86400), sys: 126, dia: 82)
        let payload = "{\"data\":{\"measurements\":[\(p1),\(p2),\(p3)]}}"
        let widePageData = Data(payload.utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, widePageData)
        }

        await store.refreshMetricStates(
            kinds: [.bloodPressure],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        // State must be .ready, otherwise the hydration precondition wasn't met.
        guard case .ready = store.metricStates[.bloodPressure] else {
            Issue.record("Expected .ready for bloodPressure, got \(String(describing: store.metricStates[.bloodPressure]))")
            return
        }
        let bp = store.summary?.metrics.first { $0.kind == .bloodPressure }
        #expect((bp?.sparkline.count ?? 0) >= 1, "Expected the wide-page-derived BP tile sparkline to carry at least one point")
        // Sanity check — every value must be a plausible systolic reading
        // (the sparkline maps `MeasurementValue.bloodPressure.primaryComponent`
        // which is the systolic component).
        for value in bp?.sparkline ?? [] {
            #expect(value >= 80 && value <= 200, "Sparkline value should be a systolic reading, got \(value)")
        }
    }

    @Test("Pulse tile sparkline populated when wide page carries pulse rows")
    func pulseSparklineHydratesFromWidePage() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        store.seedSummaryForTesting(summary(with: [placeholderMetric(.pulse)]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let row1 = "{\"id\":\"p1\",\"type\":\"PULSE\",\"value\":64,\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        let row2 = "{\"id\":\"p2\",\"type\":\"PULSE\",\"value\":68,\"measuredAt\":\"\(iso(now.addingTimeInterval(-1800)))\"}"
        let widePageData = Data("{\"data\":{\"measurements\":[\(row1),\(row2)]}}".utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, widePageData)
        }

        await store.refreshMetricStates(
            kinds: [.pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        guard case .ready = store.metricStates[.pulse] else {
            Issue.record("Expected .ready for pulse, got \(String(describing: store.metricStates[.pulse]))")
            return
        }
        let pulse = store.summary?.metrics.first { $0.kind == .pulse }
        #expect(pulse?.sparkline.count == 2, "Expected the wide-page-derived pulse tile sparkline to carry one point per row")
    }

    @Test("Existing non-empty sparkline from server is preserved (not overwritten by hydration)")
    func serverSparklineWins() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        // Server already emitted a 5-point sparkline — wide-page-derived
        // hydration must NOT clobber it (server's pre-aggregated values
        // may already include downsampling or per-day buckets that the
        // raw measurement points don't carry).
        let serverSparkline: [Double] = [70, 71, 72, 73, 74]
        let weightWithSparkline = DashboardMetric(
            id: "weight",
            kind: .weight,
            title: "Gewicht",
            latestValue: 74,
            secondaryValue: nil,
            unit: "kg",
            trend: .up,
            sparkline: serverSparkline,
            updatedAt: nil
        )
        store.seedSummaryForTesting(summary(with: [weightWithSparkline]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let row = "{\"id\":\"w1\",\"type\":\"WEIGHT\",\"value\":75,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400)))\"}"
        let widePageData = Data("{\"data\":{\"measurements\":[\(row)]}}".utf8)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, widePageData)
        }
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        let weight = store.summary?.metrics.first { $0.kind == .weight }
        #expect(weight?.sparkline == serverSparkline, "Server-emitted sparkline must win over wide-page hydration")
    }

    @Test("fanOutSettledAt is set on successful refresh")
    func fanOutSettledOnSuccess() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"data\":{\"measurements\":[]}}".utf8))
        }
        #expect(store.fanOutSettledAt == nil, "Pre-condition: fan-out has not settled before the first call")
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        #expect(store.fanOutSettledAt == now, "fanOutSettledAt must capture the supplied `now` timestamp on success")
    }

    /// **REG-11 regression guard (v0.5.6).** The operator-reported "BP /
    /// Puls / Körperfett tile zeigt keinen Chart" symptom that survived four
    /// rounds of fixes (`cafac57f`, `f3b14346`, `79396261`) traces to a
    /// single-point server sparkline being treated as "non-empty" by both
    /// the tile rendering gate AND the store hydration gate. `HLSparkline`
    /// collapses any series with `< 2` points to a flat hairline, so a
    /// `sparkline: [124]` payload (one daily rollup bucket — the realistic
    /// shape for low-frequency manual entry on these three kinds) read
    /// visually as "no chart" while the chart-detail screen (loading from
    /// `/api/measurements/series` directly) showed the full chart.
    @Test("BP tile single-point server sparkline triggers wide-page hydration")
    func bpSingleSparklinePointHydrates() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        // Server-emitted single-point sparkline — pre-REG-11-fix this passed
        // the `isEmpty == false` gate and the hydration was skipped.
        let bpWithOnePoint = DashboardMetric(
            id: "bp",
            kind: .bloodPressure,
            title: "Blutdruck",
            latestValue: 124,
            secondaryValue: 81,
            unit: "mmHg",
            trend: .unknown,
            sparkline: [124], // single-point — visually a hairline
            updatedAt: nil
        )
        store.seedSummaryForTesting(summary(with: [bpWithOnePoint]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func pair(id: String, at: Date, sys: Double, dia: Double) -> String {
            let atISO = iso(at)
            let sysRow = "{\"id\":\"\(id)-s\",\"type\":\"BLOOD_PRESSURE_SYS\",\"value\":\(sys),\"measuredAt\":\"\(atISO)\"}"
            let diaRow = "{\"id\":\"\(id)-d\",\"type\":\"BLOOD_PRESSURE_DIA\",\"value\":\(dia),\"measuredAt\":\"\(atISO)\"}"
            return sysRow + "," + diaRow
        }
        let p1 = pair(id: "b1", at: now.addingTimeInterval(-86400 * 3), sys: 122, dia: 79)
        let p2 = pair(id: "b2", at: now.addingTimeInterval(-86400 * 2), sys: 124, dia: 81)
        let p3 = pair(id: "b3", at: now.addingTimeInterval(-86400), sys: 126, dia: 83)
        let payload = "{\"data\":{\"measurements\":[\(p1),\(p2),\(p3)]}}"
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
            kinds: [.bloodPressure],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        let bp = store.summary?.metrics.first { $0.kind == .bloodPressure }
        #expect(
            (bp?.sparkline.count ?? 0) >= 2,
            "Single-point server sparkline must be expanded via wide-page hydration so HLSparkline can render a real chart instead of the < 2-points hairline."
        )
    }

    @Test("BodyFat tile single-point server sparkline triggers wide-page hydration")
    func bodyFatSingleSparklinePointHydrates() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let bodyFatOne = DashboardMetric(
            id: "bodyFat",
            kind: .bodyFat,
            title: "Körperfett",
            latestValue: 22.0,
            secondaryValue: nil,
            unit: "%",
            trend: .unknown,
            sparkline: [22.0],
            updatedAt: nil
        )
        store.seedSummaryForTesting(summary(with: [bodyFatOne]))

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
        let bf = store.summary?.metrics.first { $0.kind == .bodyFat }
        #expect((bf?.sparkline.count ?? 0) >= 2, "BodyFat single-point sparkline must be hydrated from the wide page")
    }

    @Test("Pulse tile single-point server sparkline triggers wide-page hydration")
    func pulseSingleSparklinePointHydrates() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)
        let pulseOne = DashboardMetric(
            id: "pulse",
            kind: .pulse,
            title: "Puls",
            latestValue: 68,
            secondaryValue: nil,
            unit: "bpm",
            trend: .unknown,
            sparkline: [68],
            updatedAt: nil
        )
        store.seedSummaryForTesting(summary(with: [pulseOne]))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = "{\"id\":\"p1\",\"type\":\"PULSE\",\"value\":66,\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600 * 5)))\"}"
        let r2 = "{\"id\":\"p2\",\"type\":\"PULSE\",\"value\":70,\"measuredAt\":\"\(iso(now.addingTimeInterval(-1800)))\"}"
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
            kinds: [.pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        let pulse = store.summary?.metrics.first { $0.kind == .pulse }
        #expect((pulse?.sparkline.count ?? 0) >= 2, "Pulse single-point sparkline must be hydrated from the wide page")
    }

    @Test("fanOutSettledAt is set even when recentAll() throws (operator N1 scenario)")
    func fanOutSettledOnFailure() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        // Critical: without this signal, `DashboardEmptyTilePolicy` never
        // gets the loading-too-long input it needs to auto-hide
        // perpetually-`.unknown` tiles after a network failure.
        #expect(store.fanOutSettledAt == now, "fanOutSettledAt must be set even after recentAll() failure (operator N1)")
    }
}

// swiftlint:enable force_unwrapping
