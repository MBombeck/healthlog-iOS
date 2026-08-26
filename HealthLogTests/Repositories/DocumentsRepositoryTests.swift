import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the documents DATA layer against the server contract: DTO tolerant
/// decode (unknown kind → OTHER, unknown servingClass → attachment, flexible
/// numeric byteSize), envelope unwrapping, the list facets, usage pre-flight, the
/// upload idempotency + sha256-duplicate 200, restore 409, bulk per-id results,
/// and the `403 module.disabled` discriminator. Real `APIClient` + stub
/// `URLProtocol` (no mock server) per PROJECT_GUIDE.md.
@Suite("Documents data layer", .serialized)
struct DocumentsRepositoryTests {
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

    // MARK: - DTO decode

    @Test("Document decodes; unknown kind → OTHER, unknown servingClass → attachment")
    func decodeDocumentTolerant() throws {
        let json = Data(#"""
        {"id":"d1","kind":"NEW_SERVER_KIND","title":"Brief","filename":"brief.pdf",
         "mimeType":"application/pdf","byteSize":12345,"status":"STORED","providerType":null,
         "reportDate":null,"documentDate":"2026-03-04","errorReason":null,"factCount":0,
         "pendingCount":0,"conditionLinks":[{"episodeId":"e1","name":"Grippe"}],
         "servingClass":"FUTURE_CLASS","createdAt":"2026-03-04T09:00:00.000Z",
         "updatedAt":"2026-03-04T09:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(InboundDocument.self, from: json)
        #expect(dto.kind == .other)
        #expect(dto.servingClass == .attachment)
        #expect(dto.byteSize == 12345)
        #expect(dto.documentDate == "2026-03-04")
        #expect(dto.conditionLinks.first?.name == "Grippe")
    }

    @Test("Document decodes a fractional / stringified byteSize")
    func decodeFlexibleByteSize() throws {
        let json = Data(#"""
        {"id":"d2","kind":"LAB_RESULT","title":null,"filename":null,"mimeType":"image/png",
         "byteSize":2048.0,"status":"STORED","providerType":null,"reportDate":null,
         "documentDate":null,"errorReason":null,"factCount":0,"pendingCount":0,
         "conditionLinks":[],"servingClass":"inline","createdAt":"2026-03-04T09:00:00.000Z",
         "updatedAt":"2026-03-04T09:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(InboundDocument.self, from: json)
        #expect(dto.byteSize == 2048)
        #expect(dto.servingClass == .inline)
        #expect(dto.resolvedTitle == nil)
    }

    @Test("Detail decodes flattened document + staged facts")
    func decodeDetailWithFacts() throws {
        let json = Data(#"""
        {"id":"d3","kind":"LAB_RESULT","title":"Labor","filename":"lab.pdf","mimeType":"application/pdf",
         "byteSize":10,"status":"EXTRACTED","providerType":"anthropic","reportDate":"2026-02-01",
         "documentDate":"2026-02-01","errorReason":null,"factCount":1,"pendingCount":1,
         "conditionLinks":[],"servingClass":"inline","createdAt":"2026-02-01T09:00:00.000Z",
         "updatedAt":"2026-02-01T09:00:00.000Z",
         "facts":[{"id":"f1","factType":"OBSERVATION","status":"PENDING","confidence":0.4,
           "needsReview":true,"data":{"label":"Hämoglobin","value":13.2},
           "provenance":{"sourceText":"Hb 13.2","page":1,"confidence":0.4},
           "committedRecordId":null,"committedRecordType":null}]}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(InboundDocumentDetail.self, from: json)
        #expect(dto.document.id == "d3")
        #expect(dto.facts.count == 1)
        #expect(dto.facts.first?.needsReview == true)
        #expect(dto.facts.first?.summaryLabel == "Hämoglobin")
    }

    // MARK: - List facets

    @Test("List sends q / kind (repeated) / episodeId / year + server-pinned sort")
    func listFacets() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound")
            let query = req.url?.query ?? ""
            #expect(query.contains("q=Blut"))
            #expect(query.contains("kind=LAB_RESULT"))
            #expect(query.contains("kind=IMAGING"))
            #expect(query.contains("episodeId=e9"))
            #expect(query.contains("year=2026"))
            #expect(query.contains("sort=documentDate"))
            #expect(query.contains("order=desc"))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"documents":[],"nextCursor":null},"error":null}"#.utf8)
            )
        }
        let repo = makeRepo()
        let page = try await repo.list(
            filter: DocumentListFilter(q: "Blut", kinds: [.labResult, .imaging], episodeId: "e9", year: 2026)
        )
        #expect(page.documents.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("Usage decodes limits + linked episodes and computes headroom")
    func usageDecode() async throws {
        MockURLProtocol.handler = { req in
            ok(req, #"""
            {"data":{"usedBytes":800,"quotaBytes":1000,"maxFileBytes":500,
             "acceptedExtensions":[".pdf",".jpg"],
             "linkedEpisodes":[{"episodeId":"e1","name":"Grippe"}]},"error":null}
            """#)
        }
        let usage = try await makeRepo().usage()
        #expect(usage.remainingBytes == 200)
        #expect(usage.maxFileBytes == 500)
        #expect(usage.acceptedExtensions.contains(".pdf"))
        #expect(usage.usedFraction == 0.8)
    }

    // MARK: - Upload

    @Test("Upload pre-flight rejects an over-cap file before the network")
    func uploadPreflightFileTooLarge() async throws {
        MockURLProtocol.handler = { _ in Issue.record("upload must not hit the network")
            throw URLError(.badURL)
        }
        let repo = makeRepo()
        let usage = DocumentUsage(
            usedBytes: 0, quotaBytes: 1_000_000, maxFileBytes: 10,
            acceptedExtensions: [], linkedEpisodes: []
        )
        let draft = DocumentUploadDraft(data: Data(count: 100), filename: "big.pdf", mimeType: "application/pdf")
        do {
            _ = try await repo.upload(draft, usage: usage)
            Issue.record("expected fileTooLarge")
        } catch let DocumentUploadError.fileTooLarge(maxFileBytes) {
            #expect(maxFileBytes == 10)
        }
    }

    @Test("Upload pre-flight rejects when the file would exceed remaining quota")
    func uploadPreflightQuota() async throws {
        MockURLProtocol.handler = { _ in Issue.record("upload must not hit the network")
            throw URLError(.badURL)
        }
        let repo = makeRepo()
        let usage = DocumentUsage(
            usedBytes: 950, quotaBytes: 1000, maxFileBytes: 1_000_000,
            acceptedExtensions: [], linkedEpisodes: []
        )
        let draft = DocumentUploadDraft(data: Data(count: 100), filename: "f.pdf", mimeType: "application/pdf")
        do {
            _ = try await repo.upload(draft, usage: usage)
            Issue.record("expected quotaExceeded")
        } catch let DocumentUploadError.quotaExceeded(quotaBytes, usedBytes) {
            #expect(quotaBytes == 1000)
            #expect(usedBytes == 950)
        }
    }

    @Test("Upload carries an Idempotency-Key + multipart body and maps a 200 duplicate")
    func uploadDuplicate200() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound")
            #expect(req.httpMethod == "POST")
            #expect(req.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
            #expect(req.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
            return ok(req, #"""
            {"data":{"id":"dup1","kind":"OTHER","title":null,"filename":"f.pdf","mimeType":"application/pdf",
             "byteSize":3,"status":"STORED","providerType":null,"reportDate":null,"documentDate":null,
             "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
             "createdAt":"2026-03-04T09:00:00.000Z","updatedAt":"2026-03-04T09:00:00.000Z"},
             "meta":{"duplicate":true},"error":null}
            """#, status: 200)
        }
        let outcome = try await makeRepo().upload(
            DocumentUploadDraft(data: Data([1, 2, 3]), filename: "f.pdf", mimeType: "application/pdf"),
            usage: nil
        )
        #expect(outcome.isDuplicate)
        #expect(outcome.document.id == "dup1")
    }

    @Test("Upload maps a 201 as a fresh (non-duplicate) store")
    func uploadCreated201() async throws {
        MockURLProtocol.handler = { req in
            ok(req, #"""
            {"data":{"id":"new1","kind":"OTHER","title":null,"filename":"f.pdf","mimeType":"application/pdf",
             "byteSize":3,"status":"STORED","providerType":null,"reportDate":null,"documentDate":null,
             "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
             "createdAt":"2026-03-04T09:00:00.000Z","updatedAt":"2026-03-04T09:00:00.000Z"},"error":null}
            """#, status: 201)
        }
        let outcome = try await makeRepo().upload(
            DocumentUploadDraft(data: Data([1, 2, 3]), filename: "f.pdf", mimeType: "application/pdf"),
            usage: nil
        )
        #expect(!outcome.isDuplicate)
        #expect(outcome.document.id == "new1")
    }

    @Test("Upload maps a 415 to unsupportedType")
    func upload415() async throws {
        MockURLProtocol.handler = { req in
            ok(req, #"{"data":null,"error":"unsupported"}"#, status: 415)
        }
        do {
            _ = try await makeRepo().upload(
                DocumentUploadDraft(data: Data([1]), filename: "x.bin", mimeType: "application/octet-stream"),
                usage: nil
            )
            Issue.record("expected unsupportedType")
        } catch {
            #expect(error as? DocumentUploadError == .unsupportedType)
        }
    }

    // MARK: - Restore / bulk

    @Test("Restore surfaces a 409 conflict via the discriminator")
    func restore409() async throws {
        MockURLProtocol.handler = { req in
            ok(req, #"{"data":null,"error":"duplicate exists","meta":{"errorCode":"conflict"}}"#, status: 409)
        }
        do {
            _ = try await makeRepo().restore(id: "d1")
            Issue.record("expected 409")
        } catch {
            #expect(DocumentsRepository.isRestoreConflict(error))
        }
    }

    @Test("Bulk returns per-id results (partial failure preserved)")
    func bulkPerIdResults() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/documents/inbound/bulk")
            return ok(req, #"""
            {"data":{"results":[{"id":"a","ok":true,"error":null},
             {"id":"b","ok":false,"error":"notFound"}]},"error":null}
            """#)
        }
        let response = try await makeRepo().bulk(ids: ["a", "b"], action: .delete)
        #expect(response.okCount == 1)
        #expect(response.failedCount == 1)
        #expect(response.results.first { $0.id == "b" }?.error == "notFound")
    }

    // MARK: - Module gate

    @Test("A 403 module.disabled is recognised so the surface renders the enable CTA")
    func moduleDisabled403() async throws {
        MockURLProtocol.handler = { req in
            ok(
                req,
                #"{"data":null,"error":"disabled","meta":{"errorCode":"module.disabled","module":"inboundDocuments"}}"#,
                status: 403
            )
        }
        do {
            _ = try await makeRepo().list()
            Issue.record("expected 403 module disabled")
        } catch {
            #expect(DocumentsRepository.isModuleDisabled(error))
        }
    }

    // MARK: - Filter helper

    @Test("DocumentListFilter counts active facets (search + each kind + episode + year)")
    func filterActiveCount() {
        let filter = DocumentListFilter(q: "x", kinds: [.labResult, .imaging], episodeId: "e1", year: 2026)
        #expect(filter.isActive)
        #expect(filter.activeCount == 5)
        #expect(DocumentListFilter().activeCount == 0)
    }
}
