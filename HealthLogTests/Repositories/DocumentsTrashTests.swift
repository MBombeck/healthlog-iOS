import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Recently deleted (#151, server v1.46.0).** The link's counter, the
/// list with its cap, restore (the document is back in the vault list),
/// delete for good after the in-place question, and the refusals (409
/// `documents.inbound.notDeleted` reloads, duplicate, gone, module off,
/// somebody else's record). Real `APIClient` over a stub `URLProtocol` that
/// holds a small vault, so every write is seen by the next read.
@Suite("Recently deleted documents (#151)", .serialized, .mockURLSession, .timeLimit(.minutes(1)))
@MainActor
struct DocumentsTrashTests {
    // MARK: - Counter and link

    @Test("A usage answer without deletedCount (server before 1.46.0) offers no link")
    func olderServerHasNoLink() throws {
        let usage = try Self.decodeUsage(#"{"usedBytes":1,"quotaBytes":2,"maxFileBytes":1,"acceptedExtensions":[],"linkedEpisodes":[]}"#)
        #expect(usage.deletedCount == nil)
        #expect(!RecentlyDeletedDocumentsLink.isOffered(usage))
        #expect(!RecentlyDeletedDocumentsLink.isOffered(nil))
    }

    @Test("deletedCount 0 (empty, or somebody else's record) offers no link, above 0 does", arguments: [
        (0, false), (1, true), (37, true)
    ])
    func counterGatesLink(count: Int, offered: Bool) throws {
        let usage = try Self.decodeUsage(
            #"{"usedBytes":1,"quotaBytes":2,"maxFileBytes":1,"acceptedExtensions":[],"linkedEpisodes":[],"deletedCount":\#(count)}"#
        )
        #expect(usage.deletedCount == count)
        #expect(RecentlyDeletedDocumentsLink.isOffered(usage) == offered)
    }

    @Test("A malformed deletedCount costs only the field")
    func malformedCounter() throws {
        let usage = try Self.decodeUsage(
            #"{"usedBytes":5,"quotaBytes":9,"maxFileBytes":1,"acceptedExtensions":[],"linkedEpisodes":[],"deletedCount":"many"}"#
        )
        #expect(usage.usedBytes == 5)
        #expect(usage.deletedCount == nil)
    }

    @Test("The vault store reads the counter with the usage")
    func vaultStoreReadsCounter() async {
        let vault = FakeVault(live: ["d-live"], deleted: ["d-old", "d-new"])
        let store = Self.makeVault(vault)
        await store.load()
        #expect(store.usage?.deletedCount == 2)
        #expect(RecentlyDeletedDocumentsLink.isOffered(store.usage))
    }

    // MARK: - List

    @Test("The list decodes rows, grace days and the 200-row cap; a row without id is dropped")
    func listDecodesCap() async {
        let vault = FakeVault(live: [], deleted: ["d1"])
        vault.truncated = true
        vault.extraRawRow = #"{"kind":"OTHER","title":"no id"}"#
        let trash = DocumentsTrashStore(vault: Self.makeVault(vault))
        await trash.load()
        #expect(trash.phase == .loaded)
        #expect(trash.rows.map(\.id) == ["d1"])
        #expect(trash.rows.first?.resolvedTitle == "Doc d1")
        #expect(trash.graceDays == 30)
        #expect(trash.isTruncated)
        #expect(trash.cap?.limit == 200)
    }

    @Test("An uncut list says nothing about a cap")
    func listWithoutCap() async {
        let trash = DocumentsTrashStore(vault: Self.makeVault(FakeVault(live: [], deleted: ["d1"])))
        await trash.load()
        #expect(!trash.isTruncated)
    }

    @Test("Each row shows when it was deleted and when it goes for good")
    func rowDateLines() {
        let row = DeletedDocument(
            id: "d1", deletedAt: "2026-11-01T10:00:00.000Z", purgeAt: "2026-12-01T10:00:00.000Z"
        )
        let lines = DeletedDocumentRowDates.lines(for: row)
        #expect(lines.count == 2)
        #expect(lines[0].contains(DocumentFormat.mediumDate("2026-11-01T10:00:00.000Z")))
        #expect(lines[1].contains(DocumentFormat.mediumDate("2026-12-01T10:00:00.000Z")))
        #expect(lines.allSatisfy { !$0.contains("%@") })
        #expect(DeletedDocumentRowDates.lines(for: DeletedDocument(id: "d2", deletedAt: "garbage")).isEmpty)
    }

    // MARK: - Restore

    @Test("Restore puts the document back into the vault list and out of Recently deleted")
    func restoreReturnsToList() async {
        let vault = FakeVault(live: ["d-live"], deleted: ["d-old"])
        let store = Self.makeVault(vault)
        await store.load()
        let trash = DocumentsTrashStore(vault: store)
        await trash.load()

        let restored = await trash.restore(trash.rows[0])

        #expect(restored)
        #expect(Set(store.documents.map(\.id)) == ["d-live", "d-old"])
        #expect(store.usage?.deletedCount == 0)
        #expect(!RecentlyDeletedDocumentsLink.isOffered(store.usage))
        #expect(trash.rows.isEmpty)
        #expect(trash.outcome == nil)
        #expect(vault.calls.contains("POST /api/documents/inbound/d-old/restore"))
    }

    @Test("A restore blocked by an identical document says so and keeps the row")
    func restoreDuplicate() async {
        let vault = FakeVault(live: [], deleted: ["d-copy"])
        vault.restoreRefusal = (409, "documents.inbound.restoreDuplicate")
        let trash = DocumentsTrashStore(vault: Self.makeVault(vault))
        await trash.load()
        #expect(await !trash.restore(trash.rows[0]))
        #expect(trash.outcome == String(localized: "documents.trash.restoreDuplicate"))
        #expect(trash.rows.map(\.id) == ["d-copy"])
    }

    @Test("A restore of a document purged meanwhile says it is gone and reloads it away")
    func restoreGone() async {
        let vault = FakeVault(live: [], deleted: ["d-gone"])
        vault.restoreRefusal = (409, "documents.inbound.restoreGone")
        let trash = DocumentsTrashStore(vault: Self.makeVault(vault))
        await trash.load()
        vault.deleted = []
        #expect(await !trash.restore(trash.rows[0]))
        #expect(trash.outcome == String(localized: "documents.error.purged"))
        #expect(trash.rows.isEmpty)
    }

    // MARK: - Delete for good

    @Test("Delete for good asks first, then removes the row and lowers the counter")
    func purgeAfterQuestion() async throws {
        let vault = FakeVault(live: ["d-live"], deleted: ["d-a", "d-b"])
        let store = Self.makeVault(vault)
        await store.load()
        let trash = DocumentsTrashStore(vault: store)
        await trash.load()

        // The first tap only opens the question; nothing is sent.
        trash.confirmingPurgeID = "d-a"
        #expect(!vault.calls.contains { $0.hasSuffix("/purge") })

        let purged = try await trash.purge(#require(trash.rows.first { $0.id == "d-a" }))

        #expect(purged)
        #expect(vault.calls.contains("POST /api/documents/inbound/d-a/purge"))
        #expect(trash.confirmingPurgeID == nil)
        #expect(trash.rows.map(\.id) == ["d-b"])
        #expect(store.usage?.deletedCount == 1)
        #expect(store.documents.map(\.id) == ["d-live"])
    }

    @Test("409 notDeleted on delete for good reloads both lists and says why")
    func purgeNotDeletedReloads() async {
        let vault = FakeVault(live: [], deleted: ["d-back"])
        let store = Self.makeVault(vault)
        await store.load()
        let trash = DocumentsTrashStore(vault: store)
        await trash.load()
        // Restored on another device meanwhile.
        vault.deleted = []
        vault.live = ["d-back"]
        trash.confirmingPurgeID = "d-back"

        #expect(await !trash.purge(trash.rows[0]))

        #expect(trash.outcome == String(localized: "documents.trash.notDeleted"))
        #expect(trash.rows.isEmpty)
        #expect(trash.confirmingPurgeID == nil)
        #expect(store.documents.map(\.id) == ["d-back"])
        #expect(store.usage?.deletedCount == 0)
    }

    @Test("A purge that finds nothing (404) got what it asked for")
    func purgeNotFound() async {
        let vault = FakeVault(live: [], deleted: ["d-x"])
        let trash = DocumentsTrashStore(vault: Self.makeVault(vault))
        await trash.load()
        vault.deleted = []
        #expect(await !trash.purge(trash.rows[0]))
        #expect(trash.outcome == nil)
        #expect(trash.rows.isEmpty)
    }

    @Test("Refusal codes map to their meaning", arguments: [
        (409, "documents.inbound.restoreDuplicate", false, DocumentTrashRefusal.duplicateExists),
        (409, "documents.inbound.restoreGone", false, .gone),
        (409, "documents.inbound.notDeleted", true, .notDeleted),
        (404, "documents.inbound.notFound", true, .notFound),
        (409, "something.else", false, .gone),
        (409, "something.else", true, .notDeleted)
    ])
    func refusalCodes(status: Int, code: String, purging: Bool, expected: DocumentTrashRefusal) {
        let error = HLError.server(status: status, code: code, message: "")
        #expect(DocumentsRepository.trashRefusal(error, purging: purging) == expected)
    }

    @Test("Other errors are no refusal and keep a plain sentence")
    func otherErrors() {
        #expect(DocumentsRepository.trashRefusal(HLError.server(status: 500, code: nil, message: ""), purging: true) == nil)
        #expect(DocumentsRepository.trashRefusal(HLError.offline, purging: false) == nil)
        let purgeText = DocumentsTrashStore.message(for: nil, purging: true, error: HLError.server(status: 500, code: nil, message: ""))
        #expect(purgeText == String(localized: "documents.trash.purgeFailed"))
    }

    // MARK: - Module and rights

    @Test("403 module.disabled shows the module card, any other 403 the refusal card, 500 the retry state")
    func readRefusals() async {
        for (status, body, expected) in [
            (
                403,
                #"{"data":null,"error":"off","meta":{"errorCode":"module.disabled","module":"inboundDocuments"}}"#,
                DocumentsTrashStore.Phase.moduleOff
            ),
            (403, #"{"data":null,"error":"Forbidden","meta":{"errorCode":"auth.forbidden"}}"#, .notOffered),
            (500, #"{"data":null,"error":"boom"}"#, .failed)
        ] {
            let vault = FakeVault(live: [], deleted: [])
            vault.deletedListFailure = (status, body)
            let trash = DocumentsTrashStore(vault: Self.makeVault(vault))
            await trash.load()
            #expect(trash.phase == expected, "status \(status)")
        }
    }

    // MARK: - Helpers

    private static func decodeUsage(_ json: String) throws -> DocumentUsage {
        try JSONDecoder.hlDefault.decode(DocumentUsage.self, from: Data(json.utf8))
    }

    private static func makeVault(_ vault: FakeVault) -> DocumentsStore {
        MockURLProtocol.install { request in vault.answer(request) }
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return DocumentsStore(repository: DocumentsRepository(api: api))
    }
}

/// A vault on the other side of the stub: live and deleted ids, the calls it
/// saw, and the refusals a test arms.
private final class FakeVault: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLive: [String]
    private var storedDeleted: [String]
    private var storedCalls: [String] = []
    var truncated = false
    var extraRawRow: String?
    var restoreRefusal: (Int, String)?
    var deletedListFailure: (Int, String)?

    init(live: [String], deleted: [String]) {
        storedLive = live
        storedDeleted = deleted
    }

    var live: [String] {
        get { lock.withLock { storedLive } }
        set { lock.withLock { storedLive = newValue } }
    }

    var deleted: [String] {
        get { lock.withLock { storedDeleted } }
        set { lock.withLock { storedDeleted = newValue } }
    }

    var calls: [String] {
        lock.withLock { storedCalls }
    }

    func answer(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        lock.withLock { storedCalls.append("\(method) \(path)") }
        switch (method, path) {
        case ("GET", "/api/documents/inbound/usage"):
            return reply(
                request,
                #"{"data":{"usedBytes":1,"quotaBytes":100,"maxFileBytes":10,"#
                    + #""acceptedExtensions":[".pdf"],"linkedEpisodes":[],"deletedCount":\#(deleted.count)},"error":null}"#
            )
        case ("GET", "/api/documents/inbound"):
            let rows = live.map(Self.liveJSON).joined(separator: ",")
            return reply(request, #"{"data":{"documents":[\#(rows)],"nextCursor":null},"error":null}"#)
        case ("GET", "/api/documents/inbound/deleted"):
            if let (status, body) = deletedListFailure { return reply(request, body, status: status) }
            let rows = (deleted.map(Self.deletedJSON) + [extraRawRow].compactMap(\.self)).joined(separator: ",")
            return reply(
                request,
                #"{"data":{"documents":[\#(rows)],"graceDays":30},"error":null,"meta":{"truncated":\#(truncated),"limit":200}}"#
            )
        default:
            return write(request, method: method, path: path)
        }
    }

    private func write(_ request: URLRequest, method: String, path: String) -> (HTTPURLResponse, Data?) {
        let parts = path.split(separator: "/").map(String.init)
        guard method == "POST", parts.count == 5, let id = parts.dropLast().last else {
            return reply(request, #"{"data":null,"error":"unscripted"}"#, status: 500)
        }
        switch parts[4] {
        case "restore":
            if let (status, code) = restoreRefusal {
                return reply(request, #"{"data":null,"error":"no","meta":{"errorCode":"\#(code)"}}"#, status: status)
            }
            guard deleted.contains(id) else {
                return reply(request, #"{"data":null,"error":"gone","meta":{"errorCode":"documents.inbound.restoreGone"}}"#, status: 409)
            }
            deleted.removeAll { $0 == id }
            live.append(id)
            return reply(request, #"{"data":\#(Self.liveJSON(id)),"error":null}"#)
        case "purge":
            if live.contains(id) {
                return reply(request, #"{"data":null,"error":"live","meta":{"errorCode":"documents.inbound.notDeleted"}}"#, status: 409)
            }
            guard deleted.contains(id) else {
                return reply(request, #"{"data":null,"error":"nf","meta":{"errorCode":"documents.inbound.notFound"}}"#, status: 404)
            }
            deleted.removeAll { $0 == id }
            return reply(request, #"{"data":{"id":"\#(id)","purged":true},"error":null}"#)
        default:
            return reply(request, #"{"data":null,"error":"unscripted"}"#, status: 500)
        }
    }

    private func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static func liveJSON(_ id: String) -> String {
        #"{"id":"\#(id)","kind":"OTHER","title":"Doc \#(id)","filename":null,"mimeType":"application/pdf","#
            + #""byteSize":1,"status":"STORED","providerType":null,"reportDate":null,"documentDate":"2026-05-01","#
            + #""errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline","#
            + #""createdAt":"2026-05-01T09:00:00.000Z","updatedAt":"2026-05-01T09:00:00.000Z","facts":[]}"#
    }

    private static func deletedJSON(_ id: String) -> String {
        #"{"id":"\#(id)","kind":"LAB_RESULT","title":"Doc \#(id)","filename":"\#(id).pdf","mimeType":"application/pdf","#
            + #""byteSize":1,"documentDate":null,"sourceSystem":null,"#
            + #""deletedAt":"2026-11-01T10:00:00.000Z","purgeAt":"2026-12-01T10:00:00.000Z"}"#
    }
}
