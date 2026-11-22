import CoreGraphics

// swiftlint:disable force_unwrapping

@testable import HealthLog
import SwiftUI
import Testing

/// The selection of a list that shows its detail beside it (documents, labs).
/// It is the screen's state: it does not look at the width, and it resolves to
/// nothing as soon as the selected item is gone.
@Suite("Pane selection", .serialized, .mockURLSession)
@MainActor
struct DocumentsPaneSelectionTests {
    private let ids = ["a", "b", "c"]

    @Test("nothing selected resolves to nothing, or to the first where the detail is cheap")
    func empty() {
        let selection = HLPaneSelection<String>()
        #expect(selection.resolved(in: ids) == nil)
        #expect(selection.resolvedOrFirst(in: ids) == "a")
        #expect(selection.resolvedOrFirst(in: []) == nil)
    }

    @Test("the row is marked only where the preview stands beside the list")
    func markedOnlyBesideTheList() {
        var selection = HLPaneSelection<String>()
        selection.select("b")
        for width in AdaptiveWidths.all {
            let layout = HLListDetailLayout.resolve(width: width, typeSize: .large)
            let marked = selection.highlighted(isSideBySide: layout.isSideBySide, in: ids)
            #expect(marked == (layout.isSideBySide ? "b" : nil), "at \(width)")
            // The selection itself is the same at every width.
            #expect(selection.resolved(in: ids) == "b")
        }
        #expect(selection.highlighted(isSideBySide: true, in: ["a", "c"]) == nil, "a deleted row is not marked")
    }

    @Test("a deleted document falls away, the others are untouched")
    func fallsAwayOnDelete() {
        var selection = HLPaneSelection<String>()
        selection.select("b")
        let afterDelete = ["a", "c"]
        #expect(selection.resolved(in: afterDelete) == nil)
        // Where the first item stands in for none, it is the first that is left.
        #expect(selection.resolvedOrFirst(in: afterDelete) == "a")
        selection.select("c")
        #expect(selection.resolved(in: afterDelete) == "c")
    }

    @Test("a deletion that is undone brings the preview back")
    func undoRestoresPreview() {
        var selection = HLPaneSelection<String>()
        selection.select("b")
        #expect(selection.resolved(in: ["a", "c"]) == nil)
        #expect(selection.resolved(in: ids) == "b")
    }

    @Test("a filter that hides the selected document hides its preview too")
    func filterHidesSelection() {
        var selection = HLPaneSelection<String>()
        selection.select("c")
        #expect(selection.resolved(in: ["a"]) == nil)
        #expect(selection.resolved(in: []) == nil)
    }

    @Test("selecting nothing clears it")
    func clear() {
        var selection = HLPaneSelection<String>(selected: "a")
        selection.select(nil)
        #expect(selection.resolved(in: ids) == nil)
    }

    @Test("the real document ids drive it: delete the selected one from a list of documents")
    func withDocuments() throws {
        let documents = try ["d1", "d2", "d3"].map { id in
            try JSONDecoder.hlDefault.decode(InboundDocument.self, from: Data("""
            {"id":"\(id)","kind":"LAB_RESULT","title":"Befund \(id)","mimeType":"application/pdf","byteSize":1200,
             "status":"STORED","factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
             "createdAt":"2026-10-21T09:00:00Z","updatedAt":"2026-10-21T09:00:00Z"}
            """.utf8))
        }
        var selection = HLPaneSelection<String>()
        selection.select("d2")
        #expect(selection.resolved(in: documents.map(\.id)) == "d2")
        let remaining = documents.filter { $0.id != "d2" }
        #expect(selection.resolved(in: remaining.map(\.id)) == nil)
    }

    // MARK: - Against the real store

    private nonisolated static func documentJSON(_ id: String) -> String {
        """
        {"id":"\(id)","kind":"LAB_RESULT","title":"Befund \(id)","filename":"\(id).pdf","mimeType":"application/pdf",
         "byteSize":10,"status":"STORED","providerType":null,"reportDate":null,"documentDate":"2026-05-01",
         "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
         "createdAt":"2026-05-01T09:00:00.000Z","updatedAt":"2026-05-01T09:00:00.000Z"}
        """
    }

    private func makeStore() -> DocumentsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        let lease = DocumentAIConsentLease(ownerUserID: "test-user", bearerToken: "token", scope: .serverManaged)
        let repository = DocumentsRepository(
            api: api,
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )
        return DocumentsStore(repository: repository)
    }

    @Test("deleting the selected document through the store drops its preview; the neighbour stays selectable")
    func deleteThroughStore() async throws {
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            let body = if req.httpMethod == "DELETE" {
                #"{"data":{"deleted":true},"error":null}"#
            } else if path == "/api/documents/inbound/usage" {
                #"{"data":{"usedBytes":0,"quotaBytes":1000,"maxFileBytes":500,"acceptedExtensions":[".pdf"],"linkedEpisodes":[]},"error":null}"#
            } else {
                #"{"data":{"documents":["# + Self.documentJSON("d1") + "," + Self.documentJSON("d2") + #"],"nextCursor":null},"error":null}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let store = makeStore()
        await store.load()
        #expect(store.documents.map(\.id) == ["d1", "d2"])

        var selection = HLPaneSelection<String>()
        selection.select("d2")
        #expect(selection.resolved(in: store.documents.map(\.id)) == "d2")

        let doomed = try #require(store.documents.last)
        await store.delete(doomed, undoMessage: "removed")

        #expect(store.documents.map(\.id) == ["d1"])
        #expect(selection.resolved(in: store.documents.map(\.id)) == nil, "the pane shows its placeholder")
        selection.select("d1")
        #expect(selection.resolved(in: store.documents.map(\.id)) == "d1")
    }
}
