import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The `DocumentsStore` behaviour: load populates the snapshot + usage, a `403
/// module.disabled` flips `isDisabled` (enable-CTA), the filter derives active
/// facets, a duplicate upload flags the row, and `clearOnLogout` purges the PHI
/// snapshot. Real `APIClient` + stub `URLProtocol` per PROJECT_GUIDE.md.
@MainActor
@Suite("Documents store", .serialized)
struct DocumentsStoreTests {
    private func makeStore() -> DocumentsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let lease = DocumentAIConsentLease(
            ownerUserID: "test-user",
            bearerToken: "token",
            scope: .serverManaged
        )
        let repository = DocumentsRepository(
            api: api,
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
        return DocumentsStore(repository: repository)
    }

    private nonisolated func json(_ req: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private nonisolated static let usageBody = #"""
    {"data":{"usedBytes":0,"quotaBytes":1000,"maxFileBytes":500,"acceptedExtensions":[".pdf"],
     "linkedEpisodes":[{"episodeId":"e1","name":"Grippe"}]},"error":null}
    """#

    private nonisolated static let listBody = #"""
    {"data":{"documents":[
     {"id":"d1","kind":"LAB_RESULT","title":"Labor","filename":"lab.pdf","mimeType":"application/pdf",
      "byteSize":10,"status":"STORED","providerType":null,"reportDate":null,"documentDate":"2026-05-01",
      "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
      "createdAt":"2026-05-01T09:00:00.000Z","updatedAt":"2026-05-01T09:00:00.000Z"}
    ],"nextCursor":null},"error":null}
    """#

    @Test("load populates documents + usage; condition chips come from usage")
    func loadPopulates() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/documents/inbound/usage" {
                return json(req, Self.usageBody)
            }
            return json(req, Self.listBody)
        }
        let store = makeStore()
        await store.load()
        #expect(store.documents.count == 1)
        #expect(store.usage?.quotaBytes == 1000)
        #expect(store.conditionChips.first?.name == "Grippe")
        #expect(store.years == [2026])
        #expect(!store.isDisabled)
    }

    @Test("A 403 module.disabled flips isDisabled + clears the snapshot")
    func moduleDisabled() async {
        MockURLProtocol.handler = { req in
            json(
                req,
                #"{"data":null,"error":"off","meta":{"errorCode":"module.disabled","module":"inboundDocuments"}}"#,
                status: 403
            )
        }
        let store = makeStore()
        await store.load()
        #expect(store.isDisabled)
        #expect(store.documents.isEmpty)
    }

    @Test("clearOnLogout purges the in-memory snapshot")
    func logoutWipe() {
        let store = makeStore()
        let doc = InboundDocument(
            id: "d1", kind: .other, title: "t", filename: nil, mimeType: "application/pdf",
            byteSize: 1, status: .stored, providerType: nil, reportDate: nil, documentDate: nil,
            errorReason: nil, factCount: 0, pendingCount: 0, conditionLinks: [],
            servingClass: .inline, createdAt: "2026-05-01T09:00:00.000Z", updatedAt: "2026-05-01T09:00:00.000Z"
        )
        store.seedForTesting(
            documents: [doc],
            usage: DocumentUsage(usedBytes: 1, quotaBytes: 2, maxFileBytes: 1, acceptedExtensions: [], linkedEpisodes: []),
            selection: ["d1"]
        )
        #expect(!store.documents.isEmpty)
        store.clearOnLogout()
        #expect(store.documents.isEmpty)
        #expect(store.usage == nil)
        #expect(store.selection.isEmpty)
    }

    // MARK: - Phase 2 — assist gate (data half) + content index

    private nonisolated static let assistUsageBody = #"""
    {"data":{"usedBytes":0,"quotaBytes":1000,"maxFileBytes":500,"acceptedExtensions":[".pdf"],
     "linkedEpisodes":[],"assistAvailable":true,
     "contentIndex":{"enabled":true,"indexedCount":1,"totalCount":2}},"error":null}
    """#

    @Test("load reflects assistAvailable + contentIndex → the data half of the gate is open")
    func assistGateOpen() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/documents/inbound/usage" {
                return json(req, Self.assistUsageBody)
            }
            return json(req, Self.listBody)
        }
        let store = makeStore()
        await store.load()
        #expect(store.assistAvailable)
        #expect(store.contentIndexEnabled)
        #expect(store.usage?.contentIndex?.hasUnindexed == true)
    }

    @Test("A pre-P2 usage (no assist fields) keeps the gate closed → actions absent")
    func assistGateClosedWhenUnavailable() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/documents/inbound/usage" {
                // The existing pre-P2 usage body omits assistAvailable + contentIndex.
                return json(req, Self.usageBody)
            }
            return json(req, Self.listBody)
        }
        let store = makeStore()
        await store.load()
        // assistAvailable=false short-circuits the view gate regardless of consent.
        #expect(store.assistAvailable == false)
        #expect(store.contentIndexEnabled == false)
    }

    @Test("indexContent posts to /index and refreshes usage coverage")
    func indexContentRefreshesUsage() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/documents/inbound/d1/index" {
                return json(req, #"{"data":{"documentId":"d1","indexed":true,"tokenCount":9},"error":null}"#)
            }
            // The post-index usage refresh now reports full coverage.
            return json(req, #"""
            {"data":{"usedBytes":0,"quotaBytes":1000,"maxFileBytes":500,"acceptedExtensions":[],
             "linkedEpisodes":[],"assistAvailable":true,
             "contentIndex":{"enabled":true,"indexedCount":2,"totalCount":2}},"error":null}
            """#)
        }
        let store = makeStore()
        let result = try? await store.indexContent(id: "d1")
        #expect(result?.indexed == true)
        #expect(store.usage?.contentIndex?.indexedCount == 2)
        #expect(store.usage?.contentIndex?.hasUnindexed == false)
    }

    @Test("A duplicate upload flags the highlighted row")
    func uploadDuplicateHighlights() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/documents/inbound/usage" {
                return json(req, Self.usageBody)
            }
            if req.httpMethod == "POST" {
                return json(req, #"""
                {"data":{"id":"dup","kind":"OTHER","title":null,"filename":"f.pdf","mimeType":"application/pdf",
                 "byteSize":3,"status":"STORED","providerType":null,"reportDate":null,"documentDate":null,
                 "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
                 "createdAt":"2026-05-01T09:00:00.000Z","updatedAt":"2026-05-01T09:00:00.000Z"},
                 "meta":{"duplicate":true},"error":null}
                """#, status: 200)
            }
            return json(req, Self.listBody)
        }
        let store = makeStore()
        await store.upload(DocumentUploadDraft(data: Data([1, 2, 3]), filename: "f.pdf", mimeType: "application/pdf"))
        #expect(store.highlightedDocumentId == "dup")
        #expect(store.lastUploadError == nil)
    }
}
