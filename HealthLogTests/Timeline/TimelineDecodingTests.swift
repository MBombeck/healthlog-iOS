import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// `GET /api/timeline` as the server answers it (`Timeline` in the OpenAPI,
/// `src/lib/day/wire-schemas.ts`, server 1.47.1): every lane, a medication
/// as a group of items, value series by bucket, a lab marker and a person's
/// own symptom. A row this build cannot read costs that row, never the page.
@Suite("Timeline — wire contract of GET /api/timeline", .serialized, .mockURLSession)
@MainActor
struct TimelineDecodingTests {
    /// The server's shape with the fields the app reads and the ones it does
    /// not (`precision`, `href`, `standing`, `notable`, `icon`, `scale`), plus
    /// three rows a future server might send: an unknown item kind, an item
    /// without an id and a lane this build does not know.
    nonisolated static let body = #"""
    {"data":{
      "zoom":"quarter",
      "range":{"from":"2026-08-19","to":"2026-11-17","dataFrom":"2023-11-18"},
      "lanes":[
        {"key":"illness","items":[
          {"id":"ep1","kind":"episode","start":"2026-10-01","end":"2026-10-08","open":false,"precision":"DAY","startKnown":true,"label":"Magen-Darm-Infekt",
           "sub":null,"href":"/illness/ep1","group":null},
          {"id":"ch1","kind":"chronic","start":"2023-11-18","end":null,"open":true,"precision":"YEAR","startKnown":true,"label":"Bluthochdruck","sub":null,"href":null,"group":null}
        ]},
        {"key":"medications","items":[
          {"id":"m1","kind":"medication","start":"2026-02-20","end":null,"open":true,"precision":"DAY","startKnown":true,"label":"Trulicity","sub":"2,5 mg","href":"/medications/m1","group":"m1"},
          {"id":"d1","kind":"doseChange","start":"2026-03-24","end":null,"open":false,"precision":"DAY","startKnown":true,"label":"Trulicity","sub":"5 mg","href":null,"group":"m1"},
          {"id":"p1","kind":"pause","start":"2026-09-30","end":"2026-10-07","open":false,"precision":"DAY","startKnown":true,"label":"Trulicity","sub":null,"href":null,"group":"m1"},
          {"id":"x1","kind":"somethingNew","start":"2026-10-01","end":null,"open":false,"precision":"DAY","startKnown":true,"label":"Neu","sub":null,"href":null,"group":null},
          {"kind":"medication","start":"2026-10-01","label":"ohne id"}
        ]},
        {"key":"futureLane","items":[{"id":"f1","kind":"visit","start":"2026-10-01","end":null,"open":false,"precision":"DAY","startKnown":true,"label":"x","sub":null,"href":null,"group":null}]}
      ],
      "standing":[{"lane":"allergies","id":"a1","label":"Penicillin","since":null,"href":null}],
      "bucket":"week",
      "series":[
        {"key":"WEIGHT","unit":"kg","points":[{"t":"2026-11-02","mean":88.4,"count":4},{"t":"2026-11-09","mean":88.1,"count":2},{"t":"bad"}]},
        {"key":"BLOOD_PRESSURE_SYS","unit":"mmHg","points":[]}
      ],
      "availableSeries":["BLOOD_PRESSURE_SYS","BLOOD_PRESSURE_DIA","WEIGHT"],
      "labSeries":[{"key":"lab:bm_ggt","biomarkerId":"bm_ggt","name":"GGT","panel":"Leber","unit":"U/L",
        "band":{"low":null,"high":60},
        "points":[{"id":"r1","date":"2026-11-05","value":72,"sourceValue":null,"rangeStatus":"above","referenceLow":null,"referenceHigh":60,"report":null}],
        "excluded":0}],
      "availableLabs":[{"key":"lab:bm_ggt","biomarkerId":"bm_ggt","name":"GGT","panel":"Leber","unit":"U/L"}],
      "symptomSeries":[{"key":"symptom:sd_head","definitionId":"sd_head","label":"Kopfschmerz","icon":null,"isActive":false,
        "scale":{"min":0,"max":10},"points":[{"t":"2026-10-05","mean":5.5,"count":4}]}],
      "availableSymptoms":[{"key":"symptom:sd_head","definitionId":"sd_head","label":"Kopfschmerz","icon":null,"isActive":false}],
      "notable":[{"date":"2026-10-03","kind":"extremeHigh"}]
    },"error":null}
    """#

    private struct Envelope: Decodable {
        let data: TimelineRead
    }

    nonisolated static func decode(_ json: String = body) throws -> TimelineRead {
        try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(json.utf8)).data
    }

    @Test("reads the window, the bucket and every lane it knows; an unknown lane is left out")
    func lanesAndWindow() throws {
        let read = try Self.decode()
        #expect(read.zoom == .quarter)
        #expect(read.bucket == .week)
        #expect(read.range == TimelineRange(from: "2026-08-19", to: "2026-11-17", dataFrom: "2023-11-18"))
        #expect(read.lanes.map(\.key) == [.illness, .medications])
        #expect(read.items(of: .illness).map(\.kind) == [.episode, .chronic])
        #expect(read.items(of: .vaccinations).isEmpty)
    }

    @Test("a medication arrives as its group; an unknown kind reads .other, an item without id is dropped")
    func medicationGroup() throws {
        let items = try Self.decode().items(of: .medications)
        #expect(items.map(\.id) == ["m1", "d1", "p1", "x1"])
        #expect(items[0].open && items[0].sub == "2,5 mg" && items[0].group == "m1")
        #expect(items[1].kind == .doseChange && items[1].sub == "5 mg")
        #expect(items[2].kind == .pause && items[2].end == "2026-10-07")
        #expect(items[3].kind == .other)
        #expect(items[0].isSpan && !items[1].isSpan && items[2].isSpan)
    }

    @Test("series keep the server's means and counts; an unreadable point costs that point")
    func series() throws {
        let read = try Self.decode()
        let weight = try #require(read.series.first { $0.key == "WEIGHT" })
        #expect(weight.unit == "kg")
        #expect(weight.points == [
            TimelineValuePoint(t: "2026-11-02", mean: 88.4, count: 4),
            TimelineValuePoint(t: "2026-11-09", mean: 88.1, count: 2)
        ])
        #expect(read.series.first { $0.key == "BLOOD_PRESSURE_SYS" }?.points.isEmpty == true)
        #expect(read.availableSeries == ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA", "WEIGHT"])
    }

    @Test("a lab marker keeps its single readings and band; a symptom its means and hidden state")
    func labsAndSymptoms() throws {
        let read = try Self.decode()
        let ggt = try #require(read.labSeries.first)
        #expect(ggt.band == TimelineLabBand(low: nil, high: 60))
        #expect(ggt.points.map(\.rangeStatus) == [.above])
        #expect(read.availableLabs.map(\.key) == ["lab:bm_ggt"])
        let symptom = try #require(read.symptomSeries.first)
        #expect(symptom.label == "Kopfschmerz" && !symptom.isActive)
        #expect(symptom.points == [TimelineValuePoint(t: "2026-10-05", mean: 5.5, count: 4)])
        #expect(read.availableSymptoms == [TimelineSymptomOption(
            key: "symptom:sd_head",
            definitionId: "sd_head",
            label: "Kopfschmerz",
            isActive: false
        )])
    }

    @Test("an older server without labs and symptoms still decodes, with empty lists")
    func olderServer() throws {
        let json = #"""
        {"data":{"zoom":"all","range":{"from":"2024-01-01","to":"2026-11-17","dataFrom":null},
          "lanes":[],"standing":[],"bucket":"quarter","series":[],"availableSeries":[],"notable":[]},"error":null}
        """#
        let read = try Self.decode(json)
        #expect(read.zoom == .all && read.bucket == .quarter)
        #expect(read.labSeries.isEmpty && read.symptomSeries.isEmpty && read.availableSymptoms.isEmpty)
        #expect(read.range.dataFrom == nil)
    }

    // MARK: - Repository

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("the read names the zoom, a range's ends and the chosen lines; malformed keys are never sent")
    func repositoryQuery() async throws {
        let repo = TimelineRepository(api: makeAPI())
        let seen = TimelineLockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.body.utf8))
        }
        let read = try await repo.fetchTimeline(
            zoom: .quarter,
            values: ["WEIGHT", "lab:bm_ggt", "symptom:sd_head", "WEIGHT", "weight", "lab:", "symptom:a,b", "MOOD"]
        )
        _ = try await repo.fetchTimeline(zoom: .range, from: "2026-05-01", to: "2026-11-17", values: [])
        #expect(read.lanes.count == 2)
        let items = seen.all.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        func value(_ name: String, _ index: Int) -> String? {
            items[index].first { $0.name == name }?.value
        }
        #expect(seen.all.allSatisfy { $0.path == "/api/timeline" })
        #expect(value("zoom", 0) == "quarter")
        #expect(value("from", 0) == nil)
        #expect(value("values", 0) == "WEIGHT,lab:bm_ggt,symptom:sd_head,MOOD")
        #expect(value("zoom", 1) == "range")
        #expect(value("from", 1) == "2026-05-01" && value("to", 1) == "2026-11-17")
        #expect(value("values", 1)?.isEmpty == true)
    }

    /// Build 312 on the iPad: signed in, the version forgotten with the
    /// server address and not probed again until the next foreground, so
    /// the sidebar had no timeline. Unknown offers the page.
    @Test("the page is offered from server 1.42 on and while the version is not known yet")
    func availability() {
        #expect(TimelineRepository.isTimelineAvailable(serverVersion: nil))
        #expect(!TimelineRepository.isTimelineAvailable(serverVersion: "1.41.9"))
        #expect(TimelineRepository.isTimelineAvailable(serverVersion: "1.42.0"))
        #expect(TimelineRepository.isTimelineAvailable(serverVersion: "1.47.1"))
        #expect(!TimelineRepository.isTimelineAvailable(serverVersion: "garbage"))
    }
}

private final class TimelineLockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var all: [URL] {
        lock.withLock { urls }
    }
}
