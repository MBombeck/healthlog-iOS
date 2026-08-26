import Foundation
@testable import HealthLog
import Testing

@MainActor
@Suite("Authenticated documents boundary")
struct AuthenticatedDocumentsBoundaryTests {
    private final class SessionOwnerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ownerID: String

        init(_ ownerID: String) {
            self.ownerID = ownerID
        }

        func read() -> String {
            lock.withLock { ownerID }
        }

        func set(_ ownerID: String) {
            lock.withLock { self.ownerID = ownerID }
        }
    }

    private actor RequestGate {
        private var entered = 0
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            entered += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitForRequests(_ count: Int) async {
            while entered < count {
                await withCheckedContinuation { entryWaiters.append($0) }
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    @Test("lateAccountAReadOrWriteCannotAffectB")
    func lateAccountAReadOrWriteCannotAffectB() async {
        let api = StubAPIClient()
        let gate = RequestGate()
        let accountADocument = Self.document(id: "shared", title: "Account A")
        await api.setHandler { request in
            if request is APIRequest<DocumentUsage> {
                await gate.suspend()
                return Self.usage(usedBytes: 100)
            }
            if request is APIRequest<InboundDocumentDetail> {
                await gate.suspend()
                return InboundDocumentDetail(document: accountADocument, facts: [])
            }
            if request is APIRequest<InboundDocumentList> {
                return InboundDocumentList(documents: [accountADocument], nextCursor: "account-a-cursor")
            }
            throw HLError.unknown("unexpected documents boundary request")
        }

        let sessionRegistry = AuthenticatedSessionLeaseRegistry()
        let sessionOwner = SessionOwnerBox("account-a")
        sessionRegistry.activate(ownerID: sessionOwner.read())
        let store = DocumentsStore(repository: DocumentsRepository(api: api))
        store.bindAuthenticatedSessionRegistry(sessionRegistry, ownerIDProvider: sessionOwner.read)
        let accountALoad = Task { @MainActor in await store.load() }
        let accountAWrite = Task { @MainActor in
            await store.updateMetadata(id: "shared", .title("Account A"))
        }
        await gate.waitForRequests(2)

        sessionRegistry.invalidate()
        store.clearOnLogout()
        sessionOwner.set("account-b")
        sessionRegistry.activate(ownerID: sessionOwner.read())
        let accountBDocument = Self.document(id: "shared", title: "Account B")
        let accountBUsage = Self.usage(usedBytes: 7)
        store.seedForTesting(documents: [accountBDocument], usage: accountBUsage, selection: ["shared"])
        store.filter = DocumentListFilter(q: "account-b")
        await gate.release()
        _ = await accountAWrite.value
        await accountALoad.value

        let accountBRemainsCurrent = store.documents == [accountBDocument]
            && store.usage == accountBUsage
            && store.filter.q == "account-b"
            && store.selection == ["shared"]
            && store.nextCursor == nil
            && !store.isLoading
            && store.lastError == nil
        #expect(
            accountBRemainsCurrent,
            "EXPECTED_RED: late A document read or write affected B"
        )
    }

    private nonisolated static func document(id: String, title: String) -> InboundDocument {
        InboundDocument(
            id: id,
            kind: .other,
            title: title,
            filename: "document.pdf",
            mimeType: "application/pdf",
            byteSize: 1,
            status: .stored,
            providerType: nil,
            reportDate: nil,
            documentDate: "2026-08-14",
            errorReason: nil,
            factCount: 0,
            pendingCount: 0,
            conditionLinks: [],
            servingClass: .inline,
            createdAt: "2026-08-14T08:00:00.000Z",
            updatedAt: "2026-08-14T08:00:00.000Z"
        )
    }

    private nonisolated static func usage(usedBytes: Int) -> DocumentUsage {
        DocumentUsage(
            usedBytes: usedBytes,
            quotaBytes: 1000,
            maxFileBytes: 500,
            acceptedExtensions: [".pdf"],
            linkedEpisodes: []
        )
    }
}
