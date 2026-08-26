import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the v1.25 mental-health DATA layer against the server contract: DTO
/// decode (incl. `crisis: null` and a present crisis set), the `{ data: { ... } }`
/// envelope unwrapping for GET history + POST submit, the exact POST request body
/// shape, and the outbox-enqueue on a retriable failure. Real `APIClient` + stub
/// `URLProtocol` (no mock server) per PROJECT_GUIDE.md.
@Suite("Mental-health data layer (v1.25)", .serialized)
struct MentalHealthRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo(outbox: OutboxQueue) -> MentalHealthRepository {
        MentalHealthRepository(api: makeAPI(), outbox: outbox)
    }

    // MARK: - DTO decode

    @Test("Assessment row decodes; raw items are never present on the wire")
    func decodeRow() throws {
        let json = Data(#"""
        {"id":"mh1","instrument":"PHQ9","locale":"en","version":"standard",
         "totalScore":18,"severityBand":"modSevere","item9Flagged":true,
         "crisisShownAt":"2026-06-28T08:00:00.000Z","takenAt":"2026-06-28T08:00:00.000Z",
         "createdAt":"2026-06-28T08:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MentalHealthAssessmentDTO.self, from: json)
        #expect(dto.id == "mh1")
        #expect(dto.instrument == .phq9)
        #expect(dto.totalScore == 18)
        #expect(dto.severityBand == "modSevere")
        #expect(dto.item9Flagged)
        #expect(dto.crisisShownAt != nil)
    }

    @Test("POST response decodes a present crisis set (item-9 flagged)")
    func decodeResponseWithCrisis() throws {
        let json = Data(#"""
        {"assessment":{"id":"mh2","instrument":"PHQ9","locale":"de","version":"standard",
          "totalScore":3,"severityBand":"minimal","item9Flagged":true,
          "crisisShownAt":"2026-06-28T08:00:00.000Z","takenAt":"2026-06-28T08:00:00.000Z",
          "createdAt":"2026-06-28T08:00:00.000Z"},
         "actionThreshold":10,
         "crisis":{"emergencyNumber":"112","resources":[
           {"id":"telefonSeelsorge","contacts":["0800 111 0 111","0800 111 0 222","telefonseelsorge.de"]},
           {"id":"nummerGegenKummer","contacts":["116 111"]}]}}
        """#.utf8)
        let resp = try JSONDecoder.hlDefault.decode(CreateAssessmentResponse.self, from: json)
        #expect(resp.actionThreshold == 10)
        #expect(resp.assessment.item9Flagged)
        // The crisis card is gated on item-9 (band is minimal here) — set present.
        #expect(resp.crisis?.emergencyNumber == "112")
        #expect(resp.crisis?.resources.first?.id == "telefonSeelsorge")
        #expect(resp.crisis?.resources.first?.contacts.count == 3)
    }

    @Test("POST response tolerates crisis: null (item-9 not flagged)")
    func decodeResponseCrisisNull() throws {
        let json = Data(#"""
        {"assessment":{"id":"mh3","instrument":"GAD7","locale":"en","version":"standard",
          "totalScore":8,"severityBand":"mild","item9Flagged":false,
          "crisisShownAt":null,"takenAt":"2026-06-28T08:00:00.000Z",
          "createdAt":"2026-06-28T08:00:00.000Z"},
         "actionThreshold":10,"crisis":null}
        """#.utf8)
        let resp = try JSONDecoder.hlDefault.decode(CreateAssessmentResponse.self, from: json)
        #expect(resp.assessment.item9Flagged == false)
        #expect(resp.crisis == nil)
    }

    // MARK: - Envelope unwrapping

    @Test("GET /api/mental-health/assessments unwraps data.assessments")
    func historyEnvelope() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/mental-health/assessments")
            #expect(req.httpMethod == "GET")
            let body = Data(#"""
            {"data":{"assessments":[
              {"id":"mh1","instrument":"PHQ9","locale":"en","version":"standard",
               "totalScore":2,"severityBand":"minimal","item9Flagged":false,
               "crisisShownAt":null,"takenAt":"2026-06-28T08:00:00.000Z",
               "createdAt":"2026-06-28T08:00:00.000Z"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo(outbox: OutboxQueue(inMemory: true))
        let history = try await repo.history()
        #expect(history.count == 1)
        #expect(history.first?.instrument == .phq9)
    }

    @Test("SCI row round-trips through DTO decoding")
    func decodeSciRow() throws {
        let json = Data(#"""
        {"id":"sci1","instrument":"SCI","locale":"en","version":"standard",
         "totalScore":17,"severityBand":"aboveThreshold","item9Flagged":false,
         "crisisShownAt":null,"takenAt":"2026-07-20T08:00:00.000Z",
         "createdAt":"2026-07-20T08:00:00.000Z"}
        """#.utf8)

        let dto = try JSONDecoder.hlDefault.decode(MentalHealthAssessmentDTO.self, from: json)
        let encoded = try JSONEncoder.hlDefault.encode(dto)
        let decoded = try JSONDecoder.hlDefault.decode(MentalHealthAssessmentDTO.self, from: encoded)

        #expect(decoded.instrument == .sci)
        #expect(decoded.totalScore == 17)
        #expect(decoded.severityBand == "aboveThreshold")
    }

    @Test("Instrument-filtered history sends the exact SCI query")
    func filteredSciHistoryQuery() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/mental-health/assessments")
            let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "instrument" })?.value == "SCI")
            #expect(query?.first(where: { $0.name == "limit" })?.value == "40")
            #expect(query?.first(where: { $0.name == "offset" })?.value == "0")
            let body = Data(#"""
            {"data":{"assessments":[
              {"id":"sci1","instrument":"SCI","locale":"en","version":"standard",
               "totalScore":21,"severityBand":"aboveThreshold","item9Flagged":false,
               "crisisShownAt":null,"takenAt":"2026-07-20T08:00:00.000Z",
               "createdAt":"2026-07-20T08:00:00.000Z"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let repo = try makeRepo(outbox: OutboxQueue(inMemory: true))
        let history = try await repo.history(instrument: .sci, limit: 40)

        #expect(history.map(\.instrument) == [.sci])
        #expect(history.map(\.id) == ["sci1"])
    }

    // MARK: - POST request shape

    @Test("submit POSTs the exact body { instrument, items, functionalDifficulty?, locale } + an Idempotency-Key")
    func submitRequestShape() async throws {
        let probe = MHRequestProbe()
        MockURLProtocol.handler = { req in
            probe.capture(req)
            let body = Data(#"""
            {"data":{"assessment":{"id":"mh9","instrument":"PHQ9","locale":"en","version":"standard",
              "totalScore":6,"severityBand":"mild","item9Flagged":false,"crisisShownAt":null,
              "takenAt":"2026-06-28T08:00:00.000Z","createdAt":"2026-06-28T08:00:00.000Z"},
             "actionThreshold":10,"crisis":null},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo(outbox: OutboxQueue(inMemory: true))
        let req = CreateAssessmentRequest(
            instrument: .phq9,
            items: [1, 1, 1, 0, 1, 0, 1, 0, 1],
            functionalDifficulty: 2,
            locale: "en",
            source: "IOS",
            externalId: "ext-abc-123"
        )
        _ = try await repo.submit(req)

        #expect(probe.method == "POST")
        #expect(probe.path == "/api/mental-health/assessments")
        #expect(probe.idempotencyKey?.isEmpty == false)
        // #39 — the idempotency-key header is BOUND to the body externalId so a
        // >24h outbox replay still dedups to one administration.
        #expect(probe.idempotencyKey == "ext-abc-123")
        let json = try probe.bodyJSON()
        #expect(json["instrument"] as? String == "PHQ9")
        #expect((json["items"] as? [Int])?.count == 9)
        #expect(json["functionalDifficulty"] as? Int == 2)
        #expect(json["locale"] as? String == "en")
        // #39 — client provenance + durable idempotency id on the wire.
        #expect(json["source"] as? String == "IOS")
        #expect(json["externalId"] as? String == "ext-abc-123")
        // userId is NEVER a body field.
        #expect(json["userId"] == nil)
    }

    // MARK: - Outbox durability

    @Test("A retriable (503) submit failure enqueues createMentalHealthAssessment + re-throws")
    func retriableSubmitEnqueues() async throws {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let outbox = try OutboxQueue(inMemory: true)
        let repo = makeRepo(outbox: outbox)
        let req = CreateAssessmentRequest(instrument: .phq9, items: Array(repeating: 0, count: 9), locale: "en")

        await #expect(throws: HLError.self) {
            _ = try await repo.submit(req)
        }
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.kind == .createMentalHealthAssessment)
    }
}

/// Captures the method / path / Idempotency-Key / body of the last stubbed
/// request so the submit test can assert the exact wire shape. `httpBody` is nil
/// for `URLSession` stream uploads, so the body is read from `httpBodyStream`.
private final class MHRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _method: String?
    private var _path: String?
    private var _key: String?
    private var _body: Data?

    func capture(_ req: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        _method = req.httpMethod
        _path = req.url?.path
        _key = req.value(forHTTPHeaderField: "Idempotency-Key")
        if let body = req.httpBody {
            _body = body
        } else if let stream = req.httpBodyStream {
            _body = MHRequestProbe.drain(stream)
        }
    }

    var method: String? {
        lock.lock()
        defer { lock.unlock() }
        return _method
    }

    var path: String? {
        lock.lock()
        defer { lock.unlock() }
        return _path
    }

    var idempotencyKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return _key
    }

    func bodyJSON() throws -> [String: Any] {
        lock.lock()
        let data = _body
        lock.unlock()
        guard let data, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
