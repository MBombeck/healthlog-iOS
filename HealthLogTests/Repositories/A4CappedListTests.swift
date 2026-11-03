import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// **A4 (iOS 1.4) — capped lists (#146, #147; server v1.43.7 / v1.43.8).**
///
/// `ListCapMeta` in `docs/api/openapi.yaml` at `v1.43.10`: every response of
/// fifteen list routes carries `meta: { requestId, truncated, limit }`
/// ("True when more rows exist than this response carries … Show the person
/// that the list is partial rather than letting the last row read as the
/// oldest there is"). The app reads nine of them. Where the route takes
/// `offset` (illness episodes, mental-health assessments) the read goes on
/// until the list is whole; where it only takes `limit` it asks once more at
/// the route's maximum; ECG and rhythm events take neither.
@Suite("A4: capped lists honour meta.truncated", .serialized, .mockURLSession)
struct A4CappedListTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static func ok(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    static func episode(_ id: String) -> String {
        """
        {"id":"\(id)","label":"Cold \(id)","type":"INFECTION","lifecycle":"ACUTE",
         "onsetAt":"2026-06-01T00:00:00.000Z","resolvedAt":null,"parentConditionId":null,
         "note":null,"createdAt":"2026-06-01T00:00:00.000Z","updatedAt":"2026-06-01T00:00:00.000Z"}
        """
    }

    static func screener(_ id: String) -> String {
        """
        {"id":"\(id)","instrument":"PHQ9","locale":"en","version":"standard","totalScore":4,
         "severityBand":"minimal","item9Flagged":false,"crisisShownAt":null,
         "takenAt":"2026-07-20T08:00:00.000Z","createdAt":"2026-07-20T08:00:00.000Z"}
        """
    }

    static func allergy(_ id: String) -> String {
        """
        {"id":"\(id)","substance":"S\(id)","category":"FOOD","type":"ALLERGY","severity":null,"status":"ACTIVE",
         "onsetAt":null,"reaction":null,"note":null,"createdAt":"","updatedAt":""}
        """
    }

    static func meta(truncated: Bool, limit: Int) -> String {
        #"{"requestId":"req-a4-0001","truncated":\#(truncated),"limit":\#(limit)}"#
    }

    @Test("illness episodes: a cut page is read on with offset until the list is whole")
    func illnessPages() async throws {
        let offsets = Mutex<[String?]>([])
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/illness/episodes")
            let offset = Self.query(req, "offset")
            offsets.withLock { $0.append(offset) }
            let body = offset == nil
                ? #"{"data":[\#(Self.episode("ep-1")),\#(Self.episode("ep-2"))],"error":null,"meta":\#(Self.meta(truncated: true, limit: 2))}"#
                : #"{"data":[\#(Self.episode("ep-3"))],"error":null,"meta":\#(Self.meta(truncated: false, limit: 2))}"#
            return Self.ok(req, body)
        }
        let repo = try IllnessRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let episodes = try await repo.episodes(limit: 2)
        #expect(episodes.map(\.id) == ["ep-1", "ep-2", "ep-3"])
        #expect(offsets.withLock { $0 } == [nil, "2"])
    }

    @Test("a complete page (or an older server without meta) is one request")
    func completeIsOneRequest() async throws {
        let calls = Mutex(0)
        MockURLProtocol.install { req in
            calls.withLock { $0 += 1 }
            return Self.ok(req, #"{"data":[\#(Self.episode("ep-1"))],"error":null}"#)
        }
        let repo = try IllnessRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        #expect(try await repo.episodes().map(\.id) == ["ep-1"])
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("mental-health history: the first page reads on with offset, keeping its own query")
    func mentalHealthPages() async throws {
        let offsets = Mutex<[String?]>([])
        MockURLProtocol.install { req in
            let offset = Self.query(req, "offset")
            offsets.withLock { $0.append(offset) }
            let first = offset == "0"
            let rows = first ? [Self.screener("p1")] : [Self.screener("p2")]
            let body = #"{"data":{"assessments":[\#(rows.joined(separator: ","))]},"error":null,"meta":\#(Self.meta(truncated: first, limit: 1))}"#
            return Self.ok(req, body)
        }
        let repo = try MentalHealthRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let history = try await repo.history(limit: 1)
        #expect(history.map(\.id) == ["p1", "p2"])
        #expect(offsets.withLock { $0 } == ["0", "1"])
    }

    @Test("allergies take no offset: a cut answer is asked once more at the route's maximum")
    func allergiesCeiling() async throws {
        let limits = Mutex<[String?]>([])
        MockURLProtocol.install { req in
            let limit = Self.query(req, "limit")
            limits.withLock { $0.append(limit) }
            let wide = limit == "200"
            let rows = wide ? [Self.allergy("a1"), Self.allergy("a2")] : [Self.allergy("a1")]
            let body = #"{"data":[\#(rows.joined(separator: ","))],"error":null,"meta":\#(Self.meta(truncated: !wide, limit: wide ? 200 : 1))}"#
            return Self.ok(req, body)
        }
        let repo = try AllergiesRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let list = try await repo.list(limit: 1)
        #expect(list.map(\.id) == ["a1", "a2"])
        #expect(limits.withLock { $0 } == ["1", "200"])
    }

    @Test("ECG takes neither limit nor offset: a cut list is decoded and kept, with one request")
    func ecgCutIsKept() async throws {
        let calls = Mutex(0)
        MockURLProtocol.install { req in
            calls.withLock { $0 += 1 }
            let body = #"""
            {"data":{"recordings":[
              {"id":"ecg-1","recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,"samplingFrequency":300,
               "sampleCount":9000,"averageHeartRate":62,"lead":"I","classification":"NOT_DETECTED",
               "source":"APPLE_HEALTH","hasWaveform":true}],
             "hasRecordings":true},"error":null,"meta":{"requestId":"req-a4-0002","truncated":true,"limit":200}}
            """#
            return Self.ok(req, body)
        }
        let dto = try #require(try await EcgRepository(api: makeAPI()).fetchList())
        #expect(dto.recordings.map(\.id) == ["ecg-1"])
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("the cap decodes tolerantly; a transport without the envelope answers without it")
    func capDecoding() throws {
        let cap = try JSONDecoder.hlDefault.decode(ListCapMeta.self, from: Data(#"{"truncated":"yes","limit":200}"#.utf8))
        #expect(cap == ListCapMeta(truncated: false, limit: 200))
        let full = try JSONDecoder.hlDefault.decode(ListCapMeta.self, from: Data(#"{"truncated":true,"limit":100}"#.utf8))
        #expect(full == ListCapMeta(truncated: true, limit: 100))
    }
}
