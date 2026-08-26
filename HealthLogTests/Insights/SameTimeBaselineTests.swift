import Foundation
@testable import HealthLog
import Synchronization
import Testing

// `file_length` is disabled here by Plan 09-11, with its reason (the rule's
// warning threshold is 600 and this file is past it since the session
// migration). The migration costs three lines per test — construct the session,
// `defer { session.invalidate() }`, take the seam — across 21 wire-contract
// cases, plus one permanent transport-ownership case. Splitting the suite was
// rejected: every case here shares `okJSON`, `okBody` and `gatedBody`, so two
// files would duplicate those fixtures and let the halves drift, which is a
// worse outcome for a document whose whole job is to pin one server contract
// byte for byte. Refreshing the SwiftLint baseline was rejected outright — a
// baseline that grows to accommodate new code is not a ratchet.
// swiftlint:disable force_unwrapping type_body_length file_length

/// File-scope on purpose: a `@Sendable` handler closure runs on the URL-loading
/// queue, and keeping the response helper out of the suite keeps it callable
/// from there without isolation ceremony.
private func respond(_ req: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
    let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (http, Data(json.utf8))
}

/// **CU-30 / C5.** Locks the Same-Time-Baseline wire contract
/// (`GET /api/insights/derived?metric=SAME_TIME_BASELINE&type=<MeasurementType>`,
/// server v1.34.0, `src/lib/insights/derived/same-time-baseline.ts`) and the
/// digest rail card it feeds.
///
/// The suite pins the two corrections the wire research turned up against the
/// server source, both of which contradict a doc comment / the brief:
///
///  1. **`asOfHour` is really 0…22, never 23** — it is
///     `hourOfDayForUserTz(now, tz) - 1` over a 0…23 source, so the curves are
///     1…23 points long and a client that hard-plans 24 points is wrong.
///  2. **`percentOfTypical` can be `null` on an `ok` arm** — exactly when the
///     typical total at that hour is zero (normal at 05:00). Everything else in
///     `value` is fully populated, so a missing percentage must not read as
///     "metric unavailable".
///
/// Real `APIClient` over ``MockURLProtocol`` throughout (never a mock server).
///
/// ## Issue #82 / Plan 09-11 — the transport is session-owned
///
/// Every response handler below is installed on a ``MockURLProtocolSession``
/// that its own test retains, and that session's `baseURL` **and** configuration
/// are what build that test's `APIClient`. This file assigns the mock's
/// process-global handler slot zero times, so a parallel or later suite cannot
/// replace a handler between our install and our request. `.serialized` is kept
/// for the ordering it gives inside the suite, not for isolation it never
/// provided.
@Suite("Same-Time-Baseline — Wire-Vertrag, gegatete Arme, Rail-Schlüssel", .serialized)
struct SameTimeBaselineTests {
    /// The transport seam (issue #82 / Plan 09-11). Both halves come from the
    /// caller's retained session, so every request this client makes is answered
    /// by that session's handler or by nothing at all.
    ///
    /// `baseURL: session.baseURL` is the load-bearing half, and it is not
    /// interchangeable with the configuration. `APIClient.init` assigns
    /// `config.httpAdditionalHeaders` **wholesale** on the configuration object
    /// it is handed, before its `URLSession` exists, so the session token is gone
    /// by the time the first request is built. Keeping the old hard-coded host
    /// here while passing `session.configuration` would leave all sixteen
    /// handlers below installed and never reached, answered instead by the legacy
    /// process-global slot.
    /// `MockURLProtocolIsolationTests.aSessionConfigurationAloneDoesNotMigrateAClient`
    /// pins exactly that trap. `req.targets("/api/…")` is unaffected — only the
    /// host moved.
    private func makeAPI(session: MockURLProtocolSession) -> APIClient {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.12.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
    }

    /// A byte-shaped `ok` envelope. Defaults mirror
    /// `same-time-baseline.ts:240-259` at hour 9 with a 10-point curve pair.
    private func okBody(
        type: String = "ACTIVITY_STEPS",
        asOfHour: Int = 9,
        percentOfTypical: String = "112",
        band: String = "above",
        todayCurve: String = "[0,0,0,0,0,120,900,2400,3800,5200]",
        typicalCurve: String = "[0,0,0,0,10,240,1100,2100,3300,4650.5]"
    ) -> Data {
        Data(okJSON(
            type: type,
            asOfHour: asOfHour,
            percentOfTypical: percentOfTypical,
            band: band,
            todayCurve: todayCurve,
            typicalCurve: typicalCurve
        ).utf8)
    }

    private func okJSON(
        type: String = "ACTIVITY_STEPS",
        asOfHour: Int = 9,
        percentOfTypical: String = "112",
        band: String = "above",
        todayCurve: String = "[0,0,0,0,0,120,900,2400,3800,5200]",
        typicalCurve: String = "[0,0,0,0,10,240,1100,2100,3300,4650.5]"
    ) -> String {
        """
        {"data":{
          "metric":"SAME_TIME_BASELINE","status":"ok",
          "value":{
            "type":"\(type)","unit":"count","timezone":"Europe/Berlin",
            "dateKey":"2026-07-31","asOfHour":\(asOfHour),
            "todayValue":5200,"typicalValue":4650.5,
            "typicalLow":3900,"typicalHigh":5400,
            "delta":549.5,"percentOfTypical":\(percentOfTypical),
            "band":"\(band)",
            "todayCurve":\(todayCurve),
            "typicalCurve":\(typicalCurve),
            "baselineDays":21,"windowDays":28
          },
          "coverage":{"requiredInputs":1,"presentInputs":1,"historyDays":21,"missing":[]},
          "confidence":{"score":82,"band":"high"},
          "provenance":{"inputs":["ACTIVITY_STEPS"],"source":"live","windowDays":28,
                        "computedAt":"2026-07-31T10:00:00+02:00"},
          "reason":null,"assessment":null
        },"error":null}
        """
    }

    private func gatedBody(reason: String, historyDays: Int, missing: String = "[]") -> Data {
        Data("""
        {"data":{
          "metric":"SAME_TIME_BASELINE","status":"insufficient",
          "value":null,
          "coverage":{"requiredInputs":1,"presentInputs":\(historyDays > 0 ? 1 : 0),
                      "historyDays":\(historyDays),"missing":\(missing)},
          "confidence":null,
          "provenance":{"inputs":[],"source":"\(historyDays > 0 ? "live" : "none")",
                        "windowDays":28,"computedAt":"2026-07-31T10:00:00+02:00"},
          "reason":"\(reason)","assessment":null
        },"error":null}
        """.utf8)
    }

    // MARK: - The `ok` arm

    @Test("ok-Arm — alle 16 value-Felder dekodieren in die typisierte Projektion")
    func decodesOkArm() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            let body = okBody()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetchSameTimeBaseline(type: .activitySteps))
        #expect(dto.isOK)
        #expect(dto.sameTimeBaselineGate == nil)

        let baseline = try #require(dto.sameTimeBaseline)
        #expect(baseline.type == .activitySteps)
        #expect(baseline.unit == "count")
        // "count" is a technical placeholder, not something to paint next to a
        // number — steps carry no display unit.
        #expect(baseline.displayUnit.isEmpty)
        #expect(baseline.timezone == "Europe/Berlin")
        #expect(baseline.dateKey == "2026-07-31")
        #expect(baseline.asOfHour == 9)
        #expect(baseline.todayValue == 5200)
        // NOT re-rounded: a median of integers legitimately lands on x.5.
        #expect(baseline.typicalValue == 4650.5)
        #expect(baseline.typicalLow == 3900)
        #expect(baseline.typicalHigh == 5400)
        #expect(baseline.delta == 549.5)
        #expect(baseline.percentOfTypical == 112)
        #expect(baseline.band == .above)
        #expect(baseline.baselineDays == 21)
        #expect(baseline.windowDays == 28)
    }

    @Test("Einzelabruf sendet metric + type und umgeht den Tages-Cache")
    func singleRouteQuery() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        let seen = SeenURL()
        let calls = CallCounter()
        session.install { req in
            guard req.targets("/api/insights/derived") else { return respond(req, "{}") }
            calls.bump()
            seen.record(req.url)
            let body = okBody(type: "FLIGHTS_CLIMBED")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.fetchSameTimeBaseline(type: .flightsClimbed)
        // A recorded URL alone does not prove this suite was routed: `seen`
        // would stay `nil` for an unrouted request and `#require` would report
        // it as a missing query rather than a missing request. The count says
        // which.
        #expect(calls.value == 1)
        let url = try #require(seen.value)
        #expect(url.path == "/api/insights/derived")
        let query = url.query ?? ""
        #expect(query.contains("metric=SAME_TIME_BASELINE"))
        #expect(query.contains("type=FLIGHTS_CLIMBED"))
    }

    @Test("Kurven-Invariante — beide Kurven haben exakt asOfHour + 1 Punkte, indexgleich")
    func curveLengthInvariant() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            let body = okBody()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let baseline = try #require(try await repo.fetchSameTimeBaseline()?.sameTimeBaseline)
        #expect(baseline.todayCurve.count == baseline.asOfHour + 1)
        #expect(baseline.typicalCurve.count == baseline.asOfHour + 1)
        #expect(baseline.curvesAreAligned)

        let points = baseline.curvePoints
        #expect(points.count == 10)
        #expect(points.first?.hour == 0)
        #expect(points.last?.hour == 9)
        // Index alignment: hour h reads BOTH curves at index h.
        #expect(points.last?.today == 5200)
        #expect(points.last?.typical == 4650.5)
        // Cumulative curves are monotonically non-decreasing.
        #expect(zip(baseline.todayCurve, baseline.todayCurve.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(zip(baseline.typicalCurve, baseline.typicalCurve.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Korrektur 1 — asOfHour 22 ist der Höchstwert: 23 Punkte, nie 24")
    func asOfHourMaximumIsTwentyTwo() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        let curve = (0 ... 22).map { String($0 * 400) }.joined(separator: ",")
        session.install { req in
            let body = okBody(
                asOfHour: 22,
                todayCurve: "[\(curve)]",
                typicalCurve: "[\(curve)]"
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let baseline = try #require(try await repo.fetchSameTimeBaseline()?.sameTimeBaseline)
        #expect(baseline.asOfHour == 22)
        #expect(baseline.todayCurve.count == 23)
        #expect(baseline.curvesAreAligned)
        #expect(baseline.curvePoints.count == 23)
    }

    @Test("Fehlausgerichtete Kurven — Zahlen bleiben, der Chart entfällt still")
    func misalignedCurvesDropTheChartOnly() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            // A hypothetical future shape whose curves no longer match asOfHour.
            let body = okBody(todayCurve: "[0,100,200]", typicalCurve: "[0,90,180]")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let baseline = try #require(try await repo.fetchSameTimeBaseline()?.sameTimeBaseline)
        #expect(!baseline.curvesAreAligned)
        #expect(baseline.curvePoints.isEmpty)
        // The card still has everything it needs to state the standing.
        #expect(baseline.todayValue == 5200)
        #expect(baseline.band == .above)
    }

    @Test("Korrektur 2 — percentOfTypical null auf einem ok-Arm lässt alles andere intakt")
    func nullPercentOnOkArm() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            // 05:00 shape: the typical total at this hour is zero, so the ratio
            // is undefined — NOT a hundred percent and NOT a failure.
            let body = okBody(
                asOfHour: 4,
                percentOfTypical: "null",
                band: "above",
                todayCurve: "[0,0,0,0,80]",
                typicalCurve: "[0,0,0,0,0]"
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetchSameTimeBaseline())
        // Still the ok arm — the gate projection must stay empty.
        #expect(dto.isOK)
        #expect(dto.sameTimeBaselineGate == nil)

        let baseline = try #require(dto.sameTimeBaseline)
        #expect(baseline.percentOfTypical == nil)
        // Everything else is fully populated.
        #expect(baseline.band == .above)
        #expect(baseline.todayValue == 5200)
        #expect(baseline.delta == 549.5)
        #expect(baseline.curvesAreAligned)
        #expect(baseline.curvePoints.count == 5)
    }

    @Test("typicalLow/High dürfen auf typicalValue zusammenfallen, wenn kein Band gebildet wurde")
    func collapsedBandStillDecodes() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            var json = okJSON()
            json = json.replacingOccurrences(of: "\"typicalLow\":3900", with: "\"typicalLow\":4650.5")
            json = json.replacingOccurrences(of: "\"typicalHigh\":5400", with: "\"typicalHigh\":4650.5")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
        let baseline = try #require(try await repo.fetchSameTimeBaseline()?.sameTimeBaseline)
        #expect(baseline.typicalLow == baseline.typicalValue)
        #expect(baseline.typicalHigh == baseline.typicalValue)
    }

    // MARK: - The gated arms

    @Test("learning_usual_day — historyDays trägt den Zähler, kein Fehler", arguments: [0, 3, 13])
    func learningUsualDay(historyDays: Int) async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            let body = gatedBody(reason: "learning_usual_day", historyDays: historyDays)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetchSameTimeBaseline())
        // A gated envelope is a VALUE, not an absence — the repo returns it.
        #expect(!dto.isOK)
        #expect(dto.sameTimeBaseline == nil)
        #expect(dto.sameTimeBaselineGate == .learningUsualDay(historyDays: historyDays))
        #expect(dto.coverage.historyDays == historyDays)
        // "N von 14" is renderable from the envelope alone.
        #expect(SameTimeBaselineMetric.requiredHistoryDays == 14)
    }

    @Test("no_intraday_today — ehrliche Abwesenheit, keine Fehlerfläche")
    func noIntradayToday() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            // The permanent state of a Fitbit / Withings / Polar account: the
            // activity arrives as a daily total, there never was an intraday
            // stream. HTTP 200, not an error.
            let body = gatedBody(
                reason: "no_intraday_today",
                historyDays: 0,
                missing: "[\"ACTIVITY_STEPS\"]"
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetchSameTimeBaseline())
        #expect(dto.sameTimeBaselineGate == .noIntradayToday)
        #expect(dto.provenance.source == "none")
        #expect(dto.coverage.missing == ["ACTIVITY_STEPS"])
        #expect(dto.confidence == nil)
    }

    @Test("day_too_young und unsupported_baseline_type dekodieren ruhig")
    func remainingGates() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        for (reason, expected) in [
            ("day_too_young", SameTimeBaselineGate.dayTooYoung),
            ("unsupported_baseline_type", SameTimeBaselineGate.unsupportedType),
            ("not_implemented", SameTimeBaselineGate.notImplemented)
        ] {
            session.install { req in
                let body = gatedBody(reason: reason, historyDays: 0)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            let dto = try #require(try await repo.fetchSameTimeBaseline())
            #expect(dto.sameTimeBaselineGate == expected)
            #expect(dto.sameTimeBaselineGate?.reason == reason)
        }
    }

    @Test("Unbekannter gegateter Grund bleibt tolerant — derselbe ruhige Zustand")
    func unknownGateIsTolerated() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            let body = gatedBody(reason: "some_future_reason", historyDays: 7)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetchSameTimeBaseline())
        #expect(dto.sameTimeBaselineGate == .unknown("some_future_reason"))
        #expect(dto.sameTimeBaseline == nil)
    }

    @Test("Ein type ausserhalb der vier ist HTTP 200 mit unsupported_baseline_type, kein 422")
    func unsupportedTypeIsNotATransportError() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            let body = gatedBody(reason: "unsupported_baseline_type", historyDays: 0, missing: "[\"WEIGHT\"]")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(metric: "SAME_TIME_BASELINE", type: "WEIGHT", cached: false))
        #expect(dto.sameTimeBaselineGate == .unsupportedType)
        #expect(dto.coverage.missing == ["WEIGHT"])
    }

    @Test("404/422 → nil, die Fläche verschwindet lautlos", arguments: [404, 422])
    func routeAbsentMapsToNil(status: Int) async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":{"code":"not_found","message":"nope"}}"#.utf8)
            )
        }
        let result = try await repo.fetchSameTimeBaseline()
        #expect(result == nil)
    }

    // MARK: - The batch token

    @Test("Batch — der Typ reitet als Doppelpunkt-Suffix mit und keyt die Antwort")
    func batchTokenRoundTrip() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        let seen = SeenURL()
        let calls = CallCounter()
        session.install { req in
            guard req.targets("/api/insights/derived/batch") else { return respond(req, "{}") }
            calls.bump()
            seen.record(req.url)
            let inner = okJSON()
                .replacingOccurrences(of: "{\"data\":", with: "")
                .replacingOccurrences(of: ",\"error\":null}", with: "")
            let body = Data("""
            {"data":{"metrics":{"SAME_TIME_BASELINE:ACTIVITY_STEPS":\(inner)}},"error":null}
            """.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let token = SameTimeBaselineType.activitySteps.batchToken
        #expect(token == "SAME_TIME_BASELINE:ACTIVITY_STEPS")

        let results = await repo.fetchBatch([token])
        // `fetchBatch` returns an empty array for an unrouted request just as it
        // does for an empty envelope, so the count is what proves the batch route
        // was actually reached on this suite's own session.
        #expect(calls.value == 1)
        let url = try #require(seen.value)
        // The colon rides the query literally (it is a legal query character),
        // so the CSV the server parses is byte-identical to the token.
        #expect(url.query == "metrics=SAME_TIME_BASELINE:ACTIVITY_STEPS")
        #expect(results.count == 1)
        #expect(results.first?.sameTimeBaseline?.type == .activitySteps)
    }

    // MARK: - Supported types

    @Test("Die vier kumulativen Typen sind fest eingebaut — sie sind nicht entdeckbar")
    func supportedTypesArePinned() {
        // `GET /api/meta/capabilities` exposes derivedMetricIds and
        // vitalsBaselineTypes but NOT SAME_TIME_BASELINE_TYPES, so the set has
        // to live in the client.
        #expect(SameTimeBaselineType.allCases.map(\.rawValue) == [
            "ACTIVITY_STEPS",
            "ACTIVE_ENERGY_BURNED",
            "WALKING_RUNNING_DISTANCE",
            "FLIGHTS_CLIMBED"
        ])
        #expect(SameTimeBaselineType.default == .activitySteps)
        #expect(SameTimeBaselineType(rawValue: "WEIGHT") == nil)
    }

    @Test("Der Block hängt genau an den vier Typseiten und nur mit Cloud-Insights")
    func blockPlacementGate() {
        #expect(SameTimeBaselineBlock.supportedType(for: .steps, canShowCloudInsights: true) == .activitySteps)
        #expect(
            SameTimeBaselineBlock.supportedType(for: .activeEnergy, canShowCloudInsights: true)
                == .activeEnergyBurned
        )
        #expect(
            SameTimeBaselineBlock.supportedType(for: .distanceWalkingRunning, canShowCloudInsights: true)
                == .walkingRunningDistance
        )
        #expect(
            SameTimeBaselineBlock.supportedType(for: .flightsClimbed, canShowCloudInsights: true)
                == .flightsClimbed
        )
        // Every other metric page never constructs the block, so never reads.
        #expect(SameTimeBaselineBlock.supportedType(for: .pulse, canShowCloudInsights: true) == nil)
        #expect(SameTimeBaselineBlock.supportedType(for: .weight, canShowCloudInsights: true) == nil)
        // Pure server compute — absent in standalone / no-server.
        #expect(SameTimeBaselineBlock.supportedType(for: .steps, canShowCloudInsights: false) == nil)
    }

    // MARK: - The digest rail card

    @Test("Rail-Eintrag same_time_baseline dekodiert, ist abweisbar, Schlüssel ohne Stunde")
    func railItemDecodes() throws {
        let json = Data("""
        {"date":"2026-07-31","score":null,"worthALook":[
          {"kind":"same_time_baseline",
           "itemKey":"same_time_baseline:2026-07-31:ACTIVITY_STEPS",
           "title":"Heute mehr unterwegs als sonst um diese Zeit",
           "body":"5.200 Schritte bis 10 Uhr — üblich sind hier 4.700.",
           "status":"info",
           "actions":[{"labelKey":"daily.action.viewSteps","intent":"steps.view","href":"/insights/steps"}],
           "moduleKey":"insights"}
        ]}
        """.utf8)
        let digest = try JSONDecoder().decode(DailyDigest.self, from: json)
        let item = try #require(digest.worthALook.first)
        #expect(item.kindToken == .sameTimeBaseline)
        #expect(item.statusToken == .info)
        #expect(item.moduleKey == "insights")
        #expect(item.isDismissible)
        // The key deliberately omits the hour: the card's figures move through
        // the day, and an hourly key would undo a dismissal every hour.
        let key = try #require(item.itemKey)
        #expect(key == "same_time_baseline:2026-07-31:ACTIVITY_STEPS")
        #expect(key.split(separator: ":").count == 3)
        #expect(item.actions.first?.intent == "steps.view")
        // No number crosses the wire on the rail card — the figures are baked
        // into the server-localized title/body.
        #expect(!item.title.isEmpty)
    }

    @Test("Rail-Schlüssel wird identisch aus einer dekodierten Baseline gebildet")
    func railKeyFromBaseline() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        session.install { req in
            let body = okBody()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let baseline = try #require(try await repo.fetchSameTimeBaseline()?.sameTimeBaseline)
        #expect(baseline.railItemKey == "same_time_baseline:2026-07-31:ACTIVITY_STEPS")
        #expect(
            SameTimeBaseline.railItemKey(dateKey: "2026-01-05", type: .flightsClimbed)
                == "same_time_baseline:2026-01-05:FLIGHTS_CLIMBED"
        )
    }

    @Test("Ein Rail-Eintrag ohne itemKey ist nicht abweisbar")
    func railItemWithoutKeyIsNotDismissible() throws {
        let json = Data("""
        {"date":"2026-07-31","score":null,"worthALook":[
          {"kind":"same_time_baseline","title":"x","actions":[]}
        ]}
        """.utf8)
        let digest = try JSONDecoder().decode(DailyDigest.self, from: json)
        let item = try #require(digest.worthALook.first)
        #expect(item.kindToken == .sameTimeBaseline)
        #expect(!item.isDismissible)
    }

    // MARK: - Store

    @MainActor
    @Test("Store — gegateter Arm bleibt erhalten, Logout räumt auf, Wiederholung ist idempotent")
    func storeKeepsGatedArm() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        let store = DerivedInsightsStore(repo: repo)
        let calls = CallCounter()
        session.install { req in
            // Endpoint-scoped as well as session-owned. Session ownership stops
            // a foreign request from moving this counter; the predicate keeps
            // the assertion reading "the same-time route was called N times"
            // rather than "N requests happened".
            guard req.targets("/api/insights/derived") else { return respond(req, "{}") }
            calls.bump()
            let body = gatedBody(reason: "learning_usual_day", historyDays: 6)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.loadSameTimeBaseline()
        #expect(store.sameTimeBaselineSettled)
        #expect(store.sameTimeBaselineType == .activitySteps)
        // The gated envelope is KEPT — the card renders "learning", not nothing.
        #expect(store.sameTimeBaseline?.sameTimeBaselineGate == .learningUsualDay(historyDays: 6))
        #expect(calls.value == 1)

        // Idempotent per appearance: a re-mount does not re-hit the route.
        await store.loadSameTimeBaseline()
        #expect(calls.value == 1)
        // Switching type always re-reads.
        await store.loadSameTimeBaseline(type: .flightsClimbed)
        #expect(calls.value == 2)
        #expect(store.sameTimeBaselineType == .flightsClimbed)
        // Pull-to-refresh forces a read.
        await store.loadSameTimeBaseline(type: .flightsClimbed, force: true)
        #expect(calls.value == 3)

        store.clearOnLogout()
        #expect(store.sameTimeBaseline == nil)
        #expect(!store.sameTimeBaselineSettled)
        #expect(store.sameTimeBaselineType == .activitySteps)
    }

    @MainActor
    @Test("Store — SAME_TIME_BASELINE fährt nicht im Übersichts-Raster mit")
    func sameTimeBaselineIsNotOnTheOverviewGrid() {
        // It is per-type and must be read uncached, so it stays out of the
        // batched grid the overview paints.
        #expect(!DerivedInsightsStore.surfacedMetrics.contains(SameTimeBaselineMetric.id))
    }

    // MARK: - Transport ownership (issue #82 / Plan 09-11)

    @Test("a handler installed after ours cannot answer this suite's request")
    func aLaterInstallCannotAnswerThisSuite() async throws {
        // The failure this migration removes: a suite running in parallel
        // replaces the handler between our install and our request, so our
        // request is answered by a foreign closure and our counter stays at
        // zero. Here the foreign install happens *after* ours — deterministically
        // the losing order under one process-global slot — and must still not be
        // reached.
        let session = MockURLProtocolSession()
        let foreign = MockURLProtocolSession()
        defer {
            session.invalidate()
            foreign.invalidate()
        }
        let mine = CallCounter()
        let theirs = CallCounter()
        let body = okJSON()
        session.install { req in
            guard req.targets("/api/insights/derived") else { return respond(req, "{}") }
            mine.bump()
            return respond(req, body)
        }
        foreign.install { req in
            theirs.bump()
            return respond(req, "{}")
        }

        let repo = DerivedMetricsRepository(api: makeAPI(session: session))
        let dto = try await repo.fetchSameTimeBaseline(type: .activitySteps)

        // A positive count is the whole point: a decoded envelope proves the
        // *response* was right, and an unrouted request produces `nil` here just
        // as a 404 does. Only the count says the request reached this session.
        #expect(mine.value == 1, "EXPECTED_RED: SameTimeBaselineTests was not routed to its own session")
        #expect(theirs.value == 0)
        #expect(dto?.sameTimeBaseline?.type == .activitySteps)
    }

    // MARK: - Helpers

    /// Records the last URL the stub saw, across the `@Sendable` handler
    /// boundary. `Mutex` rather than an `NSLock` behind an unchecked-`Sendable`
    /// conformance (Plan 09-11): checked concurrency instead of a promise the compiler
    /// cannot verify. Since the migration it is reachable only through the
    /// session that owns it.
    private final class SeenURL: Sendable {
        private let stored = Mutex<URL?>(nil)

        var value: URL? {
            stored.withLock { $0 }
        }

        func record(_ url: URL?) {
            stored.withLock { $0 = url }
        }
    }

    private final class CallCounter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func bump() {
            count.withLock { $0 += 1 }
        }
    }
}

// swiftlint:enable force_unwrapping type_body_length file_length
