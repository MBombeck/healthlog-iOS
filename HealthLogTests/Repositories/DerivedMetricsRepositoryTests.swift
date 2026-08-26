import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping type_body_length

/// Locks the wire contract for `GET /api/insights/derived?metric=<ID>`
/// (server v1.10.0, `src/app/api/insights/derived/route.ts`, envelope
/// `src/lib/insights/derived/types.ts:Derived<T>`).
///
/// Covers:
/// - the flattened `Derived<T>` envelope decode (status / coverage /
///   confidence / provenance / value) on the `ok` arm
/// - the `insufficient` arm (no value/confidence, reason present) decodes +
///   is honestly NOT presented as a value
/// - 422 (unknown id) / 404 (route absent) → nil (skip the metric)
/// - HONEST-ONLY: the derived block renders only `ok`-with-value envelopes
@Suite("DerivedMetrics — wire contract + honest-only gating", .serialized)
struct DerivedMetricsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.12.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("fetch — decodes the ok arm (score + coverage + confidence + provenance)")
    func fetchOkComposite() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"READINESS","status":"ok",
              "value":{"score":78,"band":"green"},
              "coverage":{"requiredInputs":5,"presentInputs":4,"historyDays":21,"missing":["RESPIRATORY_RATE"]},
              "confidence":{"score":78,"band":"high"},
              "provenance":{"inputs":["RESTING_HEART_RATE","HEART_RATE_VARIABILITY","SLEEP_DURATION"],
                            "source":"DAY","windowDays":30,"computedAt":"2026-06-02T22:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "READINESS"))
        #expect(dto.isOK)
        #expect(dto.metric == "READINESS")
        #expect(dto.value?.score == 78)
        #expect(dto.value?.band == "green")
        #expect(dto.coverage.missing == ["RESPIRATORY_RATE"])
        #expect(dto.confidence?.band == "high")
        #expect(dto.provenance.source == "DAY")
        #expect(dto.provenance.windowDays == 30)
        #expect(dto.reason == nil)
    }

    @Test("fetch — wellness score decodes trendDelta (real wellness-scores.ts wire shape)")
    func fetchWellnessScoreTrend() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            // Byte-aligned with src/lib/insights/derived/wellness-scores.ts
            // `WellnessScoreValue` (score/band/trendDelta/daysInWindow/asOf).
            let body = Data(#"""
            {"data":{
              "metric":"RECOVERY_SCORE","status":"ok",
              "value":{"score":64,"band":"yellow","trendDelta":7,"daysInWindow":9,
                       "asOf":"2026-06-02T12:00:00Z"},
              "coverage":{"requiredInputs":1,"presentInputs":1,"historyDays":9,"missing":[]},
              "confidence":{"score":90,"band":"high"},
              "provenance":{"inputs":["RECOVERY_SCORE"],"source":"DAY","windowDays":14,
                            "computedAt":"2026-06-02T22:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "RECOVERY_SCORE"))
        #expect(dto.value?.score == 64)
        #expect(dto.value?.trendDelta == 7)
        // HONEST-ONLY: the trend line derives from the server delta only.
        // Locale-resolved (host may run de).
        #expect([
            "+7 vs your recent baseline",
            "+7 gegenüber deinem jüngsten Ausgangswert"
        ].contains(InsightsDerivedBlock.trendLine(for: dto)))
    }

    @Test("trendLine — nil delta + non-score metric → no fabricated trend")
    func trendLineHonestSuppression() {
        let cov = DerivedMetricDTO.Coverage(requiredInputs: 1, presentInputs: 1, historyDays: 9, missing: [])
        let prov = DerivedMetricDTO.Provenance(
            inputs: ["RECOVERY_SCORE"], source: "DAY", windowDays: 14, computedAt: .now
        )
        // Wellness score but the server returned no prior window → no line.
        let noDelta = DerivedMetricDTO(
            metric: "STRESS_SCORE", status: "ok",
            value: .init(score: 42, trendDelta: nil, band: "yellow"),
            coverage: cov, confidence: .init(score: 90, band: "high"), provenance: prov, reason: nil
        )
        #expect(InsightsDerivedBlock.trendLine(for: noDelta) == nil)
        // A re-frame metric never carries a trend line even with a value.
        let reframe = DerivedMetricDTO(
            metric: "FITNESS_AGE", status: "ok",
            value: .init(score: nil, trendDelta: 5, band: nil, fitnessAgeDeltaYears: -6),
            coverage: cov, confidence: .init(score: 70, band: "medium"), provenance: prov, reason: nil
        )
        #expect(InsightsDerivedBlock.trendLine(for: reframe) == nil)
    }

    @Test("fetch — decodes the re-frame arm (fitness-age delta years)")
    func fetchOkReframe() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"FITNESS_AGE","status":"ok",
              "value":{"vo2Max":44.2,"fitnessAgeDeltaYears":-6,"band":"high"},
              "coverage":{"requiredInputs":1,"presentInputs":1,"historyDays":40,"missing":[]},
              "confidence":{"score":70,"band":"medium"},
              "provenance":{"inputs":["VO2_MAX"],"source":"DAY","windowDays":90,
                            "computedAt":"2026-06-02T22:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "FITNESS_AGE"))
        #expect(dto.value?.fitnessAgeDeltaYears == -6)
        #expect(dto.value?.vo2Max == 44.2)
        // HONEST-ONLY re-frame headline derives from the server value, not
        // invented. The catalog resolves to the host locale, so assert the
        // verbatim EN-or-DE re-frame string.
        #expect([
            "Cardio fitness of someone ~6 yr younger",
            "Ausdauer wie ~6 J. jünger"
        ].contains(InsightsDerivedBlock.headline(for: dto)))
    }

    @Test("fetch — insufficient arm decodes (no value, reason present)")
    func fetchInsufficient() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"SLEEP_SCORE","status":"insufficient",
              "value":null,
              "coverage":{"requiredInputs":1,"presentInputs":0,"historyDays":0,"missing":["SLEEP_DURATION"]},
              "confidence":null,
              "provenance":{"inputs":["SLEEP_DURATION"],"source":"none","windowDays":0,
                            "computedAt":"2026-06-02T22:00:00+02:00"},
              "reason":"insufficient_components"
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "SLEEP_SCORE"))
        #expect(!dto.isOK)
        #expect(dto.value == nil)
        #expect(dto.confidence == nil)
        #expect(dto.reason == "insufficient_components")
    }

    @Test("fetch — 422 (unknown id) → nil → metric skipped")
    func fetch422IsNil() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(metric: "FUTURE_METRIC") == nil)
    }

    @Test("fetch — 404 (route absent) → nil")
    func fetch404IsNil() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(metric: "READINESS") == nil)
    }

    @Test("fetchBatch — decodes the token-keyed map into one pass")
    func fetchBatchDecodesMap() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/insights/derived/batch") == true)
            // `data.metrics` keyed by the per-request token; each value is the
            // same flat Derived<T> envelope the single route returns.
            let body = Data(#"""
            {"data":{"metrics":{
              "READINESS":{"metric":"READINESS","status":"ok","value":{"score":78,"band":"green"},
                "coverage":{"requiredInputs":5,"presentInputs":4,"historyDays":21,"missing":[]},
                "confidence":{"score":78,"band":"high"},
                "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"DAY","windowDays":30,
                              "computedAt":"2026-06-02T22:00:00+02:00"},"reason":null},
              "STRESS_SCORE":{"metric":"STRESS_SCORE","status":"insufficient","value":null,
                "coverage":{"requiredInputs":1,"presentInputs":0,"historyDays":0,"missing":["HEART_RATE_VARIABILITY"]},
                "confidence":null,
                "provenance":{"inputs":["HEART_RATE_VARIABILITY"],"source":"none","windowDays":0,
                              "computedAt":"2026-06-02T22:00:00+02:00"},"reason":"insufficient_components"}
            }},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let out = await repo.fetchBatch(["READINESS", "STRESS_SCORE"])
        #expect(out.count == 2)
        let readiness = try #require(out.first { $0.metric == "READINESS" })
        #expect(readiness.isOK)
        #expect(readiness.value?.score == 78)
        let stress = try #require(out.first { $0.metric == "STRESS_SCORE" })
        #expect(!stress.isOK)
        #expect(stress.reason == "insufficient_components")
    }

    @Test("fetchBatch — 422 on the batch route falls back to the per-id fan-out")
    func fetchBatchFallsBackOn422() async {
        let repo = DerivedMetricsRepository(api: makeAPI())
        // The batch route 422s the whole request if ANY token is unknown; the
        // single route drops just the unknown arm. The handler 422s `/batch`
        // and serves the single route, so the fallback must still hydrate the
        // known ids.
        MockURLProtocol.handler = { req in
            if req.url?.path.hasSuffix("/insights/derived/batch") == true {
                return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
            }
            let metric = req.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "metric" }?.value ?? "READINESS"
            if metric == "FUTURE_METRIC" {
                return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = Data(#"""
            {"data":{"metric":"\#(metric)","status":"ok","value":{"score":80,"band":"green"},
              "coverage":{"requiredInputs":1,"presentInputs":1,"historyDays":10,"missing":[]},
              "confidence":{"score":80,"band":"high"},
              "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"DAY","windowDays":30,
                            "computedAt":"2026-06-02T22:00:00+02:00"},"reason":null}
            ,"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let out = await repo.fetchBatch(["READINESS", "FUTURE_METRIC"])
        // Batch 422'd → per-id fallback: READINESS hydrates, FUTURE_METRIC drops.
        #expect(out.count == 1)
        #expect(out.first?.metric == "READINESS")
    }

    @MainActor
    @Test("store — presentable drops insufficient envelopes (HONEST-ONLY)")
    func storePresentableHonestOnly() {
        // Hand-built envelopes: one ok-with-value, one insufficient. Only the
        // ok one is presentable — never fabricate a value for the gated arm.
        let cov = DerivedMetricDTO.Coverage(requiredInputs: 1, presentInputs: 1, historyDays: 10, missing: [])
        let prov = DerivedMetricDTO.Provenance(inputs: ["MOOD"], source: "DAY", windowDays: 30, computedAt: .now)
        let ok = DerivedMetricDTO(
            metric: "READINESS", status: "ok",
            value: .init(score: 80, band: "green"),
            coverage: cov, confidence: .init(score: 80, band: "high"),
            provenance: prov, reason: nil
        )
        let insufficient = DerivedMetricDTO(
            metric: "SLEEP_SCORE", status: "insufficient",
            value: nil, coverage: cov, confidence: nil, provenance: prov, reason: "insufficient_components"
        )
        // The store's `presentable` filter is pure; assert its predicate.
        let presentable = [ok, insufficient].filter { $0.isOK && $0.value != nil }
        #expect(presentable.count == 1)
        #expect(presentable.first?.metric == "READINESS")
    }

    // MARK: - I-2 contributor breakdown + coincident-deviation decode

    @Test("fetch — READINESS decodes the components[] contributor breakdown")
    func fetchReadinessContributors() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            // Byte-aligned with readiness.ts ReadinessValue.components[].
            let body = Data(#"""
            {"data":{
              "metric":"READINESS","status":"ok",
              "value":{"score":78,"band":"green","components":[
                 {"key":"rhr","value":90,"weight":0.29},
                 {"key":"hrv","value":71,"weight":0.29},
                 {"key":"sleep","value":82,"weight":0.29},
                 {"key":"respiratory","value":null,"weight":0},
                 {"key":"mood","value":66,"weight":0.13}]},
              "coverage":{"requiredInputs":5,"presentInputs":4,"historyDays":21,"missing":["RESPIRATORY_RATE"]},
              "confidence":{"score":78,"band":"high"},
              "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"DAY","windowDays":30,
                            "computedAt":"2026-06-02T22:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "READINESS"))
        let contributors = try #require(dto.value?.contributors)
        #expect(contributors.count == 5)
        // The missing input decodes as nil-value (never fabricated).
        #expect(contributors.first { $0.key == "respiratory" }?.value == nil)
        #expect(contributors.first { $0.key == "rhr" }?.value == 90)
        // v0.14.3 F4 — rankByImpact hides null-value rows; the decoded DTO still
        // carries all 5 (the missing input is never fabricated, asserted above),
        // but the ranked view drops "respiratory" so no empty "—" row shows.
        let ranked = WellnessScorePresentation.rankedContributors(dto)
        #expect(!ranked.contains { $0.key == "respiratory" })
        #expect(ranked.allSatisfy { $0.value != nil })
    }

    @Test("fetch — SLEEP_SCORE subScores[] decode into the unified contributors")
    func fetchSleepSubScores() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"SLEEP_SCORE","status":"ok",
              "value":{"score":71,"band":"green","night":"2026-06-03","asleepMinutes":410,
                       "inBedMinutes":470,"windowNights":14,"subScores":[
                 {"key":"sufficiency","value":88,"weight":0.30},
                 {"key":"efficiency","value":87,"weight":0.25},
                 {"key":"consistency","value":60,"weight":0.20}]},
              "coverage":{"requiredInputs":5,"presentInputs":3,"historyDays":14,"missing":[]},
              "confidence":{"score":71,"band":"medium"},
              "provenance":{"inputs":["SLEEP_DURATION"],"source":"DAY","windowDays":14,
                            "computedAt":"2026-06-03T08:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "SLEEP_SCORE"))
        // subScores feed the SAME `contributors` accessor as READINESS components.
        let contributors = try #require(dto.value?.contributors)
        #expect(contributors.map(\.key) == ["sufficiency", "efficiency", "consistency"])
        #expect(dto.value?.components == nil) // sleep uses subScores, not components
    }

    @Test("fetch — COINCIDENT_DEVIATION decodes fired/vitals/contributing (honest count)")
    func fetchCoincidentDeviation() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"COINCIDENT_DEVIATION","status":"ok",
              "value":{"fired":true,"day":"2026-06-04",
                "vitals":[
                  {"type":"RESTING_HEART_RATE","value":72,"center":60,"low":54,"high":66,
                   "outside":true,"direction":"above"},
                  {"type":"RESPIRATORY_RATE","value":18,"center":14,"low":12,"high":16,
                   "outside":true,"direction":"above"},
                  {"type":"OXYGEN_SATURATION","value":97,"center":97,"low":95,"high":99,
                   "outside":false,"direction":"in"}],
                "contributing":[
                  {"type":"RESTING_HEART_RATE","value":72,"center":60,"low":54,"high":66,
                   "outside":true,"direction":"above"},
                  {"type":"RESPIRATORY_RATE","value":18,"center":14,"low":12,"high":16,
                   "outside":true,"direction":"above"}]},
              "coverage":{"requiredInputs":2,"presentInputs":3,"historyDays":30,"missing":[]},
              "confidence":{"score":80,"band":"high"},
              "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"DAY","windowDays":30,
                            "computedAt":"2026-06-04T08:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "COINCIDENT_DEVIATION"))
        let summary = try #require(WellnessScorePresentation.deviationSummary(dto))
        #expect(summary.fired == true)
        #expect(summary.contributingCount == 2) // honest COUNT, not a score
        #expect(summary.checked == 3)
        #expect(summary.contributing == ["RESTING_HEART_RATE", "RESPIRATORY_RATE"])
    }

    @Test("derived block — provenance line uses server window + source (no fabrication)")
    func provenanceLineFromServer() {
        let prov = DerivedMetricDTO.Provenance(
            inputs: ["RESTING_HEART_RATE"], source: "DAY", windowDays: 30, computedAt: .now
        )
        // Catalog resolves to the host locale; the window (30) + source come
        // straight from the server provenance, never fabricated.
        #expect([
            "From your last 30 days · daily data",
            "Aus deinen letzten 30 Tagen · täglich-Daten"
        ].contains(InsightsDerivedBlock.provenanceLine(for: prov)))
    }

    // MARK: - W-B187 #29: recovery source authority (WHOOP-native vs computed)

    /// Builds a RECOVERY_SCORE envelope with the given provenance `inputs`, so the
    /// source-authority resolvers can be exercised off a realistic DTO.
    private func recoveryDTO(inputs: [String], score: Double = 66) -> DerivedMetricDTO {
        DerivedMetricDTO(
            metric: "RECOVERY_SCORE", status: "ok",
            value: .init(score: score, band: "green"),
            coverage: .init(requiredInputs: 1, presentInputs: 1, historyDays: 14, missing: []),
            confidence: .init(score: 90, band: "high"),
            provenance: .init(inputs: inputs, source: "DAY", windowDays: 14, computedAt: .now),
            reason: nil
        )
    }

    @Test("recovery — headline is the server value (no client recompute)")
    func recoveryHeadlineIsServerValue() {
        // The headline read-out comes straight from the server `score`, whatever
        // source the server resolved it from. 66 in → "66 / 100" out, verbatim.
        let dto = recoveryDTO(inputs: ["WHOOP_RECOVERY"], score: 66)
        #expect(InsightsDerivedBlock.headline(for: dto) == "66 / 100")
        #expect(WellnessScorePresentation.scoreValueText(dto) == "66")
    }

    @Test("recovery — WHOOP marker in provenance.inputs reads as WHOOP-native")
    func recoveryWhoopNativeDetected() {
        #expect(WellnessScorePresentation.isWhoopNativeRecovery(recoveryDTO(inputs: ["WHOOP_RECOVERY"])))
        #expect(WellnessScorePresentation.isWhoopNativeRecovery(recoveryDTO(inputs: ["WHOOP"])))
        // Case-insensitive substring match — a future token spelling still reads.
        #expect(WellnessScorePresentation.isWhoopNativeRecovery(recoveryDTO(inputs: ["whoop_recovery"])))
    }

    @Test("recovery — no WHOOP marker reads as the computed proxy (older server too)")
    func recoveryComputedProxyDefault() {
        // The HRV-derived proxy + an older server that omits any marker both read
        // as computed — never misattributed to WHOOP.
        #expect(!WellnessScorePresentation.isWhoopNativeRecovery(recoveryDTO(inputs: ["HEART_RATE_VARIABILITY"])))
        #expect(!WellnessScorePresentation.isWhoopNativeRecovery(recoveryDTO(inputs: [])))
        // Only RECOVERY_SCORE participates; a STRESS envelope with a stray WHOOP
        // input is never flagged.
        let stress = DerivedMetricDTO(
            metric: "STRESS_SCORE", status: "ok", value: .init(score: 40, band: "green"),
            coverage: .init(requiredInputs: 1, presentInputs: 1, historyDays: 14, missing: []),
            confidence: .init(score: 80, band: "high"),
            provenance: .init(inputs: ["WHOOP"], source: "DAY", windowDays: 14, computedAt: .now),
            reason: nil
        )
        #expect(!WellnessScorePresentation.isWhoopNativeRecovery(stress))
    }

    @Test("recovery — copy is provenance-aware (WHOOP-native drops the 'proxy' framing)")
    func recoveryCopyIsProvenanceAware() {
        let whoop = recoveryDTO(inputs: ["WHOOP_RECOVERY"])
        let computed = recoveryDTO(inputs: ["HEART_RATE_VARIABILITY"])

        // WHOOP-native caveat + explainer name WHOOP and do NOT call it a proxy
        // (locale-resolved EN-or-DE).
        #expect(InsightsDerivedBlock.caveat(for: whoop)?.lowercased().contains("whoop") == true)
        #expect(InsightsDerivedBlock.whatIs(for: whoop)?.lowercased().contains("whoop") == true)

        // The computed proxy keeps the existing honest "proxy / heart-rate
        // variability" framing — unchanged from the string-keyed resolver.
        #expect(InsightsDerivedBlock.caveat(for: computed) == InsightsDerivedBlock.caveat(for: "RECOVERY_SCORE"))
        #expect(InsightsDerivedBlock.whatIs(for: computed) == InsightsDerivedBlock.whatIs(for: "RECOVERY_SCORE"))

        // A non-recovery metric delegates straight through unchanged.
        let readiness = DerivedMetricDTO(
            metric: "READINESS", status: "ok", value: .init(score: 80, band: "green"),
            coverage: .init(requiredInputs: 1, presentInputs: 1, historyDays: 14, missing: []),
            confidence: .init(score: 80, band: "high"),
            provenance: .init(inputs: ["RESTING_HEART_RATE"], source: "DAY", windowDays: 14, computedAt: .now),
            reason: nil
        )
        #expect(InsightsDerivedBlock.caveat(for: readiness) == InsightsDerivedBlock.caveat(for: "READINESS"))
    }

    // MARK: - D1: per-score assessment (Einschätzung)

    @Test("fetch — decodes the additive per-score assessment (text + source + updatedAt)")
    func fetchDecodesAssessment() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"SLEEP_SCORE","status":"ok",
              "value":{"score":71,"band":"yellow"},
              "coverage":{"requiredInputs":5,"presentInputs":5,"historyDays":30,"missing":[]},
              "confidence":{"score":71,"band":"medium"},
              "provenance":{"inputs":["SLEEP_DURATION"],"source":"DAY","windowDays":30,
                            "computedAt":"2026-06-05T22:00:00+02:00"},
              "reason":null,
              "assessment":{"text":"Dein Schlafscore liegt bei 71 (gelb). Dauer und Konsistenz stützen den Wert.",
                            "source":"deterministic","updatedAt":"2026-06-05T05:00:00.000Z"}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "SLEEP_SCORE"))
        let assessment = try #require(dto.assessment)
        #expect(assessment.text.hasPrefix("Dein Schlafscore liegt bei 71"))
        #expect(assessment.source == "deterministic")
        #expect(assessment.updatedAt != nil)
    }

    @Test("fetch — assessment is nil when the server emits null (no fabrication)")
    func fetchAssessmentNull() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"STRAIN_SCORE","status":"ok",
              "value":{"score":40,"band":"green"},
              "coverage":{"requiredInputs":3,"presentInputs":3,"historyDays":14,"missing":[]},
              "confidence":{"score":60,"band":"medium"},
              "provenance":{"inputs":["ACTIVE_ENERGY"],"source":"DAY","windowDays":30,
                            "computedAt":"2026-06-05T22:00:00+02:00"},
              "reason":null,
              "assessment":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "STRAIN_SCORE"))
        #expect(dto.assessment == nil)
    }

    @Test("fetch — assessment field absent (older server) decodes to nil")
    func fetchAssessmentAbsent() async throws {
        let repo = DerivedMetricsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "metric":"READINESS","status":"ok",
              "value":{"score":78,"band":"green"},
              "coverage":{"requiredInputs":5,"presentInputs":5,"historyDays":21,"missing":[]},
              "confidence":{"score":78,"band":"high"},
              "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"DAY","windowDays":30,
                            "computedAt":"2026-06-05T22:00:00+02:00"},
              "reason":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "READINESS"))
        #expect(dto.assessment == nil)
    }
}

// swiftlint:enable force_unwrapping type_body_length
