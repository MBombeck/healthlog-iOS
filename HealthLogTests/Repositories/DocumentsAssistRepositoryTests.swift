import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Vault Phase 2 (server v1.27.22, iOS issue #43) — the additive AI-assist +
/// content-search DATA layer: `hasContentIndex` + usage `assistAvailable` /
/// `contentIndex` tolerant decode, and the suggest / summary / index / reindex
/// round-trips (real `APIClient` + stub `URLProtocol`, no mock server, per
/// PROJECT_GUIDE.md). Split from `DocumentsRepositoryTests` to keep each suite under the
/// type-body-length ceiling.
@Suite("Documents assist data layer", .serialized)
struct DocumentsAssistRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo() -> DocumentsRepository {
        let lease = DocumentAIConsentLease(
            ownerUserID: "test-user",
            bearerToken: "test-token",
            scope: .serverManaged
        )
        return DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
    }

    private func ok(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    // MARK: - Phase 2 — hasContentIndex + usage assist/contentIndex decode

    @Test("Document decodes hasContentIndex; an older server omitting it → false")
    func decodeHasContentIndex() throws {
        let with = Data(#"""
        {"id":"d9","kind":"LAB_RESULT","title":null,"filename":null,"mimeType":"application/pdf",
         "byteSize":1,"status":"STORED","providerType":null,"reportDate":null,"documentDate":null,
         "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
         "hasContentIndex":true,"createdAt":"2026-03-04T09:00:00.000Z","updatedAt":"2026-03-04T09:00:00.000Z"}
        """#.utf8)
        #expect(try JSONDecoder.hlDefault.decode(InboundDocument.self, from: with).hasContentIndex)
        // The exact JSON the pre-P2 decodeDocumentTolerant test uses — no field.
        let without = Data(#"""
        {"id":"d8","kind":"LAB_RESULT","title":null,"filename":null,"mimeType":"application/pdf",
         "byteSize":1,"status":"STORED","providerType":null,"reportDate":null,"documentDate":null,
         "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
         "createdAt":"2026-03-04T09:00:00.000Z","updatedAt":"2026-03-04T09:00:00.000Z"}
        """#.utf8)
        #expect(try JSONDecoder.hlDefault.decode(InboundDocument.self, from: without).hasContentIndex == false)
    }

    @Test("Usage decodes Phase 2 assistAvailable + contentIndex")
    func usageDecodesAssistAndIndex() async throws {
        MockURLProtocol.handler = { req in
            ok(req, #"""
            {"data":{"usedBytes":0,"quotaBytes":1000,"maxFileBytes":500,"acceptedExtensions":[],
             "linkedEpisodes":[],"assistAvailable":true,
             "contentIndex":{"enabled":true,"indexedCount":3,"totalCount":5}},"error":null}
            """#)
        }
        let usage = try await makeRepo().usage()
        #expect(usage.assistAvailable)
        #expect(usage.contentIndex?.enabled == true)
        #expect(usage.contentIndex?.indexedCount == 3)
        #expect(usage.contentIndex?.totalCount == 5)
        #expect(usage.contentIndex?.hasUnindexed == true)
    }

    @Test("Usage from a pre-P2 server → assistAvailable false, contentIndex nil")
    func usagePreP2Tolerant() async throws {
        MockURLProtocol.handler = { req in
            ok(req, #"""
            {"data":{"usedBytes":0,"quotaBytes":1000,"maxFileBytes":500,
             "acceptedExtensions":[],"linkedEpisodes":[]},"error":null}
            """#)
        }
        let usage = try await makeRepo().usage()
        #expect(usage.assistAvailable == false)
        #expect(usage.contentIndex == nil)
    }

    // MARK: - Phase 2 — suggest / summary / index / reindex

    @Test("Suggest posts to /suggest and decodes the draft; unknown kind → nil")
    func suggestHappyPath() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/suggest")
            #expect(req.httpMethod == "POST")
            // Root-cause guard (issue #43): VISION mode must send NO JSON body /
            // Content-Type. The server dispatches on Content-Type — an
            // `application/json` request is routed to the TEXT (local-OCR)
            // handler, which fails immediately for a vision-only document. A
            // missing Content-Type keeps the request on the vision path.
            #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
            return ok(req, #"""
            {"data":{"suggestions":{"title":"Laborbericht","kind":"LAB_RESULT",
             "documentDate":"2026-02-01"}},"error":null}
            """#)
        }
        let s = try await makeRepo().suggest(id: "d1")
        #expect(s.title == "Laborbericht")
        #expect(s.kind == .labResult)
        #expect(s.documentDate == "2026-02-01")
        #expect(s.hasAny)

        MockURLProtocol.handler = { req in
            ok(req, #"""
            {"data":{"suggestions":{"title":null,"kind":"WEIRD_FUTURE_KIND",
             "documentDate":null}},"error":null}
            """#)
        }
        let unknown = try await makeRepo().suggest(id: "d1")
        // A suggestion (unlike a stored doc) is NOT coerced to .other — an
        // unreadable kind simply offers no kind row.
        #expect(unknown.kind == nil)
    }

    @Test("Summary passes ?mode= and decodes summary XOR text")
    func summaryModes() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/summary")
            #expect(req.url?.query?.contains("mode=summary") == true)
            // VISION mode: no JSON body / Content-Type (see suggestHappyPath).
            #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
            return ok(req, #"{"data":{"summary":"Kurzbeschreibung."},"error":null}"#)
        }
        let sum = try await makeRepo().summary(id: "d1", mode: .summary)
        #expect(sum.prose == "Kurzbeschreibung.")

        MockURLProtocol.handler = { req in
            #expect(req.url?.query?.contains("mode=text") == true)
            return ok(req, #"{"data":{"text":"Roher Text."},"error":null}"#)
        }
        let text = try await makeRepo().summary(id: "d1", mode: .text)
        #expect(text.prose == "Roher Text.")
    }

    @Test("Index posts to /index and decodes the result")
    func indexHappyPath() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/index")
            #expect(req.httpMethod == "POST")
            // VISION mode: no JSON body / Content-Type (see suggestHappyPath).
            #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
            return ok(req, #"{"data":{"documentId":"d1","indexed":true,"tokenCount":42},"error":null}"#)
        }
        let result = try await makeRepo().index(id: "d1")
        #expect(result.indexed)
        #expect(result.tokenCount == 42)
    }

    @Test("TEXT mode sends the JSON body + Content-Type (local-OCR path)")
    func textModeSendsJSONBody() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/d1/suggest")
            // TEXT mode routes to the server's local-OCR handler, which needs the
            // `{ mode, text }` JSON body + Content-Type.
            #expect(req.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
            return ok(req, #"{"data":{"suggestions":{"title":"T","kind":null,"documentDate":null}},"error":null}"#)
        }
        let s = try await makeRepo().suggest(id: "d1", text: DocumentAiTextRequest(text: "hello"))
        #expect(s.title == "T")
    }

    @Test("Reindex decodes enqueued from a bool or a numeric count")
    func reindexTolerant() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/reindex")
            return ok(req, #"{"data":{"enqueued":true},"error":null}"#)
        }
        #expect(try await makeRepo().reindexAll().enqueued)

        MockURLProtocol.handler = { req in
            ok(req, #"{"data":{"enqueued":3},"error":null}"#)
        }
        #expect(try await makeRepo().reindexAll().enqueued)
    }

    @Test("Suggest surfaces a 422 providerUnsupported via the discriminator")
    func suggestProviderUnsupported() async throws {
        MockURLProtocol.handler = { req in
            ok(
                req,
                #"{"data":null,"error":"no provider","meta":{"errorCode":"documents.inbound.providerUnsupported"}}"#,
                status: 422
            )
        }
        do {
            _ = try await makeRepo().suggest(id: "d1")
            Issue.record("expected 422 providerUnsupported")
        } catch {
            #expect(DocumentsRepository.isProviderUnsupported(error))
        }
    }
}
