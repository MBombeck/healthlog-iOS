import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// MARK: - CU-07 — route scoping

/// The only routes `MetricInsightsRepository` can reach: the dedicated
/// `…-status` assessments, the generic `metric-status` route, and the
/// comprehensive digest.
///
/// `MockURLProtocol.handler` is process-global, so every counter and capture in
/// this file gates on this predicate — otherwise a suite running in parallel
/// moves them and the assertion fails (or, worse, passes) for a reason that has
/// nothing to do with the repository under test.
private func isMetricInsightsRoute(_ request: URLRequest) -> Bool {
    guard let path = request.url?.path, path.hasPrefix("/api/insights/") else { return false }
    return path.hasSuffix("-status") || path == "/api/insights/comprehensive"
}

// MARK: - Task #50 — preparing→poll→ready assessment lifecycle

/// Locks the Task #50 fix: the per-metric assessment is served
/// stale-while-revalidate (a cold cache returns `preparing:true, text:null` and
/// warms the prose out of band), and iOS must POLL the un-cached read until ready
/// text arrives — mirroring the web (`use-insight-status.ts`). Two prior fixes
/// "passed tests" but the text still never surfaced because `MetricStatusDTO`
/// dropped the `preparing`/`revalidating`/`insufficient` keys, so the card
/// self-suppressed on the cold body and never polled.
@Suite("MetricInsightsRepository — Task #50 assessment polling", .serialized)
struct MetricInsightsAssessmentPollingTests {
    private struct StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(online)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    @MainActor
    private func makeAPI() throws -> APIClient {
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.11.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// preparing→poll→ready: the cold body decodes `preparing:true`, classifies
    /// as `isPreparing`, and a subsequent un-cached `pollAssessment` surfaces the
    /// warmed ready text.
    @Test("preparing body then a ready poll surfaces the warmed text")
    func preparingThenPollSurfacesText() async throws {
        let api = try await makeAPI()
        nonisolated(unsafe) var callCount = 0
        MockURLProtocol.handler = { [self] request in
            if isMetricInsightsRoute(request) { callCount += 1 }
            // First call (the screen's initial fetch) → cold preparing body.
            // Second call (a poll) → the warmed assessment.
            let body = callCount == 1
                ?
                Data(
                    #"{"data":{"hasProvider":true,"text":null,"cached":false,"updatedAt":null,"preparing":true,"revalidating":false},"error":null}"#
                        .utf8
                )
                :
                Data(
                    #"{"data":{"hasProvider":true,"text":"Ruhepuls stabil im Zielbereich.","cached":false,"updatedAt":"2026-06-02T08:00:00.000Z"},"error":null}"#
                        .utf8
                )
            return (ok(request), body)
        }
        let repo = MetricInsightsRepository(api: api)

        let cold = try #require(try await repo.fetchAssessment(metric: .restingHeartRate, locale: "de"))
        #expect(cold.preparing == true)
        #expect(cold.isPreparing == true, "cold preparing body must keep the card polling")
        #expect(cold.hasReadyText == false)

        let warm = try #require(try await repo.pollAssessment(metric: .restingHeartRate, locale: "de"))
        #expect(warm.hasReadyText == true)
        #expect(warm.text == "Ruhepuls stabil im Zielbereich.")
        #expect(warm.isPreparing == false, "ready text is terminal — the poll stops")
    }

    /// insufficient body → terminal calm state, never polled.
    @Test("insufficient body is terminal (no poll)")
    func insufficientIsTerminal() async throws {
        let api = try await makeAPI()
        MockURLProtocol.handler = { [self] request in
            (
                ok(request),
                Data(#"{"data":{"hasProvider":true,"text":null,"cached":false,"updatedAt":null,"insufficient":true},"error":null}"#.utf8)
            )
        }
        let repo = MetricInsightsRepository(api: api)

        let dto = try #require(try await repo.fetchAssessment(metric: .hrv, locale: "de"))
        #expect(dto.insufficient == true)
        #expect(dto.isPreparing == false)
    }

    /// no-provider body → terminal, hidden, never polled.
    @Test("no-provider body is terminal (hidden, no poll)")
    func noProviderIsTerminal() async throws {
        let api = try await makeAPI()
        MockURLProtocol.handler = { [self] request in
            (
                ok(request),
                Data(#"{"data":{"hasProvider":false,"text":"Assistent deaktiviert.","cached":true,"updatedAt":null},"error":null}"#.utf8)
            )
        }
        let repo = MetricInsightsRepository(api: api)

        let dto = try #require(try await repo.fetchAssessment(metric: .bloodPressure, locale: "de"))
        #expect(dto.hasProvider == false)
        #expect(dto.isPreparing == false)
    }

    /// A cold `preparing` body must NOT be written through the daily SWR cache —
    /// otherwise the calm cache-paint would serve a null-text row instead of
    /// yesterday's good prose. After fetching a preparing body, the cache stays
    /// empty; only a ready assessment is persisted (via `cacheReadyAssessment`).
    @Test("a preparing body does not poison the daily SWR cache")
    func preparingBodyDoesNotPoisonCache() async throws {
        let api = try await makeAPI()
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        MockURLProtocol.handler = { [self] request in
            (
                ok(request),
                Data(#"{"data":{"hasProvider":true,"text":null,"cached":false,"updatedAt":null,"preparing":true},"error":null}"#.utf8)
            )
        }
        let repo = MetricInsightsRepository(api: api, swr: swr)

        _ = try await repo.fetchAssessment(metric: .restingHeartRate, locale: "de")

        // The daily key must be empty — a preparing/null-text body was never cached.
        let key = CacheKey.insightStatus(kind: .restingHeartRate, locale: "de", day: BerlinDayKey.string())
        let cached = await swr.peek(key, as: MetricStatusDTO.self)
        #expect(cached == nil, "a preparing/null-text body must never be written through the daily cache")

        // A ready assessment IS persisted and paints back instantly.
        let ready = MetricStatusDTO(hasProvider: true, text: "Ruhepuls stabil.", cached: false, updatedAt: nil)
        await repo.cacheReadyAssessment(metric: .restingHeartRate, locale: "de", dto: ready)
        let warm = await swr.peek(key, as: MetricStatusDTO.self)
        #expect(warm?.value.text == "Ruhepuls stabil.")
    }
}

/// PB1 Reconcile (H1) — locks the new consent-gate contract on the
/// per-metric "Befunde" path. Previously `MetricInsightsRepository.fetch`
/// hit `/api/insights/{metric}-status` unconditionally, even though the
/// server runs an LLM call when a provider is configured. App Store
/// Guideline 5.1.2(i) (Nov 2025) requires consent BEFORE any off-device
/// LLM round-trip — `Insights` + `Briefing` were gated since v0.4.2, but
/// the chart-detail "Befunde" surface was a hole. This suite verifies
/// the hole is closed at the repo layer:
///
/// 1. Gate closed → no network request fires, fetch returns nil.
/// 2. Gate open → request fires + envelope decodes.
/// 3. No gate wired (default ctor) → legacy behaviour (request fires).
@Suite("MetricInsightsRepository — consent gate (PB1 H1)", .serialized)
struct MetricInsightsRepositoryTests {
    @Test("fetch returns nil and skips the network when consent gate is closed")
    func gateClosedSkipsNetwork() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { requestCount += 1 }
            return (Self.ok(request), Data(#"{"data":{"hasProvider":true,"text":"x","cached":false,"updatedAt":null}}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { false })

        let result = try await repo.fetch(metric: .bloodPressure, locale: "de")

        #expect(result == nil, "consent-denied fetch must return nil — no LLM call may leak past consent")
        #expect(requestCount == 0, "no network round-trip when the gate is closed")
    }

    @Test("fetch performs the request and decodes when consent gate is open")
    func gateOpenPerformsRequest() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var observedPath: String?
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { observedPath = request.url?.path }
            return (Self.ok(request), Data(#"{"data":{"hasProvider":true,"text":"Werte stabil.","cached":false,"updatedAt":null}}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { true })

        let result = try await repo.fetch(metric: .bloodPressure, locale: "de")

        #expect(observedPath == "/api/insights/blood-pressure-status")
        #expect(result?.hasProvider == true)
        #expect(result?.text == "Werte stabil.")
    }

    @Test("legacy ctor without consent gate still performs the request (backwards compat)")
    func legacyConstructorPermitsRequest() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { requestCount += 1 }
            return (Self.ok(request), Data(#"{"data":{"hasProvider":false,"text":"hint","cached":false,"updatedAt":null}}"#.utf8))
        }
        // No `consentGate:` argument — the gate is nil and the repo behaves
        // as it did pre-PB1. AppContainer always wires the gate in production,
        // so this path is only relevant to unit tests that construct the
        // repo directly without a consent surface.
        let repo = MetricInsightsRepository(api: api)

        let result = try await repo.fetch(metric: .pulse, locale: "de")

        #expect(requestCount == 1)
        #expect(result?.hasProvider == false)
    }

    @Test("metric without any assessment surface short-circuits to nil regardless of gate")
    func unsupportedMetricReturnsNil() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { requestCount += 1 }
            return (Self.ok(request), Data(#"{"data":null}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { true })

        // `.bodyFat` has neither a dedicated route nor a generic-registry id
        // (no `BODY_FAT` in the server `METRIC_STATUS_IDS` enum) — it is the
        // one chartable kind with no assessment surface, so it must
        // short-circuit before any network round-trip.
        let result = try await repo.fetch(metric: .bodyFat, locale: "de")

        #expect(result == nil)
        #expect(requestCount == 0, "no endpoint mapping ⇒ no request fired (cheaper than 404 retry)")
    }

    // MARK: - v0.11 W28a — generic metric-status route

    @Test("a generic-registry kind hits /api/insights/metric-status with the metric id")
    func genericKindHitsMetricStatusRoute() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var observedPath: String?
        nonisolated(unsafe) var observedQuery: String?
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) {
                observedPath = request.url?.path
                observedQuery = request.url?.query
            }
            return (
                Self.ok(request),
                Data(#"{"data":{"hasProvider":true,"text":"Ruhepuls stabil.","cached":false,"updatedAt":null}}"#.utf8)
            )
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { true })

        let result = try await repo.fetch(metric: .restingHeartRate, locale: "de")

        #expect(observedPath == "/api/insights/metric-status")
        #expect(observedQuery?.contains("metric=RESTING_HEART_RATE") == true)
        #expect(observedQuery?.contains("locale=de") == true)
        #expect(result?.text == "Ruhepuls stabil.")
    }

    @Test("a 422 from the generic route maps to nil (graceful empty, never an error)")
    func genericRoute422MapsToNil() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.status(request, 422), Data(#"{"error":"unknown metric"}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { true })

        // Server rejects an id its closed registry enum doesn't know — must
        // surface empty findings, not a user-facing chart error.
        let result = try await repo.fetch(metric: .sleep, locale: "de")

        #expect(result == nil)
    }

    @Test("a 404 from the generic route maps to nil (route not deployed yet)")
    func genericRoute404MapsToNil() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.status(request, 404), Data(#"{"error":"not found"}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { true })

        let result = try await repo.fetch(metric: .vo2Max, locale: "de")

        #expect(result == nil)
    }

    @Test("statusRequest table — dedicated, generic, and unmapped kinds")
    func statusRequestTable() {
        // Dedicated routes (unchanged) — locale-only query.
        let bp = MetricInsightsRepository.statusRequest(for: .bloodPressure, locale: "de")
        #expect(bp?.path == "/api/insights/blood-pressure-status")
        #expect(MetricInsightsRepository.statusRequest(for: .bmi, locale: "de")?.path == "/api/insights/bmi-status")

        // Generic route — metric id + locale.
        let spo2 = MetricInsightsRepository.statusRequest(for: .spo2, locale: "en")
        #expect(spo2?.path == "/api/insights/metric-status")
        #expect(MetricInsightsRepository.metricStatusIDTable[.spo2] == "OXYGEN_SATURATION")
        #expect(MetricInsightsRepository.metricStatusIDTable[.steps] == "STEPS")
        #expect(MetricInsightsRepository.metricStatusIDTable[.sleep] == "SLEEP_DURATION")

        // Dropped: no `BODY_FAT` in the server registry — never wired.
        #expect(MetricInsightsRepository.metricStatusIDTable[.bodyFat] == nil)
        #expect(MetricInsightsRepository.statusRequest(for: .bodyFat, locale: "de") == nil)

        // Specialised ids never leak into the generic table.
        #expect(MetricInsightsRepository.metricStatusIDTable[.bloodPressure] == nil)
        #expect(MetricInsightsRepository.metricStatusIDTable[.weight] == nil)
        #expect(MetricInsightsRepository.metricStatusIDTable[.pulse] == nil)
        #expect(MetricInsightsRepository.metricStatusIDTable[.bmi] == nil)
    }

    // MARK: - v0.11 W46 — un-gated assessment read (web-mirror Insights page)

    @Test("fetchAssessment fires the request and decodes even when the consent gate is closed")
    func fetchAssessmentBypassesClosedConsentGate() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var observedPath: String?
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) {
                observedPath = request.url?.path
                requestCount += 1
            }
            // Exact current server envelope (`apiSuccess(result)` →
            // `{ data, error: null }`) with the stale-while-revalidate extras
            // (`preparing`/`revalidating`) and a fractional-second `updatedAt`.
            return (
                Self.ok(request),
                Data(#"""
                {"data":{"hasProvider":true,"text":"Ihr Blutdruck liegt im Zielbereich.","cached":true,"updatedAt":"2026-06-02T08:15:30.000Z","preparing":false,"revalidating":false},"error":null}
                """#.utf8)
            )
        }
        // Consent gate CLOSED — `fetch` would skip the network and return nil.
        // `fetchAssessment` must NOT consult the gate: the GET is read-only
        // (server `readOnly: true`) and transmits no new health data, so the
        // web-mirror page shows the already-generated assessment regardless of
        // the on-device consent grant (W46 operator P1: "web shows BP, iOS not").
        let repo = MetricInsightsRepository(api: api, consentGate: { false })

        let result = try await repo.fetchAssessment(metric: .bloodPressure, locale: "de")

        #expect(requestCount == 1, "fetchAssessment must fire the request even with a closed consent gate")
        #expect(observedPath == "/api/insights/blood-pressure-status")
        #expect(result?.hasProvider == true)
        #expect(result?.text == "Ihr Blutdruck liegt im Zielbereich.")
        #expect(result?.cached == true)
        #expect(result?.updatedAt != nil)
    }

    @Test("fetchAssessment surfaces hasProvider:false (no provider configured) verbatim")
    func fetchAssessmentSurfacesNoProviderHint() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            (
                Self.ok(request),
                Data(#"{"data":{"hasProvider":false,"text":"Assistent deaktiviert.","cached":true,"updatedAt":null},"error":null}"#.utf8)
            )
        }
        let repo = MetricInsightsRepository(api: api, consentGate: { false })

        // No provider → the server emits `hasProvider:false` + a localized hint.
        // The card renders the "assistant disabled" arm (NOT an empty box).
        let result = try await repo.fetchAssessment(metric: .bloodPressure, locale: "de")

        #expect(result?.hasProvider == false)
        #expect(result?.text == "Assistent deaktiviert.")
    }

    @Test("fetchAssessment short-circuits to nil for a kind with no assessment surface")
    func fetchAssessmentUnsupportedKindReturnsNil() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { requestCount += 1 }
            return (Self.ok(request), Data(#"{"data":null,"error":null}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        let result = try await repo.fetchAssessment(metric: .bodyFat, locale: "de")

        #expect(result == nil)
        #expect(requestCount == 0)
    }

    @Test("fetchAssessment maps a 404/422 to nil (graceful empty, never an error)")
    func fetchAssessment404MapsToNil() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.status(request, 404), Data(#"{"data":null,"error":"not found"}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        let result = try await repo.fetchAssessment(metric: .vo2Max, locale: "de")

        #expect(result == nil)
    }

    // MARK: - v0.7.0 W-API-RENDER — per-metric summary

    @Test("summary(metric:) extracts the metric's MetricSummary from the comprehensive digest")
    func summaryExtractsFromComprehensive() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var observedPath: String?
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { observedPath = request.url?.path }
            let body = #"""
            {"data":{"summaries":{"WEIGHT":{"count":87,"latest":78.4,"avg30":79.2,"slope7":{"slope":-0.04,"direction":"down","confidence":0.62},"avg30LastYear":81.5}}}}
            """#
            return (Self.ok(request), Data(body.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        let summary = try await repo.summary(metric: .weight)

        #expect(observedPath == "/api/insights/comprehensive")
        #expect(summary?.avg30LastYear == 81.5)
        #expect(summary?.slope7?.direction == .down)
        #expect(summary?.avg30 == 79.2)
    }

    @Test("summary(metric:) returns nil for kinds with no comprehensive summary key")
    func summaryNilForUnmappedKind() async throws {
        let api = try await makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            if isMetricInsightsRoute(request) { requestCount += 1 }
            return (Self.ok(request), Data(#"{"data":{}}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        // BMI has no server `summaries` entry — must short-circuit, no request.
        let summary = try await repo.summary(metric: .bmi)

        #expect(summary == nil)
        #expect(requestCount == 0, "no summary key ⇒ no comprehensive round-trip")
    }

    @Test("summary(metric:) returns nil when the metric is absent from summaries")
    func summaryNilWhenMetricMissing() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            // Digest carries WEIGHT but not PULSE.
            (Self.ok(request), Data(#"{"data":{"summaries":{"WEIGHT":{"count":5}}}}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        let summary = try await repo.summary(metric: .pulse)

        #expect(summary == nil)
    }

    @Test("summary(metric:) returns nil on a 500 — best-effort, never re-throws (v0.7.1 H-1)")
    func summaryReturnsNilOnServerError() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.status(request, 500), Data(#"{"error":"boom"}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        // Pre-v0.7.1 this re-threw HLError.server(500); the contract is
        // best-effort so a transient 500 on a decorative-only fetch must
        // collapse to "no trend decoration", not a user-facing chart error.
        let summary = try await repo.summary(metric: .weight)

        #expect(summary == nil)
    }

    @Test("summary(metric:) returns nil on a decode failure — best-effort (v0.7.1 H-1)")
    func summaryReturnsNilOnDecodeFailure() async throws {
        let api = try await makeAPIClient()
        MockURLProtocol.handler = { request in
            // 200 OK but a body that cannot decode into AIInsightResponse.
            (Self.ok(request), Data(#"{"data":{"summaries":{"WEIGHT":"not-an-object"}}}"#.utf8))
        }
        let repo = MetricInsightsRepository(api: api)

        let summary = try await repo.summary(metric: .weight)

        #expect(summary == nil)
    }

    @Test("summariesKey maps blood pressure to the systolic summary")
    func summariesKeyBloodPressure() {
        #expect(MetricInsightsRepository.summariesKey(for: .bloodPressure) == "BLOOD_PRESSURE_SYS")
        #expect(MetricInsightsRepository.summariesKey(for: .weight) == "WEIGHT")
        #expect(MetricInsightsRepository.summariesKey(for: .glucose) == "BLOOD_GLUCOSE")
        // Kinds without a comprehensive summary key.
        #expect(MetricInsightsRepository.summariesKey(for: .bmi) == nil)
        #expect(MetricInsightsRepository.summariesKey(for: .steps) == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeAPIClient() async throws -> APIClient {
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        status(request, 200)
    }

    private static func status(_ request: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
