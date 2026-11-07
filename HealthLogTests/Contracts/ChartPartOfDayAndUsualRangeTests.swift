import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **1.5 LAB-LINES, the two handed-on parts.**
///
/// - BP-TOD's chart filter: `partOfDay` on the blood pressure daily series
///   (server v1.47.0). The chart card draws the narrowed series, the rest of
///   the page keeps the whole day, a server that does not narrow is never
///   drawn under a part's name.
/// - COACH-R point 5: `coach-read` line one at the top of the chart card,
///   only when the server sends `latestIsToday`, naming the date of an older
///   latest reading instead of calling it today's.
@Suite("1.5 LAB-LINES — blood pressure part of day and usual range", .serialized, .mockURLSession)
@MainActor
struct ChartPartOfDayAndUsualRangeTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeStore(api: APIClient) throws -> ChartDetailStore {
        try ChartDetailStore(
            kind: .bloodPressure,
            measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "de" }
        )
    }

    /// One narrowed daily series as the server answers it.
    nonisolated static func rows(_ type: String, _ values: [Double], echo: String?) -> String {
        let rows = values.enumerated().map { index, value in
            #"{"type":"\#(type)","value":\#(value),"measuredAt":"2026-11-0\#(index + 1)T03:00:00.000Z","count":2}"#
        }
        let meta = echo.map { #","partOfDay":"\#($0)""# } ?? ""
        return #"{"data":{"measurements":[\#(rows.joined(separator: ","))],"meta":{"total":\#(values.count),"limit":365,"offset":0,"aggregate":"daily"\#(meta)}},"error":null}"#
    }

    private func install(echo: Bool, seen: LockedURLs) {
        MockURLProtocol.install { req in
            seen.append(req.url!)
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let type = items.first { $0.name == "type" }?.value ?? ""
            let part = items.first { $0.name == "partOfDay" }?.value
            let values: [Double] = type == "BLOOD_PRESSURE_SYS" ? [131, 128, 135] : [84, 82]
            let body = Self.rows(type, values, echo: echo ? part : nil)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    // MARK: - Part of day

    @Test("the narrowed read asks the daily rollup per type with the part, the window and the day cap")
    func narrowedQuery() async throws {
        let seen = LockedURLs()
        install(echo: true, seen: seen)
        let repo = try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let from = Date(timeIntervalSince1970: 1_790_000_000)
        let points = try #require(try await repo.bloodPressureDailySeries(
            part: .evening,
            from: from,
            to: from.addingTimeInterval(86400 * 30)
        ))
        let items = seen.all.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        #expect(seen.all.count == 2)
        #expect(Set(items.compactMap { $0.first { $0.name == "type" }?.value }) == ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"])
        for query in items {
            func value(_ name: String) -> String? {
                query.first { $0.name == name }?.value
            }
            #expect(value("partOfDay") == "evening")
            #expect(value("aggregate") == "daily")
            #expect(value("source") == "rollup")
            #expect(value("limit") == "365")
            #expect(value("from") != nil && value("to") != nil)
        }
        // A day with only half a pair is not drawn; the rest as sent.
        #expect(points.map(\.value) == [131, 128])
        #expect(points.map(\.secondary) == [84, 82])
    }

    @Test("a server that answers the whole day is refused, the choice withdrawn, never drawn as a part")
    func notNarrowedIsRefused() async throws {
        let seen = LockedURLs()
        install(echo: false, seen: seen)
        let store = try makeStore(api: makeAPI())
        store.range = .month
        store.choosePartOfDay(.morning)
        #expect(store.activePartOfDay == .morning)
        await store.loadPartOfDay()
        #expect(store.partOfDayChart.isUnsupported)
        #expect(store.activePartOfDay == nil)
        #expect(store.partOfDayChart.series == nil)
    }

    @Test("only the chart card follows the part; the whole day stays for everything else")
    func cardFollowsPart() async throws {
        let seen = LockedURLs()
        install(echo: true, seen: seen)
        let store = try makeStore(api: makeAPI())
        let whole = [
            SeriesPoint(id: "a", at: .now.addingTimeInterval(-86400), value: 140, secondary: 90),
            SeriesPoint(id: "b", at: .now, value: 120, secondary: 80)
        ]
        store.series = MeasurementSeries(
            kind: .bloodPressure,
            points: whole,
            stats: SeriesStats(mean: 130, min: 120, max: 140, stdDev: 10, count: 2)
        )
        store.range = .month
        #expect(store.chartCardPoints.map(\.value) == [140, 120])
        store.choosePartOfDay(.morning)
        // Nothing drawn under the part's name before its read lands.
        #expect(store.chartCardPoints.isEmpty)
        #expect(store.chartCardIsLoading == false)
        await store.loadPartOfDay()
        #expect(store.partOfDayChart.phase == .loaded)
        #expect(store.chartCardPoints.map(\.value) == [131, 128])
        #expect(store.chartCardSeries?.points.count == 2)
        // Stats, change and hero keep the server's whole-day series.
        #expect(store.stats?.mean == 130)
        #expect(store.chartPoints.map(\.value) == [140, 120])
        // A single day has no daily means to narrow.
        store.range = .day
        #expect(store.activePartOfDay == nil)
        #expect(store.chartCardPoints.map(\.value) == [140, 120])
        // Back to the whole day.
        store.range = .month
        store.choosePartOfDay(nil)
        #expect(store.chartCardPoints.map(\.value) == [140, 120])
    }

    @Test("a failed part read shows the chart card's error face, not the whole day")
    func failedPartRead() async throws {
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"x"}"#.utf8)
            )
        }
        let store = try makeStore(api: makeAPI())
        store.range = .week
        store.choosePartOfDay(.midday)
        await store.loadPartOfDay()
        #expect(store.partOfDayChart.phase == .failed)
        #expect(store.chartCardHasError)
        #expect(store.chartCardPoints.isEmpty)
    }

    @Test("the part row: blood pressure page of a 1.47 server only")
    func partGate() {
        #expect(InsightsChartExtras.partOfDayAvailable(kind: .bloodPressure, hasServer: true, serverVersion: "1.47.0"))
        #expect(!InsightsChartExtras.partOfDayAvailable(kind: .bloodPressure, hasServer: true, serverVersion: "1.46.6"))
        #expect(!InsightsChartExtras.partOfDayAvailable(kind: .bloodPressure, hasServer: true, serverVersion: nil))
        #expect(!InsightsChartExtras.partOfDayAvailable(kind: .pulse, hasServer: true, serverVersion: "1.47.0"))
        #expect(!InsightsChartExtras.partOfDayAvailable(kind: .bloodPressure, hasServer: false, serverVersion: "1.47.0"))
        #expect(!ChartDetailStore.partOfDayApplies(kind: .bloodPressure, range: .day))
        #expect(ChartDetailStore.partOfDayApplies(kind: .bloodPressure, range: .week))
    }

    @Test("the card names the part with the server's hours")
    func caption() {
        let caption = ChartDetailStore.partOfDayCaption(.evening)
        #expect(caption ==
            String(
                localized: "chart.partOfDay.caption \(String(localized: "insights.bpTimeOfDay.part.evening")) \(String(localized: "insights.bpTimeOfDay.hours \("18:00") \("03:59")"))"
            ))
        #expect(caption.contains("18:00") && caption.contains("03:59"))
    }

    // MARK: - Usual range (coach-read)

    nonisolated static func strip(_ baseline: String) throws -> CoachReadStrip {
        let json = #"{"data":{"baseline":\#(baseline),"learning":false,"driver":null},"error":null}"#
        return try JSONDecoder.hlDefault.decode(StripEnvelope.self, from: Data(json.utf8)).data
    }

    private struct StripEnvelope: Decodable {
        let data: CoachReadStrip
    }

    static let metric = UnitPreferences(weight: .kg, glucose: .mgdL, system: .metric)
    static let imperial = UnitPreferences(weight: .lb, glucose: .mmolL, system: .imperial)

    @Test("without latestIsToday (a server before 1.41) there is no line")
    func noFieldNoLine() throws {
        let old = try Self.strip(#"{"low":62,"high":70,"latest":66,"placement":"within","sampleDays":30}"#)
        #expect(old.baseline != nil)
        #expect(old.baseline?.latestIsToday == nil)
        #expect(ChartCoachReadLine.text(old, kind: .pulse, units: Self.metric) == nil)
        // Still learning: no baseline, no line.
        let learning = try Self.strip("null")
        #expect(ChartCoachReadLine.text(learning, kind: .pulse, units: Self.metric) == nil)
        #expect(ChartCoachReadLine.text(nil, kind: .pulse, units: Self.metric) == nil)
    }

    @Test("today's reading is called today's; an older one is named by its date")
    func todayAndDated() throws {
        let today = try Self.strip(
            #"{"low":62,"high":70,"latest":74,"latestDate":"2026-11-05","latestIsToday":true,"placement":"above","sampleDays":30}"#
        )
        #expect(ChartCoachReadLine.text(today, kind: .pulse, units: Self.metric)
            == String(localized: "insights.coachRead.today.above \("62") \("70") \("bpm") \("74")"))
        let dated = try Self.strip(
            #"{"low":62,"high":70,"latest":66,"latestDate":"2026-11-03","latestIsToday":false,"placement":"within","sampleDays":30}"#
        )
        let date = try #require(ChartCoachReadLine.dayText("2026-11-03"))
        let line = try #require(ChartCoachReadLine.text(dated, kind: .pulse, units: Self.metric))
        #expect(line == String(localized: "insights.coachRead.latest.within \("62") \("70") \("bpm") \(date) \("66")"))
        #expect(line.contains(date))
        #expect(line != String(localized: "insights.coachRead.today.within \("62") \("70") \("bpm") \("66")"))
    }

    @Test("a steady band reads as one value; a glucose day in progress says it is the range for this time of day")
    func steadyAndSameHours() throws {
        let steady = try Self.strip(
            #"{"low":61,"high":61,"latest":64,"latestDate":"2026-11-05","latestIsToday":true,"placement":"above","sampleDays":30}"#
        )
        #expect(ChartCoachReadLine.text(steady, kind: .pulse, units: Self.metric)
            == String(localized: "insights.coachRead.steady.above \("61") \("bpm") \("64")"))
        let glucose = try Self.strip(
            #"{"low":90,"high":110,"latest":100,"latestDate":"2026-11-05","latestIsToday":true,"placement":"within","sampleDays":30,"basis":"sameHours"}"#
        )
        let line = try #require(ChartCoachReadLine.text(glucose, kind: .glucose, units: Self.metric))
        #expect(line == String(localized: "insights.coachRead.sameHours.within \("90") \("110") \("mg/dL") \("100")"))
    }

    @Test("values are the server's, converted into the account's unit only")
    func accountUnit() throws {
        let weight = try Self.strip(
            #"{"low":80,"high":82,"latest":81,"latestDate":"2026-11-05","latestIsToday":true,"placement":"within","sampleDays":30}"#
        )
        let metricLine = try #require(ChartCoachReadLine.text(weight, kind: .weight, units: Self.metric))
        let imperialLine = try #require(ChartCoachReadLine.text(weight, kind: .weight, units: Self.imperial))
        #expect(metricLine.contains(MetricValueFormatter.formatScalar(80, kind: .weight, units: Self.metric)))
        #expect(imperialLine.contains(MetricValueFormatter.formatScalar(80, kind: .weight, units: Self.imperial)))
        #expect(imperialLine.contains("lb"))
    }

    @Test("an unknown placement is no baseline; only six metrics ask for the line")
    func tolerantAndScoped() throws {
        let odd = try Self.strip(
            #"{"low":1,"high":2,"latest":3,"latestDate":"2026-11-05","latestIsToday":true,"placement":"sideways","sampleDays":30}"#
        )
        #expect(odd.baseline == nil)
        #expect(CoachReadRepository.metric(for: .bloodPressure) == "BLOOD_PRESSURE_SYS")
        #expect(CoachReadRepository.metric(for: .weight) == "WEIGHT")
        #expect(CoachReadRepository.metric(for: .sleep) == nil)
        #expect(CoachReadRepository.metric(for: .steps) == nil)
    }

    @Test("the read asks coach-read for the metric")
    func coachReadQuery() async throws {
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            let body = #"{"data":{"baseline":null,"learning":true,"driver":null},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let strip = try await CoachReadRepository(api: makeAPI()).fetch(metric: "PULSE")
        #expect(strip.baseline == nil)
        let url = try #require(seen.all.first)
        #expect(url.path == "/api/insights/coach-read")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "PULSE")
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var all: [URL] {
        lock.withLock { urls }
    }
}
