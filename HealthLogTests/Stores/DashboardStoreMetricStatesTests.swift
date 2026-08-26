import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// File-scope on purpose: the suite's tests are `@MainActor`, and a `@Sendable`
/// handler closure running on the URL-loading queue cannot call a main-actor
/// member.
private func respond(_ req: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
    let http = HTTPURLResponse(
        url: req.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (http, Data(json.utf8))
}

/// F1 regression guard (PB5 review): `DashboardStore.refreshMetricStates`
/// MUST collapse the per-kind fan-out into a single `/api/measurements`
/// round-trip. The previous implementation fired N parallel calls (one
/// per `MetricKind`, up to 11) — each returning the SAME 400-row page.
///
/// These tests pin the contract:
/// 1. Refreshing N kinds triggers exactly **1** network call.
/// 2. The derived per-kind state matches what `MetricDataState.derive`
///    would produce for that kind against the same page.
///
/// ## Issue #82 / Plan 09-11 — the transport is session-owned
///
/// Every response handler below is installed on a ``MockURLProtocolSession``
/// that its own test retains, and that session's `baseURL` **and** configuration
/// build that test's `APIClient`. This file assigns the mock's process-global
/// handler slot zero times. That matters more here than almost anywhere: point 1
/// asserts a counter equals **1**, and a request that never reached this suite
/// leaves it at **0** — a failure on the *safe-looking* side of the contract, so
/// an unrouted transport could not be told apart from a fan-out that was
/// correctly collapsed.
@Suite("DashboardStore.refreshMetricStates — F1 fan-out collapse", .serialized)
struct DashboardStoreMetricStatesTests {
    /// Counts the requests this test's own session answered. Wrapped in a class
    /// so the `@Sendable` handler closure can mutate it across actor boundaries
    /// without copy semantics, and `Mutex`-backed rather than an `NSLock` behind
    /// an unchecked-`Sendable` conformance (Plan 09-11).
    private final class CallCounter: Sendable {
        private let stored = Mutex(0)

        /// Named `value`, not `count`: `#expect(theirs.value == 0)` reads to
        /// SwiftLint's `empty_count` rule as a collection emptiness check and is
        /// an error-severity violation. The counter is not a collection, and the
        /// rule is right to be suspicious of the spelling rather than wrong here.
        var value: Int {
            stored.withLock { $0 }
        }

        func bump() {
            stored.withLock { $0 += 1 }
        }
    }

    /// The transport seam (issue #82 / Plan 09-11). Both halves come from the
    /// caller's retained session, so every request this client makes is answered
    /// by that session's handler or by nothing at all.
    ///
    /// `baseURL: session.baseURL` is the load-bearing half. `APIClient.init`
    /// assigns `config.httpAdditionalHeaders` **wholesale** on the configuration
    /// object it is handed, before its `URLSession` exists, so the session token
    /// is gone by the time the first request is built. Keeping the old
    /// hard-coded host while passing `session.configuration` would leave the four
    /// handlers below installed and never reached, answered instead by the legacy
    /// process-global slot —
    /// `MockURLProtocolIsolationTests.aSessionConfigurationAloneDoesNotMigrateAClient`
    /// pins that trap. `req.targets("/api/measurements")` is unaffected; only the
    /// host moved.
    @MainActor
    private func makeAPIClient(session: MockURLProtocolSession) -> APIClient {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: session.configuration)
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Page emitted for the `/api/measurements?limit=400` call — covers
    /// multiple kinds so each per-kind derivation has something to find.
    /// Server wire types only — `STEPS` is not in `ServerMeasurementType`
    /// (sleep / steps come exclusively through HK aggregations server-side),
    /// so the outside-range probe uses `BODY_FAT` instead.
    private func mixedKindsPayload(now: Date) -> Data {
        let w = "{\"id\":\"w1\",\"type\":\"WEIGHT\",\"value\":72.0,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400 * 2)))\"}"
        let p = "{\"id\":\"p1\",\"type\":\"PULSE\",\"value\":64.0,\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        let f = "{\"id\":\"f1\",\"type\":\"BODY_FAT\",\"value\":22.0,\"measuredAt\":\"\(iso(now.addingTimeInterval(-86400 * 120)))\"}"
        let body = "{\"data\":{\"measurements\":[\(w),\(p),\(f)]}}"
        return Data(body.utf8)
    }

    @Test("11-kind refresh triggers exactly 1 /api/measurements (recent-all) call")
    @MainActor
    func singleRoundTrip() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeAPIClient(session: session)
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)

        let counter = CallCounter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recentPayload = mixedKindsPayload(now: now)
        // DASHBOARD-BUG-FIX-2: the series-endpoint fallback also fires for
        // kinds that resolved .empty from the wide page. The pinned
        // invariant remains "exactly 1 recent-all call across N kinds";
        // series calls are additive but irrelevant to this contract.
        let emptySeries = Data(
            "{\"data\":{\"kind\":\"weight\",\"points\":[],\"stats\":{\"mean\":0,\"min\":0,\"max\":0,\"stdDev\":0,\"count\":0}}}"
                .utf8
        )
        session.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.path.contains("/api/measurements/series") == true {
                return (response, emptySeries)
            }
            // Only the wide recent-all page is the fan-out guard target, and
            // "recent-all" is now spelled out on both axes (Plan 09-11): the
            // **exact** path `/api/measurements` by `targets(_:method:)`, and no
            // `?type=`. Bounded kind-scoped fallbacks (`?type=…`, e.g. the BMI
            // `BODY_MASS_INDEX` no-series fallback) are expected and allowed —
            // they are one call per no-series-empty kind, not per kind. The old
            // form counted *any* path that carried no `type=`, which the session
            // now makes harmless but which said less than it meant.
            let isRecentAll = request.targets("/api/measurements", method: "GET")
                && (request.url?.query ?? "").contains("type=") == false
            if isRecentAll {
                counter.bump()
            }
            return (response, recentPayload)
        }

        await store.refreshMetricStates(
            kinds: MetricKind.allCases,
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        #expect(
            counter.value == 1,
            "Dashboard tile state fan-out across \(MetricKind.allCases.count) kinds must hit /api/measurements (the wide page) exactly once, observed \(counter.value)"
        )
    }

    @Test("derived states match per-kind expectations from the same page")
    @MainActor
    func derivedStatesMatchPage() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeAPIClient(session: session)
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = mixedKindsPayload(now: now)
        session.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        await store.refreshMetricStates(
            kinds: [.weight, .pulse, .bodyFat, .glucose],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        // weight + pulse have a row inside 30d → .ready
        #expect(store.metricStates[.weight]?.hasValue == true)
        #expect(store.metricStates[.pulse]?.hasValue == true)
        // bodyFat has a row but it's > 30d → .empty(.outsideRange)
        if case .empty(.outsideRange) = store.metricStates[.bodyFat] ?? .unknown {
            // expected
        } else {
            Issue.record("Expected .empty(.outsideRange) for bodyFat, got \(String(describing: store.metricStates[.bodyFat]))")
        }
        // glucose has no row in the page at all → .empty(.noData)
        #expect(store.metricStates[.glucose] == .empty(reason: .noData))
    }

    @Test("network failure preserves existing metricStates")
    @MainActor
    func failurePreservesExistingStates() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeAPIClient(session: session)
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let dashboardRepo = DashboardRepository(api: api)
        let store = DashboardStore(repo: dashboardRepo)

        // Seed a known state via a successful first refresh.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = mixedKindsPayload(now: now)
        session.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        #expect(store.metricStates[.weight]?.hasValue == true)

        // Now simulate a 500 — existing states must stay.
        session.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        #expect(store.metricStates[.weight]?.hasValue == true, "Failure must not clear the previously-known weight state")
        #expect(store.metricStates[.pulse]?.hasValue == true, "Failure must not clear the previously-known pulse state")
    }

    // MARK: - Transport ownership (issue #82 / Plan 09-11)

    @Test("a handler installed after ours cannot answer this suite's request")
    @MainActor
    func aLaterInstallCannotAnswerThisSuite() async throws {
        // The failure this migration removes: a suite running in parallel
        // replaces the handler between our install and our request, so our
        // request is answered by a foreign closure and the fan-out counter this
        // whole suite exists for stays at zero — which reads as a *pass* for the
        // "exactly one call" contract. Here the foreign install happens *after*
        // ours, deterministically the losing order under one process-global
        // slot, and must still not be reached.
        let session = MockURLProtocolSession()
        let foreign = MockURLProtocolSession()
        defer {
            session.invalidate()
            foreign.invalidate()
        }
        let mine = CallCounter()
        let theirs = CallCounter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let page = mixedKindsPayload(now: now)
        let emptySeries = #"{"data":{"kind":"weight","points":[],"stats":{"mean":0,"min":0,"max":0,"stdDev":0,"count":0}}}"#
        session.install { req in
            // Scoped to the wide recent-all page, exactly like `singleRoundTrip`:
            // the series-endpoint fallback is additive and irrelevant here.
            guard req.targets("/api/measurements") else { return respond(req, emptySeries) }
            mine.bump()
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                page
            )
        }
        foreign.install { req in
            theirs.bump()
            return respond(req, "{}")
        }

        let api = makeAPIClient(session: session)
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = DashboardStore(repo: DashboardRepository(api: api))
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )

        // A positive count is the whole point. `singleRoundTrip` asserts
        // `counter.value == 1` and an unrouted request leaves it at 0, which is
        // *less* than one — so the suite's headline contract could not tell a
        // collapsed fan-out from a transport that never reached it.
        #expect(mine.value >= 1, "EXPECTED_RED: DashboardStoreMetricStatesTests was not routed to its own session")
        #expect(theirs.value == 0)
        #expect(store.metricStates[.weight]?.hasValue == true)
    }
}

// swiftlint:enable force_unwrapping
