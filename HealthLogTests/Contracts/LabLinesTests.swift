import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **1.5 LAB-LINES (#158, server #1299, v1.46.3)** — a lab marker under
/// the metric chart, read from `GET /api/timeline`: the wire contract (two
/// readings on one day stay two points, `rangeStatus` as sent, `excluded`, a
/// deleted marker), the gates (module `timeline`, version, refusals), the
/// read only when there is something to show, the remembered choice per
/// metric, the grouping of the choice and the VoiceOver wording.
@Suite("1.5 LAB-LINES — lab marker under the metric chart", .serialized, .mockURLSession)
@MainActor
struct LabLinesTests {
    nonisolated static let hba1c = "lab:bm_hba1c"

    /// The server's shape (`Timeline`, OpenAPI v1.47.0), reduced to what the
    /// app reads plus a lane it ignores: two readings on 2026-10-02 (one above,
    /// one in range), one below, an unknown verdict word, one excluded reading.
    nonisolated static let body = #"""
    {"data":{
      "zoom":"range",
      "range":{"from":"2026-08-07","to":"2026-11-04","dataFrom":"2019-01-01"},
      "lanes":[{"key":"labs","items":[]}],
      "standing":[],
      "bucket":"week",
      "series":[],
      "availableSeries":["WEIGHT"],
      "labSeries":[{
        "key":"lab:bm_hba1c","biomarkerId":"bm_hba1c","name":"HbA1c","panel":"Diabetes","unit":"%",
        "band":{"low":4.0,"high":5.6},
        "points":[
          {"id":"r1","date":"2026-08-20","value":5.2,"sourceValue":null,"rangeStatus":"in-range","referenceLow":4.0,"referenceHigh":5.6,"report":null},
          {"id":"r2","date":"2026-10-02","value":6.1,"sourceValue":6.1,"rangeStatus":"above","referenceLow":4.0,"referenceHigh":5.6,
           "report":{"id":"doc1","title":"Labor Oktober","href":"/documents/doc1"}},
          {"id":"r3","date":"2026-10-02","value":5.4,"sourceValue":null,"rangeStatus":"in-range","referenceLow":4.0,"referenceHigh":5.6,"report":null},
          {"id":"r4","date":"2026-10-30","value":3.8,"sourceValue":null,"rangeStatus":"below","referenceLow":4.0,"referenceHigh":5.6,"report":null},
          {"id":"r5","date":"2026-11-01","value":5.0,"sourceValue":null,"rangeStatus":"something-new","referenceLow":null,"referenceHigh":null,"report":null}
        ],
        "excluded":2
      }],
      "availableLabs":[
        {"key":"lab:bm_tsh","biomarkerId":"bm_tsh","name":"TSH","panel":"Schilddrüse","unit":"mU/L"},
        {"key":"lab:bm_hba1c","biomarkerId":"bm_hba1c","name":"HbA1c","panel":"Diabetes","unit":"%"},
        {"key":"lab:bm_crp","biomarkerId":"bm_crp","name":"CRP","panel":null,"unit":"mg/L"},
        {"key":"lab:bm_glucose","biomarkerId":"bm_glucose","name":"Glukose","panel":"Diabetes","unit":"mg/dL"},
        {"key":"broken"}
      ],
      "notable":[]
    },"error":null}
    """#

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private nonisolated static func decode(_ json: String = body) throws -> TimelineLabRead {
        try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(json.utf8)).data
    }

    private struct Envelope: Decodable {
        let data: TimelineLabRead
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "lab-lines-\(UUID().uuidString)"))
    }

    // MARK: - Wire contract

    @Test("reads both lists; two readings on one day stay two points, never a mean")
    func decodesTwoPointsSameDay() throws {
        let read = try Self.decode()
        let series = try #require(read.series(for: Self.hba1c))
        #expect(series.points.count == 5)
        let sameDay = series.points.filter { $0.date == "2026-10-02" }
        #expect(sameDay.map(\.value) == [6.1, 5.4])
        let plotted = ChartLabOverlay.plotted(series.points)
        #expect(plotted.count == 5)
        let sameDayDrawn = plotted.filter { $0.point.date == "2026-10-02" }
        #expect(sameDayDrawn.count == 2)
        #expect(sameDayDrawn[0].date != sameDayDrawn[1].date)
        #expect(Set(sameDayDrawn.map(\.point.value)) == [6.1, 5.4])
        // The unreadable marker row costs that row only.
        #expect(read.availableLabs.map(\.key) == ["lab:bm_tsh", Self.hba1c, "lab:bm_crp", "lab:bm_glucose"])
    }

    @Test("verdicts as sent: above is a triangle up, below a triangle down, an unknown word is no verdict")
    func verdictsAsSent() throws {
        let series = try #require(Self.decode().series(for: Self.hba1c))
        #expect(series.points.map(\.rangeStatus) == [.inRange, .above, .inRange, .below, .unknown])
        #expect(ChartLabOverlay.symbolName(.above) == "arrowtriangle.up.fill")
        #expect(ChartLabOverlay.symbolName(.below) == "arrowtriangle.down.fill")
        #expect(ChartLabOverlay.symbolName(.inRange) == "circle.fill")
        #expect(series.band == TimelineLabBand(low: 4.0, high: 5.6))
        // The band is on the axis even where no point reaches it.
        let domain = ChartLabOverlay.valueDomain(points: series.points, band: series.band)
        #expect(domain.lowerBound < 3.8 && domain.upperBound > 6.1)
    }

    @Test("excluded readings get one line with their count; none, no line")
    func excludedLine() throws {
        let series = try #require(Self.decode().series(for: Self.hba1c))
        #expect(series.excluded == 2)
        #expect(ChartLabOverlay.excludedLine(2) == String(localized: "insights.labOverlay.excluded \(2)"))
        #expect(ChartLabOverlay.excludedLine(1) == String(localized: "insights.labOverlay.excluded.one"))
        let without = try Self.decode(Self.body.replacingOccurrences(of: #""excluded":2"#, with: #""excluded":0"#))
        #expect(without.series(for: Self.hba1c)?.excluded == 0)
    }

    @Test("VoiceOver reads each point with its value and the server's verdict")
    func spokenPoint() throws {
        let series = try #require(Self.decode().series(for: Self.hba1c))
        let above = series.points[1]
        let spoken = ChartLabOverlay.spokenValue(above, unit: series.unit)
        #expect(spoken.contains(LabRangeStatus.above.localizedLabel))
        #expect(spoken.contains("%"))
        #expect(ChartLabOverlay.spokenValue(series.points[3], unit: "%").contains(LabRangeStatus.below.localizedLabel))
        #expect(!ChartLabOverlay.dayText("2026-10-02").isEmpty)
    }

    @Test("the report is a link only when the server names one; an untitled one is called a report")
    func reportLink() throws {
        let series = try #require(Self.decode().series(for: Self.hba1c))
        #expect(series.points[1].report == TimelineLabReport(id: "doc1", title: "Labor Oktober"))
        #expect(series.points[0].report == nil)
        #expect(ChartLabPointDetail
            .reportTitle(TimelineLabReport(id: "d", title: "  ")) == String(localized: "insights.labOverlay.report.untitled"))
    }

    // MARK: - Repository

    @Test("the read names the chart's window as a range and the marker; a malformed key is never sent")
    func repositoryQuery() async throws {
        let repo = TimelineRepository(api: makeAPI())
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.body.utf8))
        }
        _ = try await repo.fetchLabs(from: "2026-08-07", to: "2026-11-04", markerKey: Self.hba1c)
        _ = try await repo.fetchLabs(from: "2026-11-04", to: "2026-11-04", markerKey: nil)
        _ = try await repo.fetchLabs(from: "2026-11-04", to: "2026-11-04", markerKey: "lab:x,WEIGHT")
        let items = seen.all.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        #expect(seen.all.allSatisfy { $0.path == "/api/timeline" })
        func value(_ name: String, _ index: Int) -> String? {
            items[index].first { $0.name == name }?.value
        }
        #expect(value("zoom", 0) == "range")
        #expect(value("from", 0) == "2026-08-07")
        #expect(value("to", 0) == "2026-11-04")
        #expect(value("values", 0) == Self.hba1c)
        #expect(value("values", 1) == nil)
        #expect(value("values", 2) == nil)
        #expect(TimelineRepository.isMarkerKey("lab:cm_abc-123"))
        #expect(!TimelineRepository.isMarkerKey("lab:"))
        #expect(!TimelineRepository.isMarkerKey("lab:äbc"))
        #expect(!TimelineRepository.isMarkerKey("lab:" + String(repeating: "a", count: 65)))
        #expect(!TimelineRepository.isMarkerKey("WEIGHT"))
    }

    @Test("the window is the chart's days ending today, both inclusive, at most 15 years")
    func window() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9)))
        let month = ChartDetailStore.labWindow(days: 30, now: now, calendar: calendar)
        #expect(month.from == "2026-10-06" && month.to == "2026-11-04")
        let day = ChartDetailStore.labWindow(days: 1, now: now, calendar: calendar)
        #expect(day.from == "2026-11-04" && day.to == "2026-11-04")
        let all = ChartDetailStore.labWindow(days: 99999, now: now, calendar: calendar)
        #expect(all.from.hasPrefix("2011-"))
    }

    // MARK: - Model

    @Test("no marker chosen: nothing is read and nothing shows")
    func noSelectionNoRead() async throws {
        let calls = LockedInts()
        let model = try ChartLabOverlayModel(kind: .weight, preference: ChartLabOverlayPreference(defaults: defaults())) { _, _, _ in
            calls.append(1)
            return try Self.decode()
        }
        await model.load(days: 30)
        #expect(model.phase == .idle)
        #expect(calls.all.isEmpty)
    }

    @Test("a chosen marker loads its readings and the choice; it is remembered per metric")
    func selectLoadsAndRemembers() async throws {
        let store = try defaults()
        let preference = ChartLabOverlayPreference(defaults: store)
        let keys = LockedStrings()
        let model = ChartLabOverlayModel(kind: .weight, preference: preference) { _, _, key in
            keys.append(key ?? "-")
            return try Self.decode()
        }
        model.select(Self.hba1c)
        await model.load(days: 90)
        guard case let .loaded(series) = model.phase else {
            Issue.record("expected the marker, got \(model.phase)")
            return
        }
        #expect(series.name == "HbA1c")
        #expect(try model.choices == .loaded(Self.decode().availableLabs))
        #expect(keys.all == [Self.hba1c])
        #expect(preference.markerKey(for: .weight) == Self.hba1c)
        #expect(preference.markerKey(for: .bloodPressure) == nil)
        // A new page of the same metric starts with the remembered marker.
        let reopened = ChartLabOverlayModel(kind: .weight, preference: preference) { _, _, _ in try Self.decode() }
        #expect(reopened.selectedKey == Self.hba1c)
        reopened.select(nil)
        #expect(preference.markerKey(for: .weight) == nil)
        #expect(reopened.phase == .idle)
    }

    @Test("a deleted marker is left out by the server and shows nothing, without a message")
    func deletedMarkerMissing() async throws {
        let preference = try ChartLabOverlayPreference(defaults: defaults())
        preference.setMarkerKey("lab:bm_gone", for: .pulse)
        let model = ChartLabOverlayModel(kind: .pulse, preference: preference) { _, _, _ in try Self.decode() }
        await model.load(days: 30)
        #expect(model.phase == .missing)
        #expect(!model.isRefused)
    }

    @Test("module off, no right or no route hides the row; other failures offer a retry")
    func refusalsAndFailures() async throws {
        for (error, refused) in [
            (HLError.moduleDisabled("timeline"), true),
            (HLError.server(status: 403, code: "sharing.client.access.denied", message: ""), true),
            (HLError.server(status: 404, code: nil, message: ""), true),
            (HLError.server(status: 500, code: nil, message: ""), false)
        ] {
            let preference = try ChartLabOverlayPreference(defaults: defaults())
            preference.setMarkerKey(Self.hba1c, for: .weight)
            let model = ChartLabOverlayModel(kind: .weight, preference: preference) { _, _, _ in throw error }
            await model.load(days: 30)
            #expect(model.isRefused == refused)
            #expect(model.phase == (refused ? .idle : .failed))
        }
        let choices = try ChartLabOverlayModel(kind: .weight, preference: ChartLabOverlayPreference(defaults: defaults())) { _, _, _ in
            throw HLError.server(status: 503, code: nil, message: "")
        }
        await choices.loadChoices()
        #expect(choices.choices == .failed)
        choices.retryChoices()
        #expect(choices.choices == .notLoaded)
    }

    @Test("the choice: grouped by panel, alphabetical, markers without a panel last")
    func grouping() throws {
        let groups = try ChartLabOverlayModel.groups(Self.decode().availableLabs)
        #expect(groups.map(\.panel) == ["Diabetes", "Schilddrüse", nil])
        #expect(groups[0].markers.map(\.name) == ["Glukose", "HbA1c"])
        #expect(groups[2].markers.map(\.name) == ["CRP"])
    }

    // MARK: - Gate (Regel 10)

    @Test("only with the timeline module on, a paired server and v1.46.3 or later")
    func gate() {
        #expect(InsightsChartExtras.labOverlayAvailable(hasServer: true, serverVersion: "1.46.3", timelineModule: true))
        #expect(InsightsChartExtras.labOverlayAvailable(hasServer: true, serverVersion: "1.47.0", timelineModule: true))
        // Module off, or a map without the opt-in key.
        #expect(!InsightsChartExtras.labOverlayAvailable(hasServer: true, serverVersion: "1.47.0", timelineModule: false))
        #expect(!InsightsChartExtras.labOverlayAvailable(hasServer: true, serverVersion: "1.47.0", timelineModule: nil))
        // Older or unknown server.
        #expect(!InsightsChartExtras.labOverlayAvailable(hasServer: true, serverVersion: "1.46.2", timelineModule: true))
        #expect(!InsightsChartExtras.labOverlayAvailable(hasServer: true, serverVersion: nil, timelineModule: true))
        #expect(!InsightsChartExtras.labOverlayAvailable(hasServer: false, serverVersion: "1.47.0", timelineModule: true))
    }

    // MARK: - Shared records (POLISH-A A6)

    private nonisolated static func grant(sections: String) throws -> AccountAccessEntry {
        let json = #"""
        [{"accountId":"fixture-record","username":"fixture","access":"read","level":"read",
          "recordKind":"shared","sections":\#(sections),"canWrite":false}]
        """#
        return try #require(try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(json.utf8)).first)
    }

    /// The server admits `/api/timeline` as a whole-record read
    /// (`requireRecordAuth("read", "record")`, v1.47.0): a grant over every
    /// section reaches it, a grant scoped to some sections (even `labs`) does
    /// not. The app used to refuse it for every delegate, because the path
    /// stood in no scope list.
    @Test("a delegate with the whole record reads the timeline; a grant scoped to labs is refused like on the server")
    func delegateTimelineScope() async throws {
        let api = makeAPI()
        let seen = LockedURLs()
        let accounts = LockedStrings()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            accounts.append(req.value(forHTTPHeaderField: "X-HealthLog-Account") ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.body.utf8))
        }
        let repo = TimelineRepository(api: api)

        try await api.selectAccount(Self.grant(sections: "null"))
        let read = try await repo.fetchLabs(from: "2026-08-07", to: "2026-11-04", markerKey: Self.hba1c)
        #expect(!read.availableLabs.isEmpty)
        #expect(seen.all.map(\.path) == ["/api/timeline"])
        #expect(accounts.all == ["fixture-record"])

        try await api.selectAccount(Self.grant(sections: #"["labs","measurements"]"#))
        do {
            _ = try await repo.fetchLabs(from: "2026-08-07", to: "2026-11-04", markerKey: Self.hba1c)
            Issue.record("a scoped grant must not reach the timeline")
        } catch let HLError.server(status, code, _) {
            #expect(status == 403)
            #expect(code == "sharing.client.access.denied")
        }
        #expect(seen.all.count == 1)
    }
}

// MARK: - Small thread-safe recorders

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

private final class LockedInts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) {
        lock.withLock { values.append(value) }
    }

    var all: [Int] {
        lock.withLock { values }
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var all: [String] {
        lock.withLock { values }
    }
}
