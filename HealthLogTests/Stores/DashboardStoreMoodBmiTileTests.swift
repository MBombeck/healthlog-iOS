import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// b241 — mood + BMI dashboard tile data fixes. Pins the three contracts the
/// b241 investigation nailed down (server confirmed 483 mood rows + 35 BMI rows,
/// yet both tiles rendered a headline with an empty series):
///
/// - **Fix 2 (mood tile state):** `.mood` is a `MoodEntry` (served by
///   `/api/mood-entries` via `MoodStore`), never a `Measurement`, so the
///   `/api/measurements` fan-out always derived `.empty(.noData)`. The tile
///   state now comes from the `MoodStore` snapshot instead — non-empty ⇒
///   `.ready`, empty ⇒ `.empty(.noData)`.
/// - **Fix 3 (BMI kind-scoped fallback):** `.bmi` has no `/series` endpoint, so
///   when the wide page misses its rows the tile stays `.empty`. A kind-scoped
///   `recent(kind: .bmi)` fallback (now resolving to `?type=BODY_MASS_INDEX`)
///   re-hydrates it to `.ready`.
/// - **BMI request shape + availability key** — `recent(kind: .bmi)` hits
///   `/api/measurements?type=BODY_MASS_INDEX` and its rows stay `.bmi`.
///
/// Real `APIClient` + `MockURLProtocol` stub throughout (never a mock server) —
/// per the PROJECT_GUIDE.md Outbox/schema-drift rule and the existing
/// `DashboardStoreSeriesFallbackTests` template.
@Suite("Dashboard mood + BMI tile data (b241)", .serialized)
struct DashboardStoreMoodBmiTileTests {
    @MainActor
    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
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

    private func emptyMeasurementsPayload() -> Data {
        Data("{\"data\":{\"measurements\":[]}}".utf8)
    }

    // MARK: - Fix 2 — mood tile state from MoodStore (pure)

    @Test("moodTileState: same-day entries collapse to one day-mean sample; newest is latest")
    func moodTileStateReadyWhenEntriesExist() {
        // Two entries on the SAME calendar day (pinned via Calendar.current
        // start-of-day + hour offsets so the bucketing is timezone-robust).
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let older = MoodEntry(id: "m1", recordedAt: day.addingTimeInterval(9 * 3600), score: 3)
        let newer = MoodEntry(id: "m2", recordedAt: day.addingTimeInterval(20 * 3600), score: 5)
        let state = DashboardStore.moodTileState(entries: [older, newer])
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready for a non-empty MoodStore, got \(String(describing: state))")
            return
        }
        // Newest RAW entry wins as the tile's latest value (not the day-mean).
        #expect(latest.id == "m2")
        #expect(latest.primaryValue == 5.0)
        // Both entries share a calendar day → one coarse sample at that day's mean.
        #expect(samples.count == 1)
        #expect(samples.first?.primaryValue == 4.0) // (3 + 5) / 2
    }

    @Test("moodTileState: N entries across M days collapse to M day-mean samples")
    func moodTileStateBucketsEntriesToDailyMeans() throws {
        // 20 entries over 5 days (4 per day). Each day's four scores are
        // [1, 2, 3, 4] in ascending-hour order → daily mean 2.5 every day; the
        // newest entry (last day, last slot) scores 4, distinct from the mean so
        // `latest` provably reflects the raw newest reading, not the bucket.
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let hours = [8, 12, 16, 20]
        let scores = [1, 2, 3, 4]
        var entries: [MoodEntry] = []
        for dayOffset in 0 ..< 5 {
            let dayStart = try #require(cal.date(byAdding: .day, value: dayOffset, to: base))
            for (slot, hour) in hours.enumerated() {
                let at = dayStart.addingTimeInterval(Double(hour) * 3600)
                entries.append(MoodEntry(id: "m-\(dayOffset)-\(slot)", recordedAt: at, score: scores[slot]))
            }
        }
        let state = DashboardStore.moodTileState(entries: entries.shuffled())
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(String(describing: state))")
            return
        }
        // 20 raw entries collapse to 5 day-buckets (not 20 raw points).
        #expect(samples.count == 5)
        // Every bucket is its day's arithmetic mean: (1 + 2 + 3 + 4) / 4 = 2.5.
        #expect(samples.allSatisfy { $0.primaryValue == 2.5 })
        // `latest` is the newest RAW entry (day 4, 20:00, score 4) — not 2.5.
        #expect(latest.id == "m-4-3")
        #expect(latest.primaryValue == 4.0)
    }

    @Test("moodTileState: empty entries → .empty(.noData)")
    func moodTileStateEmptyWhenNoEntries() {
        #expect(DashboardStore.moodTileState(entries: []) == .empty(reason: .noData))
    }

    // MARK: - b-mood-smooth — 3-day moving average over the day-means

    /// The window is a deliberate product decision (3, not 7 — see
    /// `moodSparklineSmoothingWindow`), so pin the number itself: a silent bump to
    /// 7 would flatten a sparse tile into a straight line.
    @Test("mood sparkline smoothing window is 3 days (tile-sized, not the chart's 7)")
    func moodSmoothingWindowIsThree() {
        #expect(DashboardStore.moodSparklineSmoothingWindow == 3)
    }

    /// The core of the operator's complaint: mood is an INTEGER 1–5 scale, so
    /// day-means alone stay jagged. The 3-day centred moving average must visibly
    /// shrink the peak-to-trough swing while keeping the point count, the ids and
    /// the timestamps intact (SwiftUI Charts identity + x-positions).
    @Test("smoothed: a 1/5/1/5/1 zig-zag loses amplitude but keeps count, ids and dates")
    func smoothedFlattensZigZag() throws {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let scores: [Double] = [1, 5, 1, 5, 1]
        let raw: [HealthLog.Measurement] = try scores.enumerated().map { offset, score in
            let day = try #require(cal.date(byAdding: .day, value: offset, to: base))
            return HealthLog.Measurement(id: "d\(offset)", kind: .mood, recordedAt: day, value: .scalar(score))
        }
        let smoothed = DashboardStore.smoothed(raw, window: 3)
        #expect(smoothed.count == raw.count)
        #expect(smoothed.map(\.id) == raw.map(\.id))
        #expect(smoothed.map(\.recordedAt) == raw.map(\.recordedAt))
        // Centred window, clamped at the ends:
        // [ (1+5)/2, (1+5+1)/3, (5+1+5)/3, (1+5+1)/3, (5+1)/2 ]
        let values = smoothed.map(\.primaryValue)
        #expect(values[0] == 3.0)
        #expect(abs(values[1] - 7.0 / 3.0) < 0.0001)
        #expect(abs(values[2] - 11.0 / 3.0) < 0.0001)
        #expect(abs(values[3] - 7.0 / 3.0) < 0.0001)
        #expect(values[4] == 3.0)
        // The swing collapses from the full 4-point scale span to well under half.
        let rawSpan = 4.0 // max(5) − min(1) of the input day-means
        let smoothedSpan = try #require(values.max()) - (try #require(values.min()))
        #expect(smoothedSpan < rawSpan / 2)
    }

    /// Below three points a 3-wide window would average every point into the same
    /// value and draw a flat line — erasing signal instead of calming it. Those
    /// series pass through untouched.
    @Test("smoothed: series with ≤ 2 points pass through unchanged")
    func smoothedPassesThroughShortSeries() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let one = [HealthLog.Measurement(id: "a", kind: .mood, recordedAt: base, value: .scalar(4))]
        let two = one
            + [HealthLog.Measurement(
                id: "b",
                kind: .mood,
                recordedAt: base.addingTimeInterval(86400),
                value: .scalar(1)
            )]
        #expect(DashboardStore.smoothed(one, window: 3).map(\.primaryValue) == [4])
        #expect(DashboardStore.smoothed(two, window: 3).map(\.primaryValue) == [4, 1])
    }

    @Test("smoothed: missing calendar days are not invented as adjacent observations")
    func smoothedDoesNotBridgeCalendarGaps() throws {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let offsetsAndScores = [(0, 1.0), (7, 5.0), (14, 1.0)]
        let sparse = try offsetsAndScores.enumerated().map { index, pair in
            let date = try #require(calendar.date(byAdding: .day, value: pair.0, to: base))
            return HealthLog.Measurement(
                id: "sparse-\(index)",
                kind: .mood,
                recordedAt: date,
                value: .scalar(pair.1)
            )
        }

        let result = DashboardStore.smoothed(sparse, window: 3)

        #expect(result.map(\.recordedAt) == sparse.map(\.recordedAt))
        #expect(result.map(\.primaryValue) == [1, 5, 1])
    }

    /// End to end through `moodTileState`: the smoothing is applied to `samples`
    /// ONLY. `latest` must stay the true newest RAW entry — a smoothed headline
    /// would be a number the person never logged.
    @Test("moodTileState: samples are smoothed, latest stays the raw newest score")
    func moodTileStateSmoothsSamplesNotLatest() throws {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        // One entry per day, alternating the extremes of the 1–5 scale.
        let scores = [1, 5, 1, 5, 1]
        let entries: [MoodEntry] = try scores.enumerated().map { offset, score in
            let day = try #require(cal.date(byAdding: .day, value: offset, to: base))
            return MoodEntry(id: "m\(offset)", recordedAt: day.addingTimeInterval(10 * 3600), score: score)
        }
        let state = DashboardStore.moodTileState(entries: entries.shuffled())
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(String(describing: state))")
            return
        }
        // One point per day survives — smoothing never drops or adds points.
        #expect(samples.count == 5)
        // …but no sample is a raw 1 or 5 any more: the zig-zag is gone.
        #expect(samples.allSatisfy { $0.primaryValue > 1.5 && $0.primaryValue < 4.5 })
        // The headline is untouched: the last mood the person actually logged.
        #expect(latest.id == "m4")
        #expect(latest.primaryValue == 1.0)
    }

    /// Fix 2 integration — through `refreshMetricStates`: a non-empty
    /// `MoodStore` snapshot makes the `.mood` tile `.ready` even though the
    /// `/api/measurements` wide page carries NO mood rows (mood never lives
    /// there). Pre-fix this derived `.empty(.noData)` → the "Noch keine Daten"
    /// regression on the tile.
    @Test("refreshMetricStates: mood tile derives .ready from MoodStore, not measurements")
    @MainActor
    func moodTileStateWiredThroughFanOut() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = DashboardStore(repo: DashboardRepository(api: api))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, empty) // wide page + any series call → empty
        }
        let entries = [MoodEntry(id: "m1", recordedAt: now.addingTimeInterval(-3600), score: 4)]
        await store.refreshMetricStates(
            kinds: [.mood],
            measurementsRepo: measurementsRepo,
            moodEntries: entries,
            rangeDays: 30,
            now: now
        )
        guard case let .ready(latest, _) = store.metricStates[.mood] else {
            Issue.record("Expected .ready for mood tile from MoodStore, got \(String(describing: store.metricStates[.mood]))")
            return
        }
        #expect(latest.primaryValue == 4.0)
    }

    @Test("refreshMetricStates: empty MoodStore → mood tile .empty(.noData)")
    @MainActor
    func moodTileStateEmptyThroughFanOut() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = DashboardStore(repo: DashboardRepository(api: api))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, empty)
        }
        await store.refreshMetricStates(
            kinds: [.mood],
            measurementsRepo: measurementsRepo,
            moodEntries: [],
            rangeDays: 30,
            now: now
        )
        #expect(store.metricStates[.mood] == .empty(reason: .noData))
    }

    @Test("refreshMetricStates: calm MoodStore series replaces a granular server sparkline")
    @MainActor
    func moodCalmSeriesIsAuthoritative() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = DashboardStore(repo: DashboardRepository(api: api))
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let scores = [1, 5, 1, 5, 1]
        let entries = try scores.enumerated().map { offset, score in
            try MoodEntry(
                id: "mood-\(offset)",
                recordedAt: #require(calendar.date(byAdding: .day, value: offset, to: base)),
                score: score
            )
        }
        store.summary = DashboardSummary(
            greeting: Greeting(salutation: "Hi", date: base),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: [DashboardMetric(
                id: "mood",
                kind: .mood,
                title: "Stimmung",
                latestValue: 1,
                secondaryValue: nil,
                unit: "",
                trend: .unknown,
                sparkline: [1, 5, 1, 5, 1, 5, 1, 5],
                updatedAt: entries.last?.recordedAt
            )],
            lastUpdated: base
        )
        let empty = emptyMeasurementsPayload()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, empty)
        }

        try await store.refreshMetricStates(
            kinds: [.mood],
            measurementsRepo: measurementsRepo,
            moodEntries: entries,
            rangeDays: 30,
            now: #require(calendar.date(byAdding: .day, value: 5, to: base))
        )

        let sparkline = try #require(store.summary?.metrics.first?.sparkline)
        #expect(sparkline.count == entries.count)
        #expect(sparkline.allSatisfy { $0 > 1.5 && $0 < 4.5 })
    }

    // MARK: - BMI request shape + availability key

    /// The routing-table contract the BMI history depends on: BMI's
    /// availability / kind-scoped `?type=` key is `BODY_MASS_INDEX` (stored
    /// smart-scale rows), NOT the old `WEIGHT` mapping (which fetched weight rows
    /// that decoded to `.weight` and were filtered out → empty BMI list/detail).
    @Test("availability key: .bmi → BODY_MASS_INDEX")
    func bmiAvailabilityKeyIsBodyMassIndex() {
        #expect(MetricKind.bmi.availabilitySummaryKey == "BODY_MASS_INDEX")
    }

    /// `recent(kind: .bmi)` must request the kind-scoped page
    /// `/api/measurements?type=BODY_MASS_INDEX` and return rows that stay `.bmi`
    /// (BODY_MASS_INDEX decodes to `.bmi`, and the kind-scoped filter keeps them).
    @Test("recent(kind: .bmi) requests ?type=BODY_MASS_INDEX and keeps .bmi rows")
    @MainActor
    func recentBmiRequestsBodyMassIndexType() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bmiRowIso = iso(now.addingTimeInterval(-86400))
        let bmiPayload = Data(
            ("{\"data\":{\"measurements\":[{\"id\":\"b1\",\"type\":\"BODY_MASS_INDEX\",\"value\":24.5,\"measuredAt\":\""
                + bmiRowIso + "\"}]}}").utf8
        )
        nonisolated(unsafe) var capturedTypeParams: [String] = []
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let query = request.url?.query ?? ""
            if query.contains("type=") {
                capturedTypeParams.append(query)
            }
            return (response, bmiPayload)
        }
        let rows = try await measurementsRepo.recent(kind: .bmi, limit: 400)
        // The request went through the kind-scoped `?type=BODY_MASS_INDEX` page.
        #expect(capturedTypeParams.contains { $0.contains("type=BODY_MASS_INDEX") })
        // …and the rows stayed `.bmi` (not filtered out by the kind guard).
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.kind == .bmi })
        #expect(rows.first?.primaryValue == 24.5)
    }

    // MARK: - Fix 3 — BMI tile state via kind-scoped fallback

    /// Fix 3 — the wide `/api/measurements?limit=400` page carries NO BMI rows
    /// (HK power-user's recent rows are steps/HR), so BMI derives `.empty` from
    /// the fan-out. The kind-scoped fallback then re-reads
    /// `/api/measurements?type=BODY_MASS_INDEX` and hydrates the tile to `.ready`.
    /// `.bmi` has no `/series` endpoint, so this must NOT go through the series
    /// fallback.
    @Test("BMI empty in wide page → kind-scoped fallback synthesizes .ready")
    @MainActor
    func bmiEmptyTriggersKindScopedFallback() async throws {
        let api = makeAPIClient()
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = DashboardStore(repo: DashboardRepository(api: api))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bmiRowIso = iso(now.addingTimeInterval(-86400))
        let bmiTypePayload = Data(
            ("{\"data\":{\"measurements\":[{\"id\":\"b1\",\"type\":\"BODY_MASS_INDEX\",\"value\":24.5,\"measuredAt\":\""
                + bmiRowIso + "\"}]}}").utf8
        )
        let emptyWide = emptyMeasurementsPayload()
        nonisolated(unsafe) var seriesCallCount = 0
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.contains("/api/measurements/series") {
                seriesCallCount += 1
                return (response, emptyWide)
            }
            // Kind-scoped page → BMI rows; plain wide page → empty.
            if query.contains("type=BODY_MASS_INDEX") {
                return (response, bmiTypePayload)
            }
            return (response, emptyWide)
        }
        await store.refreshMetricStates(
            kinds: [.bmi],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        guard case let .ready(latest, _) = store.metricStates[.bmi] else {
            Issue.record("Expected .ready for BMI after kind-scoped fallback, got \(String(describing: store.metricStates[.bmi]))")
            return
        }
        #expect(latest.primaryValue == 24.5)
        #expect(latest.kind == .bmi)
        #expect(seriesCallCount == 0, "BMI has no /series endpoint — the fallback must be kind-scoped, not series")
    }
}

// swiftlint:enable force_unwrapping
