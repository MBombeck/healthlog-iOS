import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the v1.18.1 labs DATA layer against the server contract: DTO decode
/// (incl. `biomarkerId` null/resolved + the NEUTRAL `rangeStatus`), envelope
/// unwrapping (`{ data: { results, meta } }` / `{ data: { biomarkers } }`),
/// the `GET /api/labs` filter-query build, the restore round-trip, and the
/// `403 module.disabled` discriminator. Real `APIClient` + stub `URLProtocol`
/// (no mock server) per PROJECT_GUIDE.md.
@Suite("Labs data layer (v1.18.1 W-LABS)", .serialized)
struct LabsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.9",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo() throws -> LabsRepository {
        try LabsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
    }

    // MARK: - DTO decode

    @Test("LabResult decodes a linked row (biomarkerId resolved + neutral status)")
    func decodeLinkedRow() throws {
        let json = Data(#"""
        {"id":"l1","biomarkerId":"bm1","panel":"Metabolic","analyte":"Glucose",
         "value":5.4,"unit":"mmol/L","referenceLow":3.9,"referenceHigh":5.6,
         "takenAt":"2026-06-10T08:00:00.000Z","source":"MANUAL","hasNote":true,
         "rangeStatus":"in-range","createdAt":"2026-06-10T08:00:00.000Z",
         "updatedAt":"2026-06-10T08:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(LabResultDTO.self, from: json)
        #expect(dto.id == "l1")
        #expect(dto.biomarkerId == "bm1")
        #expect(dto.isLinked)
        #expect(dto.value == 5.4)
        #expect(dto.rangeStatus == .inRange)
        #expect(dto.hasNote)
    }

    @Test("LabResult decodes a free-text row (biomarkerId null) + unknown status falls back")
    func decodeFreeTextRowAndUnknownStatus() throws {
        let json = Data(#"""
        {"id":"l2","biomarkerId":null,"panel":null,"analyte":"Custom marker",
         "value":12,"unit":"x","referenceLow":null,"referenceHigh":null,
         "takenAt":"2026-06-10T08:00:00.000Z","source":"MANUAL","hasNote":false,
         "rangeStatus":"totally-new-server-status","createdAt":"2026-06-10T08:00:00.000Z",
         "updatedAt":"2026-06-10T08:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(LabResultDTO.self, from: json)
        #expect(dto.biomarkerId == nil)
        #expect(!dto.isLinked)
        #expect(dto.referenceLow == nil)
        // Unknown wire status decodes to `.unknown` (tolerant) rather than failing.
        #expect(dto.rangeStatus == .unknown)
    }

    @Test("LabResultDetail decodes incl. decrypted note")
    func decodeDetail() throws {
        let json = Data(#"""
        {"id":"l3","biomarkerId":null,"panel":null,"analyte":"TSH","value":2.1,
         "unit":"mIU/L","referenceLow":0.4,"referenceHigh":4.0,
         "takenAt":"2026-06-10T08:00:00.000Z","source":"MANUAL",
         "rangeStatus":"below","createdAt":"2026-06-10T08:00:00.000Z",
         "updatedAt":"2026-06-10T08:00:00.000Z","note":"fasting"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(LabResultDetailDTO.self, from: json)
        #expect(dto.note == "fasting")
        #expect(dto.rangeStatus == .below)
    }

    @Test("Biomarker decodes + null bounds tolerated")
    func decodeBiomarker() throws {
        let json = Data(#"""
        {"id":"bm1","name":"Glucose","unit":"mmol/L","lowerBound":3.9,
         "upperBound":5.6,"panel":"Metabolic","hasContext":true,
         "context":"fasting only","createdAt":"2026-06-10T08:00:00.000Z",
         "updatedAt":"2026-06-10T08:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(BiomarkerDTO.self, from: json)
        #expect(dto.name == "Glucose")
        #expect(dto.lowerBound == 3.9)
        #expect(dto.context == "fasting only")
    }

    // MARK: - List envelope unwrap (data.results / data.biomarkers)

    @Test("GET /api/labs unwraps data.results + meta.total")
    func listLabsEnvelope() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/labs")
            let body = Data(#"""
            {"data":{"results":[
              {"id":"l1","biomarkerId":"bm1","panel":"Metabolic","analyte":"Glucose",
               "value":5.4,"unit":"mmol/L","referenceLow":3.9,"referenceHigh":5.6,
               "takenAt":"2026-06-10T08:00:00.000Z","source":"MANUAL","hasNote":false,
               "rangeStatus":"in-range","createdAt":"2026-06-10T08:00:00.000Z",
               "updatedAt":"2026-06-10T08:00:00.000Z"}
             ],"meta":{"total":42,"limit":100,"offset":0}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let page = try await repo.labs()
        #expect(page.results.count == 1)
        #expect(page.results.first?.analyte == "Glucose")
        #expect(page.meta?.total == 42)
    }

    @Test("GET /api/biomarkers unwraps data.biomarkers")
    func listBiomarkersEnvelope() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/biomarkers")
            let body = Data(#"""
            {"data":{"biomarkers":[
              {"id":"bm1","name":"Glucose","unit":"mmol/L","lowerBound":3.9,
               "upperBound":5.6,"panel":null,"hasContext":false,"context":null,
               "createdAt":"2026-06-10T08:00:00.000Z","updatedAt":"2026-06-10T08:00:00.000Z"}
             ]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let list = try await repo.biomarkers()
        #expect(list.biomarkers.count == 1)
        #expect(list.biomarkers.first?.name == "Glucose")
    }

    // MARK: - Filter query build

    @Test("labs(biomarkerId:panel:) builds the right query")
    func filterQueryBuild() async throws {
        MockURLProtocol.handler = { req in
            let query = req.url?.query ?? ""
            #expect(query.contains("biomarkerId=bm1"))
            #expect(query.contains("panel=Metabolic"))
            #expect(query.contains("sortDir=desc"))
            let body = Data(#"{"data":{"results":[],"meta":{"total":0,"limit":100,"offset":0}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        _ = try await repo.labs(biomarkerId: "bm1", panel: "Metabolic")
    }

    // MARK: - Restore round-trip

    @Test("restoreLabs posts ids + returns restored count")
    func restoreRoundTrip() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/labs/restore")
            #expect(req.httpMethod == "POST")
            let body = Data(#"{"data":{"restored":2},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let restored = try await repo.restoreLabs(ids: ["l1", "l2"])
        #expect(restored == 2)
    }

    // MARK: - 403 module.disabled + 409 duplicate

    @Test("403 module.disabled(labs) is recognised by isLabsDisabled")
    func moduleDisabled() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Module disabled","meta":{"errorCode":"module.disabled","module":"labs"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        do {
            _ = try await repo.labs()
            Issue.record("expected a thrown error")
        } catch {
            #expect(LabsRepository.isLabsDisabled(error))
        }
    }

    @Test("409 on biomarker create is recognised as duplicate name")
    func duplicateName() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"A biomarker with this name already exists."}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        do {
            _ = try await repo.createBiomarker(BiomarkerCreate(name: "Glucose", unit: "mmol/L"))
            Issue.record("expected a 409")
        } catch {
            #expect(LabsRepository.isDuplicateName(error))
            #expect(!LabsRepository.isLabsDisabled(error))
        }
    }

    // MARK: - Biomarker write wire shapes (MOD-04 manage catalog)

    private static let biomarkerEnvelope = #"""
    {"data":{"id":"bm-new","name":"Ferritin","unit":"ng/mL","lowerBound":30,
     "upperBound":300,"panel":"Iron","hasContext":false,"context":null,
     "createdAt":"2026-06-19T08:00:00.000Z","updatedAt":"2026-06-19T08:00:00.000Z"}}
    """#

    @Test("createBiomarker POSTs /api/biomarkers with the body + an Idempotency-Key")
    func createBiomarkerWireShape() async throws {
        let probe = RequestProbe()
        MockURLProtocol.handler = { [env = Self.biomarkerEnvelope] req in
            probe.capture(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(env.utf8))
        }
        let repo = try makeRepo()
        let created = try await repo.createBiomarker(
            BiomarkerCreate(name: "Ferritin", unit: "ng/mL", lowerBound: 30, upperBound: 300, panel: "Iron")
        )
        #expect(created.id == "bm-new")
        #expect(probe.method == "POST")
        #expect(probe.path == "/api/biomarkers")
        #expect(probe.idempotencyKey?.isEmpty == false)
        let json = try probe.bodyJSON()
        #expect(json["name"] as? String == "Ferritin")
        #expect(json["unit"] as? String == "ng/mL")
        #expect((json["lowerBound"] as? NSNumber)?.doubleValue == 30)
        #expect((json["upperBound"] as? NSNumber)?.doubleValue == 300)
        #expect(json["panel"] as? String == "Iron")
    }

    @Test("updateBiomarker PUTs /api/biomarkers/{id} with the patch body")
    func updateBiomarkerWireShape() async throws {
        let probe = RequestProbe()
        MockURLProtocol.handler = { [env = Self.biomarkerEnvelope] req in
            probe.capture(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(env.utf8))
        }
        let repo = try makeRepo()
        // Build 3 / item 3.2 — clearable fields are tri-state now, so a SET
        // bound is spelled `.set(...)` rather than a bare optional.
        _ = try await repo.updateBiomarker(id: "bm-7", BiomarkerPatch(name: "Ferritin", upperBound: .set(400)))
        #expect(probe.method == "PUT")
        #expect(probe.path == "/api/biomarkers/bm-7")
        #expect(probe.idempotencyKey?.isEmpty == false)
        let json = try probe.bodyJSON()
        #expect(json["name"] as? String == "Ferritin")
        #expect((json["upperBound"] as? NSNumber)?.doubleValue == 400)
        // An omitted patch field is untouched (not sent), never an explicit null.
        #expect(json["unit"] == nil)
    }

    @Test("deleteBiomarker DELETEs /api/biomarkers/{id} (no Idempotency-Key header by contract)")
    func deleteBiomarkerWireShape() async throws {
        let probe = RequestProbe()
        MockURLProtocol.handler = { req in
            probe.capture(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":true}}"#.utf8)
            )
        }
        let repo = try makeRepo()
        try await repo.deleteBiomarker(id: "bm-9")
        #expect(probe.method == "DELETE")
        #expect(probe.path == "/api/biomarkers/bm-9")
        // `HTTPMethod.requiresIdempotency` deliberately excludes DELETE — a hard
        // delete is intrinsically idempotent, so no Idempotency-Key header is
        // sent (the outbox still keys the replay row for ordering/dedup).
        #expect(probe.idempotencyKey == nil)
    }
}

/// Captures the method / path / Idempotency-Key / body of the last stubbed
/// request so the biomarker write tests can assert the exact wire shape.
/// `httpBody` is nil for `URLSession` stream uploads, so the body is read from
/// `httpBodyStream` (the established `APIClient` idiom).
private final class RequestProbe: @unchecked Sendable {
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
            _body = RequestProbe.drain(stream)
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
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
