import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// #151 (server v1.46.0) — document reads that may run in the background.
///
/// `extract` and `index` always send `Prefer: respond-async` and handle both
/// answers: 200 (an older server, or one that could not apply the preference)
/// with the synchronous body, and 202 with a run polled through
/// `GET /api/ai-runs/{id}`. Plus the honest limits: `extractionIncomplete` /
/// `incomplete`, `documents.inbound.outputLimit`, 503 `aiRuns.readerBusy` and
/// `lastIndexOutcome: resource-limit`. Real `APIClient` + stub `URLProtocol`.
@Suite(
    "Document reads: background runs and honest limits (#151)",
    .serialized,
    .mockURLSession,
    .timeLimit(.minutes(1))
)
struct DocumentsReadRunTests {
    private func makeRepo() -> DocumentsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let lease = DocumentAIConsentLease(ownerUserID: "user-A", bearerToken: "lease-token", scope: .serverManaged)
        return DocumentsRepository(
            api: APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock()),
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
    }

    private func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static func detailJSON(id: String = "d1", incomplete: Bool? = nil, outcome: String? = nil) -> String {
        var extra = ""
        if let incomplete { extra += #","extractionIncomplete":\#(incomplete)"# }
        if let outcome { extra += #","lastIndexOutcome":"\#(outcome)""# }
        return #"""
        {"id":"\#(id)","kind":"LAB_RESULT","title":"Labor","filename":"labor.pdf","mimeType":"application/pdf",
         "byteSize":10,"status":"EXTRACTED","providerType":null,"reportDate":null,"documentDate":null,
         "errorReason":null,"factCount":2,"pendingCount":2,"conditionLinks":[],"servingClass":"inline",
         "createdAt":"2026-11-01T09:00:00.000Z","updatedAt":"2026-11-01T09:00:00.000Z","facts":[]\#(extra)}
        """#
    }

    private static func run(_ status: String, result: String = "null", error: String = "null") -> String {
        #"""
        {"data":{"id":"run-1","kind":"DOCUMENT_EXTRACT","documentId":"d1","status":"\#(status)",
         "result":\#(result),"error":\#(error),"createdAt":"2026-11-01T09:00:00.000Z",
         "startedAt":null,"finishedAt":null,"queuedForMs":null,"retryAfterMs":0},"error":null}
        """#
    }

    private static let accepted = #"{"data":{"runId":"run-1","status":"QUEUED","pollAfterMs":0},"error":null}"#

    // MARK: - extract

    @Test("extract sends Prefer respond-async; a 200 answer is used as before (server without runs)")
    func extractSyncAnswer() async throws {
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/extract")
            #expect(req.value(forHTTPHeaderField: "Prefer") == "respond-async")
            // VISION mode still sends no body, so it reaches the vision handler.
            #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer lease-token")
            return reply(req, #"{"data":\#(Self.detailJSON()),"error":null}"#)
        }
        let detail = try await makeRepo().extract(id: "d1")
        #expect(detail.document.id == "d1")
        // Server without the field: complete.
        #expect(detail.extractionIncomplete == false)
    }

    @Test("A synchronous answer that read only part of the document says so")
    func extractSyncIncomplete() async throws {
        MockURLProtocol.install { req in
            reply(req, #"{"data":\#(Self.detailJSON(incomplete: true)),"error":null}"#)
        }
        let detail = try await makeRepo().extract(id: "d1")
        #expect(detail.extractionIncomplete)
    }

    @Test("extract 202: polls the run until it ends, then reads the document; incomplete carries over")
    func extractBackgroundRun() async throws {
        let polls = Mutex(0)
        let paths = Mutex<[String]>([])
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            paths.withLock { $0.append("\(req.httpMethod ?? "") \(path)") }
            switch path {
            case "/api/documents/inbound/d1/extract":
                return reply(req, Self.accepted, status: 202)
            case "/api/ai-runs/run-1":
                let count = polls.withLock { value -> Int in
                    value += 1
                    return value
                }
                if count == 1 { return reply(req, Self.run("QUEUED")) }
                if count == 2 { return reply(req, Self.run("RUNNING")) }
                return reply(req, Self.run(
                    "SUCCEEDED",
                    result: #"{"documentId":"d1","factsStaged":2,"status":"EXTRACTED","incomplete":true}"#
                ))
            default:
                // The run carries a summary only; the document comes from GET.
                return reply(req, #"{"data":\#(Self.detailJSON()),"error":null}"#)
            }
        }
        let detail = try await makeRepo().extract(id: "d1")
        #expect(detail.document.factCount == 2)
        #expect(detail.extractionIncomplete)
        #expect(polls.withLock { $0 } == 3)
        #expect(paths.withLock { $0 } == [
            "POST /api/documents/inbound/d1/extract",
            "GET /api/ai-runs/run-1",
            "GET /api/ai-runs/run-1",
            "GET /api/ai-runs/run-1",
            "GET /api/documents/inbound/d1"
        ])
    }

    @Test("A run that fails with outputLimit throws the same error the request would")
    func extractRunOutputLimit() async {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/ai-runs/run-1" {
                return reply(req, Self.run(
                    "FAILED",
                    error: #"{"code":"documents.inbound.outputLimit","message":"limit","status":422}"#
                ))
            }
            return reply(req, Self.accepted, status: 202)
        }
        do {
            _ = try await makeRepo().extract(id: "d1")
            Issue.record("expected the run's failure")
        } catch {
            #expect(DocumentsRepository.isOutputLimit(error))
            #expect(DocumentReadNotice.from(error: error) == .outputLimit)
        }
    }

    @Test("outputLimit answered synchronously reads the same")
    func extractSyncOutputLimit() async {
        MockURLProtocol.install { req in
            reply(
                req,
                #"{"data":null,"error":"limit","meta":{"errorCode":"documents.inbound.outputLimit"}}"#,
                status: 422
            )
        }
        do {
            _ = try await makeRepo().extract(id: "d1")
            Issue.record("expected outputLimit")
        } catch {
            #expect(DocumentsRepository.isOutputLimit(error))
        }
    }

    // MARK: - index

    @Test("index sends Prefer respond-async and keeps the 200 body (server without runs)")
    func indexSyncAnswer() async throws {
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/index")
            #expect(req.value(forHTTPHeaderField: "Prefer") == "respond-async")
            return reply(req, #"{"data":{"documentId":"d1","indexed":true,"tokenCount":12},"error":null}"#)
        }
        let result = try await makeRepo().index(id: "d1")
        #expect(result.indexed)
        #expect(result.tokenCount == 12)
    }

    @Test("index 202: the run's result is the index body")
    func indexBackgroundRun() async throws {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/ai-runs/run-1" {
                return reply(req, Self.run(
                    "SUCCEEDED",
                    result: #"{"documentId":"d1","indexed":true,"tokenCount":40,"labFactsStaged":3}"#
                ))
            }
            return reply(req, Self.accepted, status: 202)
        }
        let result = try await makeRepo().index(id: "d1")
        #expect(result.indexed)
        #expect(result.tokenCount == 40)
    }

    @Test("index in text mode sends the JSON body together with the preference")
    func indexTextMode() async throws {
        MockURLProtocol.install { req in
            #expect(req.value(forHTTPHeaderField: "Prefer") == "respond-async")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = req.httpBody ?? req.drainedBodyStream() ?? Data()
            #expect(String(data: body, encoding: .utf8)?.contains(#""mode":"text""#) == true)
            return reply(req, #"{"data":{"documentId":"d1","indexed":true,"tokenCount":1},"error":null}"#)
        }
        _ = try await makeRepo().index(id: "d1", text: DocumentAiTextRequest(text: "Hb 14"))
    }

    // MARK: - readerBusy

    @Test("503 readerBusy, answered at once or by the run, is recognised as busy", arguments: [false, true])
    func readerBusy(viaRun: Bool) async {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/ai-runs/run-1" {
                return reply(req, Self.run(
                    "FAILED",
                    error: #"{"code":"aiRuns.readerBusy","message":"busy","status":503}"#
                ))
            }
            if viaRun { return reply(req, Self.accepted, status: 202) }
            return reply(
                req,
                #"{"data":null,"error":"busy","meta":{"errorCode":"aiRuns.readerBusy"}}"#,
                status: 503
            )
        }
        do {
            _ = try await makeRepo().index(id: "d1")
            Issue.record("expected readerBusy")
        } catch {
            #expect(DocumentsRepository.isReaderBusy(error))
            #expect(DocumentReadNotice.from(error: error) == .readerBusy)
            let sentence = await MainActor.run { DocumentDetailScreen.assistErrorMessage(error) }
            #expect(sentence == String(localized: "documents.read.readerBusy"))
        }
    }

    @Test("A failed run with a rate limit reads as the rate limit")
    func runRateLimited() async {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/ai-runs/run-1" {
                return reply(req, Self.run(
                    "FAILED",
                    error: #"{"code":"documents.inbound.budgetExceeded","message":"budget","status":429}"#
                ))
            }
            return reply(req, Self.accepted, status: 202)
        }
        do {
            _ = try await makeRepo().index(id: "d1")
            Issue.record("expected the rate limit")
        } catch {
            guard case HLError.rateLimited = error else {
                Issue.record("expected HLError.rateLimited, got \(error)")
                return
            }
        }
    }

    // MARK: - Decoding: incomplete, resource-limit, older server

    @Test("lastIndexOutcome resource-limit means too large; absent or other is not")
    func resourceLimitDecode() throws {
        let tooLarge = try JSONDecoder.hlDefault.decode(
            InboundDocumentDetail.self, from: Data(Self.detailJSON(outcome: "resource-limit").utf8)
        )
        #expect(tooLarge.document.isTooLargeToRead)
        #expect(tooLarge.document.lastIndexOutcome == "resource-limit")

        let other = try JSONDecoder.hlDefault.decode(
            InboundDocumentDetail.self, from: Data(Self.detailJSON(outcome: "provider-error").utf8)
        )
        #expect(other.document.isTooLargeToRead == false)

        // Server without the field.
        let older = try JSONDecoder.hlDefault.decode(InboundDocumentDetail.self, from: Data(Self.detailJSON().utf8))
        #expect(older.document.lastIndexOutcome == nil)
        #expect(older.extractionIncomplete == false)

        // A wrong-typed value costs the field, never the document.
        let odd = Self.detailJSON().replacingOccurrences(
            of: #""facts":[]"#, with: #""facts":[],"lastIndexOutcome":42,"extractionIncomplete":"yes""#
        )
        let tolerant = try JSONDecoder.hlDefault.decode(InboundDocumentDetail.self, from: Data(odd.utf8))
        #expect(tolerant.document.lastIndexOutcome == nil)
        #expect(tolerant.extractionIncomplete == false)
    }

    @Test("A document encoded by 1.4.1 (no lastIndexOutcome key) still decodes, and the new field round-trips")
    func documentShapeFrom141() throws {
        let old = InboundDocument(
            id: "d1", kind: .labResult, title: nil, filename: "a.pdf", mimeType: "application/pdf",
            byteSize: 1, status: .stored, providerType: nil, reportDate: nil, documentDate: nil,
            errorReason: nil, factCount: 0, pendingCount: 0, conditionLinks: [], servingClass: .inline,
            createdAt: "2026-11-01T09:00:00.000Z", updatedAt: "2026-11-01T09:00:00.000Z"
        )
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(old)) as? [String: Any]
        )
        json.removeValue(forKey: "lastIndexOutcome")
        let decoded = try JSONDecoder.hlDefault.decode(
            InboundDocument.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.lastIndexOutcome == nil)
        #expect(decoded.isTooLargeToRead == false)

        let tooLarge = InboundDocument(
            id: "d2", kind: .labResult, title: nil, filename: nil, mimeType: "application/pdf",
            byteSize: 1, status: .stored, providerType: nil, reportDate: nil, documentDate: nil,
            errorReason: nil, factCount: 0, pendingCount: 0, conditionLinks: [], servingClass: .inline,
            lastIndexOutcome: "resource-limit",
            createdAt: "2026-11-01T09:00:00.000Z", updatedAt: "2026-11-01T09:00:00.000Z"
        )
        let roundTrip = try JSONDecoder.hlDefault.decode(
            InboundDocument.self, from: JSONEncoder.hlDefault.encode(tooLarge)
        )
        #expect(roundTrip.isTooLargeToRead)
    }

    @Test("Notices have their own sentences, none of them the raw key")
    func noticeSentences() {
        for notice in [DocumentReadNotice.readerBusy, .outputLimit, .tooLarge] {
            #expect(!notice.message.isEmpty)
            #expect(!notice.message.hasPrefix("documents.read."))
        }
        #expect(DocumentReadNotice.from(error: HLError.server(status: 500, code: nil, message: "x")) == nil)
    }

    @Test("The wait between polls is bounded on both sides")
    func pollDelayBounds() {
        #expect(DocumentsRepository.clampedPollDelay(.zero) == DocumentsRepository.minimumPollDelay)
        #expect(DocumentsRepository.clampedPollDelay(.seconds(600)) == DocumentsRepository.maximumPollDelay)
        #expect(DocumentsRepository.clampedPollDelay(.seconds(2)) == .seconds(2))
    }
}

private extension URLRequest {
    /// `URLSession` hands the body over as a stream here; read it back whole.
    func drainedBodyStream() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// swiftlint:enable force_unwrapping
