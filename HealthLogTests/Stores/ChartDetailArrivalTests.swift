// 14-01 (A2) — the value and the chart must arrive together.
//
// The operator's A2 is "Zahlenwerte kommen deutlich später als ihre Grafik".
// On a series-backed metric detail the store publishes the series first
// (`ChartDetailStore+Loading.swift`, the `seriesAsync` await) and only after two
// further best-effort roundtrips — findings, then the metric summary — awaits
// the measurements page that settles `latestRawMeasurement`, `recentInRange`
// and `dataState`. The chart short-circuits on `series` alone, so it paints at
// once; every dataState-gated number block above it (Min/Ø/Max/Median, the
// headline's raw-latest refinement) waits for two requests it does not depend
// on, and then pushes the chart down when it lands.
//
// The two roundtrips are already concurrent with the page — nothing here asks
// for more requests, and nothing here may add one. What the fix moves is the
// ORDER of the awaits, so the value furniture settles with the chart.
//
// Drives the REAL store over the REAL `APIClient` on a session-scoped
// `MockURLProtocolSession` (09-13 discipline, opaque `<token>.mock.invalid`
// addressing), because the defect lives in the ordering of the fan-out's
// awaits and not in any single one of them.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Chart detail arrival (14-01)", .serialized)
    @MainActor
    struct ChartDetailArrivalTests {
        /// How long the two best-effort insight roundtrips are parked for. Long
        /// enough that the window between "the chart can paint" and "the page
        /// settled" is unmistakable, short enough that the suite stays quick.
        private nonisolated static let insightsDelay: TimeInterval = 0.30

        /// Anchored on the live clock, not a frozen epoch: the store's own
        /// range cutoff is `Date.now - range`, so a fixture pinned to a past
        /// date lands `.empty(.outsideRange)` and would be measuring the
        /// calendar rather than the arrival order.
        private let now = Date.now

        // MARK: - Harness

        private func makeAPI(_ session: MockURLProtocolSession) -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
        }

        private func makeStore(
            kind: MetricKind,
            session: MockURLProtocolSession
        ) throws -> ChartDetailStore {
            let api = makeAPI(session)
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return ChartDetailStore(
                kind: kind,
                measurementsRepo: repo,
                insightsRepo: MetricInsightsRepository(api: api),
                resolveLocale: { "de" }
            )
        }

        private func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        /// The wire body of `/api/measurements/series` for `kind`, three points
        /// inside the 30-day window so `chartPoints.count >= 2` holds.
        private func seriesBody(kind: MetricKind) -> Data {
            let points = (1 ... 3).map { index -> String in
                let at = iso(now.addingTimeInterval(-Double(index) * 86400))
                return #"{"id":"s\#(index)","at":"\#(at)","value":\#(80.0 + Double(index)),"secondary":null}"#
            }
            let body = #"{"data":{"kind":"\#(kind.rawValue)","points":[\#(points.joined(separator: ","))],"#
                + #""stats":{"mean":82,"min":81,"max":83,"stdDev":1,"count":3},"unit":"kg"}}"#
            return Data(body.utf8)
        }

        /// The wire body of the `/api/measurements` page — one row, the true
        /// latest raw reading, deliberately different from every series bucket
        /// so the refinement is observable.
        private func pageBody(type: String, value: Double) -> Data {
            let at = iso(now.addingTimeInterval(-3600))
            let row = #"{"id":"m1","type":"\#(type)","value":\#(value),"measuredAt":"\#(at)","source":"MANUAL"}"#
            return Data(#"{"data":{"measurements":[\#(row)]}}"#.utf8)
        }

        /// Installs the arrival shape under test: the series and the page both
        /// answer at once, the two insight roundtrips are parked. Whatever the
        /// screen can render when the series lands is what the operator sees
        /// first.
        private func installArrivalHandlers(
            _ session: MockURLProtocolSession,
            kind: MetricKind,
            type: String,
            latest: Double
        ) {
            let series = seriesBody(kind: kind)
            let page = pageBody(type: type, value: latest)
            session.install { request in
                let path = request.url?.path ?? ""
                let ok = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                if path.hasPrefix("/api/insights") {
                    // The URL-loading system owns this thread; the test's actor
                    // is free while the two best-effort roundtrips are parked.
                    Thread.sleep(forTimeInterval: Self.insightsDelay)
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"slow"}"#.utf8)
                    )
                }
                if path.hasPrefix("/api/measurements/series") {
                    return (ok, series)
                }
                if path.hasPrefix("/api/measurements") {
                    return (ok, page)
                }
                return (ok, Data(#"{"data":null}"#.utf8))
            }
        }

        /// Polls `condition` on the main actor against a real deadline. A yield
        /// loop would be racing the URL-loading thread rather than waiting for
        /// it, which is how a timing test becomes a flake.
        private func settle(
            within seconds: Double = 3.0,
            _ condition: @MainActor () -> Bool
        ) async -> Bool {
            let steps = Int(seconds * 200)
            for _ in 0 ..< steps {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return condition()
        }

        // MARK: - 1) the value block may not trail the chart

        /// The moment the chart can paint, the number blocks above it must be
        /// settled too. Today they are not: `dataState` and
        /// `latestRawMeasurement` are assigned only after the findings and
        /// summary roundtrips return, so `StatsRow` (Min/Ø/Max/Median, gated on
        /// `dataState.hasValue`) and the headline's raw-latest refinement land
        /// two requests late — above the chart, pushing it down.
        @Test("Der Kopfwert kommt mit der Grafik, nicht zwei Roundtrips später")
        func headlinePublishesWithTheSeries() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installArrivalHandlers(session, kind: .weight, type: "WEIGHT", latest: 79.0)
            let store = try makeStore(kind: .weight, session: session)

            let load = Task { await store.load() }
            let chartCanPaint = await settle { store.chartPoints.count >= 2 }
            #expect(chartCanPaint, "the series must reach the chart for this test to say anything")

            // Read the two gates the number blocks above the chart hang on, in
            // the same main-actor turn the chart became renderable in.
            let valueSettledWithChart = store.dataState.hasValue && store.latestRawMeasurement != nil
            #expect(
                valueSettledWithChart,
                "EXPECTED_RED: the headline value arrives two roundtrips after the chart"
            )

            await load.value
            // The data was never the problem — only when it was published.
            #expect(store.latestRawMeasurement != nil)
            #expect(store.dataState.hasValue)
        }

        // MARK: - 2) refinement is one-directional (control)

        /// A value, once rendered, may be replaced by a fresher value — never by
        /// a placeholder. The page's raw latest (79.0) deliberately disagrees
        /// with every series bucket, so the refinement is observable; what may
        /// not happen is an intermediate emission with no headline at all.
        @Test("Die Verfeinerung ersetzt den Wert, sie löscht ihn nie")
        func refinementNeverBlanksTheHeadline() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installArrivalHandlers(session, kind: .weight, type: "WEIGHT", latest: 79.0)
            let store = try makeStore(kind: .weight, session: session)

            let load = Task { await store.load() }
            let headlineArrived = await settle { store.latestPoint != nil }
            #expect(headlineArrived, "a headline must appear before it can be refined")

            // From here on it may only ever be replaced, never withdrawn.
            var blanked = false
            for _ in 0 ..< 200 {
                if store.latestPoint == nil {
                    blanked = true
                    break
                }
                if load.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            await load.value
            #expect(blanked == false, "no emission may withdraw an already-rendered headline")
            #expect(store.latestPoint != nil)
            #expect(store.latestPoint?.value == 79.0, "the settled headline is the true latest raw reading")
        }

        // MARK: - 3) the out-of-range tile states its reason (control)

        /// The second face of A2 in the research digest: a dashboard tile that
        /// renders a sparkline beside a permanent em-dash. The em-dash is
        /// correct — the data really is outside the window — and since
        /// v0.14.8 AUDIT-HOME M5 the tile also says so. Pinned here rather than
        /// re-fixed: 14-01's plan expected this to be red, and it is not.
        @Test("Die Außer-Reichweite-Kachel sagt, warum sie keine Zahl zeigt")
        func outsideRangeTileStatesWhy() {
            let metric = DashboardMetric(
                id: MetricKind.walkingSpeed.rawValue,
                kind: .walkingSpeed,
                title: "Geschwindigkeit",
                latestValue: nil,
                secondaryValue: nil,
                unit: "m/s",
                trend: .flat,
                sparkline: [1.21, 1.22, 1.23],
                updatedAt: nil
            )
            let display = MetricDisplay(
                metric: metric,
                dataState: .empty(reason: .outsideRange(latestAt: now.addingTimeInterval(-21 * 86400))),
                now: now,
                calendar: .current
            )
            #expect(display.valueText == "—")
            #expect(display.isEmptyForDisplay)
            #expect(display.secondaryLine != nil, "an em-dash beside a sparkline must state its reason")
            #expect(display.secondaryLine?.isEmpty == false)
        }

        // MARK: - 4) the already-correct path stays correct (control)

        /// A no-series kind (walking speed: absent from both `kindSupportsSeries`
        /// lists) draws its chart from the SAME measurements page that carries
        /// its headline, so the two cannot separate. Pinned so the reordering
        /// cannot regress the path that already behaves.
        @Test("Eine Metrik ohne Serien-Endpunkt liefert Wert und Chart gemeinsam")
        func nonSeriesMetricPublishesValueAndChartTogether() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let page = pageBody(type: "WALKING_SPEED", value: 1.23)
            let extra = Data(#"{"data":{"measurements":[]}}"#.utf8)
            session.install { request in
                let path = request.url?.path ?? ""
                let ok = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                if path.hasPrefix("/api/insights") {
                    Thread.sleep(forTimeInterval: Self.insightsDelay)
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"slow"}"#.utf8)
                    )
                }
                if path.hasPrefix("/api/measurements/series") {
                    // The kind has no series endpoint; the store must not ask.
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                        extra
                    )
                }
                if path.hasPrefix("/api/measurements") {
                    return (ok, page)
                }
                return (ok, Data(#"{"data":null}"#.utf8))
            }
            let store = try makeStore(kind: .walkingSpeed, session: session)

            let load = Task { await store.load() }
            // Whichever of the two appears first, the other must be there in the
            // same turn — they come out of one publication block.
            let anythingArrived = await settle {
                store.chartPoints.isEmpty == false || store.latestRawMeasurement != nil
            }
            #expect(anythingArrived)
            #expect(store.latestRawMeasurement != nil, "the headline lands with the chart's own rows")
            #expect(store.chartPoints.isEmpty == false)
            await load.value
            #expect(store.latestPoint?.value == 1.23)
        }
    }

#endif
