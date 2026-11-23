import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **The document races and typed outcomes, as failing
/// contracts.**
///
/// Lives beside ``DocumentsStoreTests`` rather than inside it: the suite's own
/// file is already at the repo's 600-line lint budget, and the strict baseline
/// refuses a new warning. Swift Testing reports every case here under the same
/// `Documents store` suite.
extension DocumentsStoreTests {
    // MARK: - Deterministic race + typed-outcome contracts

    //
    // Every case below drives the REAL store over a scripted `APIClientProtocol`
    // held open by a continuation the test owns. There is no `Task.sleep`, no
    // process-global `MockURLProtocol` state, and no assertion outside the test
    // body: the "slow" response is released only after the test has already
    // observed the state it is about to be allowed to corrupt.
    //
    // Cancellation is deliberately NOT the oracle. Every scripted response
    // resolves normally; what is under test is whether the store still publishes
    // it once the query generation, the filter, or the session that asked for it
    // has moved on.

    // MARK: RED — an older answer must never overwrite a newer one

    /// The chips and the quota bar are usage-derived, and `refreshUsage()` is the
    /// one read path with no request-generation fence at all — it checks the
    /// session lease and nothing else. So a usage refresh issued under filter A
    /// (a relink, a delete, an upload) that lands after filter B has already
    /// painted replaces B's answer with A's.
    @Test("the newest filter's usage survives an older refresh that finishes last")
    func latestFilterWinsWhenOlderRequestFinishesLast() async {
        let script = DocumentScript()
        let api = ScriptedDocumentsAPI()
        let store = Self.makeScriptedStore(api: api)

        api.route = { @Sendable [script] method, path, query in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                let call = await script.nextUsage()
                // Call 2 is the stale one — it is the refresh filter A asked for,
                // and the test holds it open across the whole of filter B.
                if call == 2 { await script.holdUntilReleased() }
                return call >= 3 ? Self.usageBeta : Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                let q = query.first { $0.0 == "q" }?.1
                return InboundDocumentList(documents: [Self.document(id: q == "b" ? "d-b" : "d-a")], nextCursor: nil)
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }

        await store.applyFilter(DocumentListFilter(q: "a"))
        #expect(store.usage?.usedBytes == 10, "filter A must paint its own usage first")

        let stale = Task { await store.refreshUsage() }
        await script.waitUntilHeld()

        await store.applyFilter(DocumentListFilter(q: "b"))
        #expect(store.documents.map(\.id) == ["d-b"], "filter B must paint before the stale answer is released")
        #expect(store.usage?.usedBytes == 99)

        await script.release()
        _ = await stale.value

        var violations: [String] = []
        if store.usage?.usedBytes != 99 {
            violations.append("filter A's usage (\(store.usage?.usedBytes ?? -1) bytes) replaced filter B's 99")
        }
        if store.conditionChips.map(\.name) != ["Beta"] {
            violations.append("the condition chips fell back to \(store.conditionChips.map(\.name))")
        }
        if store.isLoading || store.isLoadingMore {
            violations.append("a superseded request left a spinner running")
        }
        #expect(store.documents.map(\.id) == ["d-b"], "the newest document page must survive regardless")
        #expect(violations.isEmpty, "documents older filter replaced the newest result")
    }

    // MARK: RED — stale pagination and stale write rollback

    /// Two holes in one contract.
    ///
    /// `loadMore()` captures the *current* generation without claiming a new one,
    /// and its `defer` only lowers `isLoadingMore` when that generation is still
    /// current. A plain reload bumps the generation, so the page in flight can
    /// never lower the flag again — pagination latches shut for the rest of the
    /// session (`applyFilter` happens to clear it, a refresh does not).
    ///
    /// `delete(_:)` removes the row optimistically and re-inserts it on failure
    /// with no generation or filter fence, so a delete that fails under filter A
    /// pushes A's document into whatever list is on screen when the failure lands.
    @Test("a superseded page and a failed delete cannot publish into the current query")
    func stalePaginationAndErrorCannotPublish() async {
        let script = DocumentScript()
        let api = ScriptedDocumentsAPI()
        let store = Self.makeScriptedStore(api: api)

        api.route = { @Sendable [script] method, path, query in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                _ = await script.nextUsage()
                return Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                guard let cursor = query.first(where: { $0.0 == "cursor" })?.1 else {
                    return InboundDocumentList(documents: [Self.document(id: "d1")], nextCursor: "page-2")
                }
                // The page-2 fetch is the one the test holds open.
                await script.holdUntilReleased()
                return InboundDocumentList(documents: [Self.document(id: "d2-\(cursor)")], nextCursor: nil)
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }

        await store.load()
        #expect(store.nextCursor == "page-2", "the first page must offer a cursor")

        let page = Task { await store.loadMore() }
        await script.waitUntilHeld()
        // A plain reload — not a filter change — supersedes the page in flight.
        await store.load()
        await script.release()
        _ = await page.value

        var violations: [String] = []
        if store.isLoadingMore {
            violations.append("the pagination spinner stayed latched after a superseding reload")
        }
        // The script stays released, so this second attempt answers immediately —
        // only a latched `isLoadingMore` can stop it.
        await store.loadMore()
        if !store.documents.contains(where: { $0.id.hasPrefix("d2-") }) {
            violations.append("pagination stayed blocked after the superseded page resolved")
        }

        // Second half — a failed delete rolling back into a different query.
        let deleteScript = DocumentScript()
        let deleteAPI = ScriptedDocumentsAPI()
        let deleteStore = Self.makeScriptedStore(api: deleteAPI)
        deleteAPI.route = { @Sendable [deleteScript] method, path, query in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                _ = await deleteScript.nextUsage()
                return Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                let q = query.first { $0.0 == "q" }?.1
                return InboundDocumentList(documents: [Self.document(id: q == "b" ? "d-b" : "d-a")], nextCursor: nil)
            case (.delete, "/api/documents/inbound/d-a"):
                await deleteScript.holdUntilReleased()
                throw HLError.server(status: 500, code: nil, message: "boom")
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }

        await deleteStore.applyFilter(DocumentListFilter(q: "a"))
        let removed = deleteStore.documents.first
        #expect(removed?.id == "d-a", "filter A must have a row to delete")
        let discard = Task { [removed] in
            if let removed { await deleteStore.delete(removed, undoMessage: "undo") }
        }
        await deleteScript.waitUntilHeld()
        await deleteStore.applyFilter(DocumentListFilter(q: "b"))
        #expect(deleteStore.documents.map(\.id) == ["d-b"], "filter B must own the list when the failure lands")
        await deleteScript.release()
        _ = await discard.value

        if deleteStore.documents.map(\.id) != ["d-b"] {
            violations.append("a failed delete re-inserted \(deleteStore.documents.map(\.id)) into a different query")
        }
        #expect(violations.isEmpty, "documents stale pagination or error published")
    }

    // MARK: RED — the store's own logout must fence its outstanding work

    /// Production binds the shared `AuthenticatedSessionLeaseRegistry` into the
    /// store, so `clearOnLogout()` takes the `ownsAuthenticatedSessionRegistry`
    /// guard and rotates nothing. Everything that keeps the wiped store wiped
    /// therefore lives in `AppContainer`'s ordering, not in the store — and the
    /// two paths with no request-generation fence (`refreshUsage`, and `delete`'s
    /// failure rollback) publish straight back into the cleared snapshot.
    ///
    /// The preservation half is the same store with the registry invalidated
    /// first, which is the order `AppContainer` actually uses: nothing publishes.
    @Test("logout invalidates every outstanding document publication")
    func logoutInvalidatesOutstandingQuery() async {
        var violations: [String] = []

        // --- The store's own logout, registry bound as in production. ---
        let script = DocumentScript()
        let api = ScriptedDocumentsAPI()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: "owner-a")
        let store = Self.makeScriptedStore(api: api)
        store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: { "owner-a" })

        api.route = { @Sendable [script] method, path, _ in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                let call = await script.nextUsage()
                if call == 2 { await script.holdUntilReleased() }
                return Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                return InboundDocumentList(documents: [Self.document(id: "d-a")], nextCursor: nil)
            case (.delete, "/api/documents/inbound/d-a"):
                await script.holdUntilReleased()
                throw HLError.server(status: 500, code: nil, message: "boom")
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }

        await store.load()
        #expect(store.usage != nil, "the store must hold a snapshot before logout")
        let usageRefresh = Task { await store.refreshUsage() }
        await script.waitUntilHeld()
        store.clearOnLogout()
        await script.release()
        _ = await usageRefresh.value

        if store.usage != nil {
            violations.append("an outstanding usage refresh republished linked-episode names after logout")
        }

        await script.rearm()
        await store.load()
        let doomed = store.documents.first
        #expect(doomed?.id == "d-a", "the reloaded store must have a row to delete")
        let discard = Task { [doomed] in
            if let doomed { await store.delete(doomed, undoMessage: "undo") }
        }
        await script.waitUntilHeld()
        store.clearOnLogout()
        await script.release()
        _ = await discard.value

        if !store.documents.isEmpty {
            violations.append("a failed delete resurrected \(store.documents.map(\.id)) into a logged-out store")
        }
        if store.lastError != nil {
            violations.append("a superseded write published an error banner into a logged-out store")
        }

        await Self.expectInvalidateThenClearAlreadyFences()
        #expect(violations.isEmpty, "documents outstanding query published after logout")
    }

    /// The preservation half of ``logoutInvalidatesOutstandingQuery()``: the
    /// order `AppContainer` actually uses — invalidate the shared registry, then
    /// clear — already stops the same publication today. Extracted so the RED
    /// above stays inside the repo's cyclomatic budget.
    private static func expectInvalidateThenClearAlreadyFences() async {
        let script = DocumentScript()
        let api = ScriptedDocumentsAPI()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: "owner-a")
        let store = makeScriptedStore(api: api)
        store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: { "owner-a" })
        api.route = { @Sendable [script] method, path, _ in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                let call = await script.nextUsage()
                if call == 2 { await script.holdUntilReleased() }
                return usageAlpha
            case (.get, "/api/documents/inbound"):
                return InboundDocumentList(documents: [document(id: "d-a")], nextCursor: nil)
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }
        await store.load()
        let refresh = Task { await store.refreshUsage() }
        await script.waitUntilHeld()
        registry.invalidate()
        store.clearOnLogout()
        await script.release()
        _ = await refresh.value
        #expect(store.usage == nil, "the invalidate-then-clear order must already hold today")
    }

    // MARK: RED — writes must return what happened

    /// An untyped refusal (`unauthorized`, the module gate) must come back from
    /// `upload(_:)` as a failure, and an import outcome must count unreadable
    /// picks, or the upload sheet dismisses as if the upload had worked.
    @Test("write outcomes report generic and unreadable failures to their caller")
    func writeOutcomesReportGenericAndUnreadableFailures() async {
        var violations: [String] = []

        let api = ScriptedDocumentsAPI()
        let store = Self.makeScriptedStore(api: api)
        api.route = { @Sendable method, path, _ in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                return Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                return InboundDocumentList(documents: [], nextCursor: nil)
            case (.post, "/api/documents/inbound"):
                throw HLError.unauthorized
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }
        await store.load()
        let outcome = await store.upload(
            DocumentUploadDraft(data: Data([1, 2, 3]), filename: "f.pdf", mimeType: "application/pdf")
        )
        if outcome.failure == nil {
            violations.append("DocumentsStore.upload reported a refused upload as landed")
        }
        if store.lastUploadError == nil {
            violations.append("an untyped upload failure never reached the upload surface")
        }

        // A pick whose inputs were all unreadable is a visible failure, never a
        // silent success the sheet would dismiss on.
        let unreadablePick = DocumentImportOutcome(selected: 3, uploaded: 0, unreadable: 3, failures: [])
        if unreadablePick.failedCount != 3 || unreadablePick.isComplete {
            violations.append("an import of three unreadable files does not count them as failed")
        }
        let mixedPick = DocumentImportOutcome(selected: 2, uploaded: 1, unreadable: 0, failures: [.notAuthenticated])
        if mixedPick.failedCount != 1 || mixedPick.isComplete {
            violations.append("an import with a refused upload reads as complete")
        }

        #expect(store.documents.isEmpty, "a refused upload must not invent a row")
        #expect(violations.isEmpty, "documents write failure was not returned visibly")
    }

    // MARK: RED — a partial bulk keeps the failures selected

    /// `runBulk` and `bulkDelete` both call `clearSelection()` on the success
    /// path without looking at the per-id results, so the ids the server refused
    /// lose their selection and the bulk bar disappears. The user is left with no
    /// way to retry the exact rows that failed, and nothing said they did.
    @Test("a partial bulk keeps the failed ids selected and says so")
    func partialBulkRetainsFailedSelection() async {
        var violations: [String] = []

        let api = ScriptedDocumentsAPI()
        let store = Self.makeScriptedStore(api: api)
        api.route = { @Sendable method, path, _ in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                return Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                return InboundDocumentList(
                    documents: [Self.document(id: "d1"), Self.document(id: "d2")],
                    nextCursor: nil
                )
            case (.post, "/api/documents/inbound/bulk"):
                return DocumentBulkResponse(results: [
                    .init(id: "d1", ok: true, error: nil),
                    .init(id: "d2", ok: false, error: "notFound")
                ])
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }

        await store.load()
        store.toggleSelection("d1")
        store.toggleSelection("d2")
        let response = await store.runBulk(.setKind, kind: .labResult)
        #expect(response?.failedCount == 1, "the per-id result array must still reach the caller")

        if store.selection != ["d2"] {
            violations.append("a partial bulk left the selection as \(store.selection.sorted()) instead of [d2]")
        }
        if store.lastError == nil {
            violations.append("a partial bulk action reported nothing about the id it could not apply")
        }

        store.toggleSelection("d1")
        store.toggleSelection("d2")
        let deleted = await store.bulkDelete { "\($0) discarded" }
        #expect(deleted?.okCount == 1, "the bulk-delete result array must still reach the caller")
        if store.selection != ["d2"] {
            violations.append("a partial bulk delete left the selection as \(store.selection.sorted())")
        }

        #expect(violations.isEmpty, "documents partial bulk failure discarded failed selection")
    }

    // MARK: RED — module-disabled is scoped to the query that asked

    /// `applyError`'s module-disabled branch is reached from `refreshUsage`,
    /// which carries no request generation, so a `403` answering a superseded
    /// question disables whatever query is on screen when it lands. And the
    /// branch it takes wipes the content without standing the controls down: the
    /// active filter facets, the upload spinner and the last upload error all
    /// survive into a surface that has nothing to filter or upload into.
    @Test("module-disabled is scoped to the current query and leaves no controls live")
    func moduleDisabledIsCurrentQueryScoped() async {
        var violations: [String] = []

        let script = DocumentScript()
        let api = ScriptedDocumentsAPI()
        let store = Self.makeScriptedStore(api: api)
        api.route = { @Sendable [script] method, path, query in
            switch (method, path) {
            case (.get, "/api/documents/inbound/usage"):
                let call = await script.nextUsage()
                if call == 2 {
                    await script.holdUntilReleased()
                    throw HLError.moduleDisabled(ModuleKey.inboundDocuments.wireKey)
                }
                return call >= 3 ? Self.usageBeta : Self.usageAlpha
            case (.get, "/api/documents/inbound"):
                let q = query.first { $0.0 == "q" }?.1
                return InboundDocumentList(documents: [Self.document(id: q == "b" ? "d-b" : "d-a")], nextCursor: nil)
            default:
                throw HLError.unknown("unscripted \(method.rawValue) \(path)")
            }
        }

        await store.applyFilter(DocumentListFilter(q: "a"))
        let stale = Task { await store.refreshUsage() }
        await script.waitUntilHeld()
        await store.applyFilter(DocumentListFilter(q: "b"))
        #expect(store.documents.map(\.id) == ["d-b"], "filter B must own the list before the 403 is released")
        await script.release()
        _ = await stale.value

        if store.isDisabled {
            violations.append("a 403 answering a superseded question disabled the current query")
        }
        if store.documents.isEmpty {
            violations.append("a superseded 403 wiped the current query's documents")
        }

        // The disabled surface itself: content is dropped, controls are not.
        let gateAPI = ScriptedDocumentsAPI()
        let gated = Self.makeScriptedStore(api: gateAPI)
        gateAPI.route = { @Sendable _, _, _ in
            throw HLError.moduleDisabled(ModuleKey.inboundDocuments.wireKey)
        }
        gated.seedForTesting(
            documents: [Self.document(id: "d1")],
            usage: Self.usageAlpha,
            selection: ["d1"]
        )
        await gated.applyFilter(DocumentListFilter(q: "still-here", year: 2026))
        #expect(gated.isDisabled, "a direct 403 must still raise the enable-CTA state")
        #expect(gated.documents.isEmpty, "the disabled surface must drop its content")
        if gated.filter.isActive {
            violations.append("the disabled surface kept \(gated.filter.activeCount) filter facets live")
        }

        #expect(violations.isEmpty, "documents disabled state leaked across query generations")
    }

    // MARK: - Phase 08 scripted harness

    /// Builds the store over a scripted `APIClientProtocol` — no URL loading
    /// system, no shared handler, one repository per store.
    private static func makeScriptedStore(api: APIClientProtocol) -> DocumentsStore {
        DocumentsStore(
            repository: DocumentsRepository(
                api: api,
                externalAIConsent: DocumentAIConsentLeaseProvider { nil }
            )
        )
    }

    private nonisolated static func document(id: String) -> InboundDocument {
        InboundDocument(
            id: id, kind: .other, title: id, filename: nil, mimeType: "application/pdf",
            byteSize: 1, status: .stored, providerType: nil, reportDate: nil, documentDate: "2026-05-01",
            errorReason: nil, factCount: 0, pendingCount: 0, conditionLinks: [],
            servingClass: .inline, createdAt: "2026-05-01T09:00:00.000Z", updatedAt: "2026-05-01T09:00:00.000Z"
        )
    }

    private nonisolated static let usageAlpha = DocumentUsage(
        usedBytes: 10,
        quotaBytes: 1000,
        maxFileBytes: 500,
        acceptedExtensions: [".pdf"],
        linkedEpisodes: [DocumentConditionLink(episodeId: "e-alpha", name: "Alpha")]
    )

    private nonisolated static let usageBeta = DocumentUsage(
        usedBytes: 99,
        quotaBytes: 1000,
        maxFileBytes: 500,
        acceptedExtensions: [".pdf"],
        linkedEpisodes: [DocumentConditionLink(episodeId: "e-beta", name: "Beta")]
    )
}
