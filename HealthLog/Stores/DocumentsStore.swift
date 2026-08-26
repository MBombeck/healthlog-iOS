import Foundation
import Observation

/// `@MainActor @Observable` store backing the native "Dokumente" document-vault
/// surfaces. Loads the document list (keyset-paginated) + the usage/quota summary
/// via ``DocumentsRepository``, and drives metadata edits, soft-delete + restore,
/// bulk actions, uploads, and the optional AI extract.
///
/// **Opt-in module.** The surface is shown unless the user (or operator) has
/// `inboundDocuments` off. A `403 module.disabled` flips ``isDisabled`` so the
/// screen renders the enable-CTA state instead of a hard error.
///
/// **Server-pinned sort.** The list is always `documentDate desc` — the store
/// never client-sorts (web parity).
///
/// **Snapshot-owning.** Reads are network-direct; this store holds the in-memory
/// snapshot (mirrors `LabsStore` / `IllnessStore`). It joins the logout cascade
/// via ``LogoutClearable`` so the next user never inherits the previous user's
/// documents.
///
/// **Latest-query-wins (Phase 08).** Every read and every write captures a
/// ``DocumentQueryOwner`` before its first `await` and checks it again before it
/// touches any published property. Nothing here relies on cancellation, on a
/// debounce, or on a reentrancy latch: a reply that arrives late is not wrong,
/// it is simply the answer to a question that may already have been replaced,
/// and only the owner of the current question may repaint the screen.
@MainActor
@Observable
public final class DocumentsStore {
    public internal(set) var documents: [InboundDocument] = []
    public internal(set) var usage: DocumentUsage?
    public internal(set) var nextCursor: String?

    /// The active list facets (search / kinds / episode / year). Mutated through
    /// ``applyFilter(_:)`` so a change always re-queries from a clean cursor.
    public internal(set) var filter = DocumentListFilter()

    /// The facets the snapshot currently on screen actually answers — `nil`
    /// until a query has published one. Distinct from ``filter``, which is the
    /// question that has been *asked*: the gap between the two is exactly the
    /// window in which the visible rows are a stale answer.
    public private(set) var loadedFilter: DocumentListFilter?

    public internal(set) var isLoading = false
    public internal(set) var isLoadingMore = false
    public internal(set) var isDisabled = false
    public internal(set) var lastError: String?

    /// Multi-select state for the bulk bar. Empty ⇒ the bar is hidden.
    public internal(set) var selection: Set<String> = []

    /// Upload progress + feedback. `uploadingCount` drives the inline spinner;
    /// `lastUploadError` surfaces a typed pre-flight/server failure;
    /// `highlightedDocumentId` flashes the existing row after a duplicate.
    public internal(set) var uploadingCount = 0
    public internal(set) var lastUploadError: DocumentUploadError?
    public internal(set) var highlightedDocumentId: String?

    let repository: DocumentsRepository
    let undo: UndoCoordinator?
    @ObservationIgnored private var authenticatedSessionRegistry = AuthenticatedSessionLeaseRegistry()
    @ObservationIgnored private var authenticatedSessionOwnerProvider: @Sendable () -> String? = { "_anonymous" }
    @ObservationIgnored private var ownsAuthenticatedSessionRegistry = true

    /// The newest read request. Bumped by every replacement query and by every
    /// epoch change; a reply carrying an older generation may not publish.
    @ObservationIgnored private var queryGeneration: UInt64 = 0

    /// The newest *question* — moved only by ``applyFilter(_:)``,
    /// ``clearOnLogout()`` and the module-disabled stand-down. A write survives
    /// the reload it triggers itself (which bumps the generation) but never
    /// survives a filter change, a logout or a withdrawn module.
    @ObservationIgnored private var queryEpoch: UInt64 = 0

    /// The newest pagination request. Owns ``isLoadingMore`` on its own, so a
    /// plain reload can supersede a page in flight without latching the
    /// spinner shut for the rest of the session.
    @ObservationIgnored private var pageGeneration: UInt64 = 0

    public init(repository: DocumentsRepository, undo: UndoCoordinator? = nil) {
        self.repository = repository
        self.undo = undo
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

    func bindAuthenticatedSessionRegistry(
        _ registry: AuthenticatedSessionLeaseRegistry,
        ownerIDProvider: @escaping @Sendable () -> String?
    ) {
        precondition(ownsAuthenticatedSessionRegistry, "authenticated registry already bound")
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry = registry
        authenticatedSessionOwnerProvider = ownerIDProvider
        ownsAuthenticatedSessionRegistry = false
    }

    func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
        guard let ownerID = authenticatedSessionOwnerProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerID.isEmpty else { return nil }
        return authenticatedSessionRegistry.capture(ownerID: ownerID)
    }

    private func rotateOwnedAuthenticatedSessionBoundary() {
        guard ownsAuthenticatedSessionRegistry else { return }
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

    // MARK: - Query ownership

    /// Claim a new replacement query and capture everything it must still own
    /// to be allowed to publish.
    private func beginQuery(lease: AuthenticatedSessionLease) -> DocumentQueryOwner {
        queryGeneration &+= 1
        return captureOwner(lease: lease)
    }

    /// Capture the *current* question without claiming a new one — for the
    /// subordinate reads (pagination, usage) and for every write, which follow
    /// the query already on screen rather than replacing it.
    private func captureOwner(lease: AuthenticatedSessionLease, cursor: String? = nil) -> DocumentQueryOwner {
        DocumentQueryOwner(
            generation: queryGeneration,
            epoch: queryEpoch,
            filter: filter,
            cursor: cursor,
            lease: lease
        )
    }

    /// Capture a write's owner, or `nil` when there is no authenticated session
    /// to write under.
    func captureWriteOwner() -> DocumentQueryOwner? {
        guard let lease = captureAuthenticatedSessionLease() else { return nil }
        return captureOwner(lease: lease)
    }

    /// May this read publish? Only while its own request is still the newest
    /// one, under the question it was asked and the session that asked it.
    func ownsRead(_ owner: DocumentQueryOwner) -> Bool {
        owner.lease.isCurrent && owner.epoch == queryEpoch && owner.generation == queryGeneration
    }

    /// May this write publish? A write outlives the reload it performs itself,
    /// so it is scoped to the question rather than to the request.
    func ownsWrite(_ owner: DocumentQueryOwner) -> Bool {
        owner.lease.isCurrent && owner.epoch == queryEpoch
    }

    /// Move the question. Everything in flight — replacement, pagination, usage
    /// and every outstanding write — stops being allowed to publish, without a
    /// single cancellation and without waiting for anything.
    private func invalidateQueries() {
        queryEpoch &+= 1
        queryGeneration &+= 1
        pageGeneration &+= 1
    }

    // MARK: - Derived helpers

    /// The condition-filter chips — episodes carrying ≥ 1 live document link, from
    /// the usage endpoint (NOT derived from the loaded corpus), plus the actively
    /// filtered episode even if its last link was just removed. Sorted by name.
    public var conditionChips: [DocumentConditionLink] {
        var chips = usage?.linkedEpisodes ?? []
        if let episodeId = filter.episodeId, !episodeId.isEmpty,
           !chips.contains(where: { $0.episodeId == episodeId })
        {
            // Keep the active filter visible; borrow the name from any loaded doc.
            let name = documents
                .flatMap(\.conditionLinks)
                .first { $0.episodeId == episodeId }?.name ?? episodeId
            chips.append(DocumentConditionLink(episodeId: episodeId, name: name))
        }
        return chips.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The year segmenter — years present in the loaded corpus plus the active
    /// year, newest-first.
    public var years: [Int] {
        var set = Set(documents.compactMap { Self.year(from: $0.displayDate) })
        if let year = filter.year { set.insert(year) }
        return set.sorted(by: >)
    }

    /// True when there are no documents AND no filter is active AND nothing is
    /// uploading — the genuine "vault is empty" state (vs. a filtered no-match).
    public var isTrulyEmpty: Bool {
        documents.isEmpty && !filter.isActive && uploadingCount == 0
    }

    /// True while the newest query is in flight AND the rows on screen answer a
    /// *different* question. This is the only case in which keeping the visible
    /// content would be a lie; a plain refresh of the same facets leaves the
    /// list in place rather than flashing a skeleton at every poll.
    public var isReplacingContent: Bool {
        isLoading && loadedFilter != filter
    }

    // MARK: - Load

    /// Load the usage summary + the first page for the current filter, as a new
    /// replacement query. A concurrent reload is NOT suppressed — the newest
    /// request always reaches the network and only the newest reply publishes,
    /// so a user who re-asks never has their newest question dropped. A
    /// `403 module.disabled` flips ``isDisabled``.
    public func load() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        let owner = beginQuery(lease: sessionLease)
        isLoading = true
        defer { if ownsRead(owner) { isLoading = false } }
        // Usage first (drives the quota bar + condition chips + upload pre-flight).
        do {
            let fetchedUsage = try await repository.usage()
            guard ownsRead(owner) else { return }
            usage = fetchedUsage

            let page = try await repository.list(filter: owner.filter)
            guard ownsRead(owner) else { return }
            documents = page.documents
            nextCursor = page.nextCursor
            markSnapshot(answering: owner.filter)
            isDisabled = false
            lastError = nil
        } catch {
            guard ownsRead(owner) else { return }
            applyError(error)
        }
    }

    /// Fetch the next keyset page and append it. No-op when there's no cursor or a
    /// page fetch is already running.
    ///
    /// The page follows the query on screen instead of replacing it, so it
    /// captures the current generation rather than claiming a new one — but it
    /// claims its own pagination ticket, because ``isLoadingMore`` has to come
    /// back down even when a plain reload has superseded the page in flight.
    public func loadMore() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        guard let cursor = nextCursor, !cursor.isEmpty, !isLoadingMore, !isLoading else { return }
        let owner = captureOwner(lease: sessionLease, cursor: cursor)
        pageGeneration &+= 1
        let page = pageGeneration
        isLoadingMore = true
        defer { if page == pageGeneration { isLoadingMore = false } }
        do {
            let fetched = try await repository.list(filter: owner.filter, cursor: owner.cursor)
            guard ownsRead(owner) else { return }
            // De-dupe defensively — a concurrent reload could overlap.
            let known = Set(documents.map(\.id))
            documents.append(contentsOf: fetched.documents.filter { !known.contains($0.id) })
            nextCursor = fetched.nextCursor
        } catch {
            guard ownsRead(owner) else { return }
            applyError(error)
        }
    }

    /// Refresh only the usage/quota summary (after an upload / delete). Tolerated
    /// defensively — a failure leaves the previous usage in place.
    ///
    /// The chips and the quota bar are usage-derived, so this read is fenced by
    /// the same generation as the list: a refresh issued under one filter must
    /// not repaint the answer to another, and a `403` answering a superseded
    /// question must not stand the current one down.
    public func refreshUsage() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        let owner = captureOwner(lease: sessionLease)
        do {
            let fetchedUsage = try await repository.usage()
            guard ownsRead(owner) else { return }
            usage = fetchedUsage
        } catch {
            guard ownsRead(owner) else { return }
            if DocumentsRepository.isModuleDisabled(error) { applyError(error) }
        }
    }

    /// Replace the filter + reload from a clean cursor.
    public func applyFilter(_ newFilter: DocumentListFilter) async {
        invalidateQueries()
        isLoadingMore = false
        filter = newFilter
        nextCursor = nil
        await load()
    }

    /// Clear every facet + reload.
    public func clearFilter() async {
        await applyFilter(DocumentListFilter())
    }

    // MARK: - Detail / blob passthroughs

    /// `GET /api/documents/inbound/{id}` — the document + its staged facts. The
    /// detail screen owns the returned value in `@State`.
    public func detail(id: String) async throws -> InboundDocumentDetail {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let detail = try await repository.detail(id: id)
        try sessionLease.requireCurrent()
        return detail
    }

    /// The decrypted original bytes + response (Content-Type / filename headers).
    public func original(id: String) async throws -> (Data, HTTPURLResponse) {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let original = try await repository.original(id: id)
        try sessionLease.requireCurrent()
        return original
    }

    // MARK: - Selection (bulk bar)

    public func isSelected(_ id: String) -> Bool {
        selection.contains(id)
    }

    public func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func clearSelection() {
        selection = []
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot on logout so the next user never inherits the
    /// previous user's documents.
    /// Production binds the shared ``AuthenticatedSessionLeaseRegistry``, so the
    /// owned-boundary rotation is a no-op here and the lease an outstanding
    /// request holds stays current. The epoch bump — taken FIRST, before a
    /// single field is cleared — is therefore what actually keeps the wiped
    /// store wiped, independently of composition order.
    public func clearOnLogout() {
        rotateOwnedAuthenticatedSessionBoundary()
        invalidateQueries()
        documents = []
        usage = nil
        nextCursor = nil
        filter = DocumentListFilter()
        markSnapshot(answering: nil)
        selection = []
        uploadingCount = 0
        lastUploadError = nil
        highlightedDocumentId = nil
        isLoading = false
        isLoadingMore = false
        isDisabled = false
        lastError = nil
    }

    // MARK: - Test seam

    /// Test-only — populate the in-memory snapshot without a network round-trip so
    /// the logout-wipe suite can prove `clearOnLogout` purges the PHI.
    func seedForTesting(documents: [InboundDocument], usage: DocumentUsage? = nil, selection: Set<String> = []) {
        self.documents = documents
        self.usage = usage
        self.selection = selection
    }

    // MARK: - Private

    /// A withdrawn module is not an error banner, it is a different surface —
    /// so the whole module stands down together. Content, cursor, facets,
    /// selection, upload feedback and both spinners go with it, because a
    /// filter, a bulk bar or an upload spinner over an enable-CTA points at
    /// something that is not there. The epoch moves last-but-one so nothing in
    /// flight can repaint the disabled surface; the spinners are lowered
    /// explicitly because that same bump takes them out of their owner's reach.
    func applyError(_ error: Error) {
        if DocumentsRepository.isModuleDisabled(error) {
            isDisabled = true
            documents = []
            usage = nil
            nextCursor = nil
            filter = DocumentListFilter()
            markSnapshot(answering: nil)
            selection = []
            uploadingCount = 0
            lastUploadError = nil
            highlightedDocumentId = nil
            lastError = nil
            invalidateQueries()
            isLoading = false
            isLoadingMore = false
            return
        }
        lastError = LogSanitizer.redact(String(describing: error))
    }

    /// Clear an outcome banner the user has read. Only the message — never the
    /// selection it is about, which is the handle on the rows that failed.
    public func acknowledgeOutcome() {
        lastError = nil
    }

    /// Record which question the snapshot now on screen answers — or that it
    /// answers none, after a logout or a module stand-down.
    private func markSnapshot(answering filter: DocumentListFilter?) {
        loadedFilter = filter
    }

    /// Replace `doc` in the in-memory list (after a metadata edit / relink).
    func replaceDocument(_ document: InboundDocument) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        }
    }

    /// The 4-digit calendar year at the front of a `YYYY-MM-DD` / ISO date, or nil.
    private static func year(from date: String) -> Int? {
        guard date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

// MARK: - DocumentQueryOwner

/// The immutable token every document read and write captures before its first
/// `await`, and checks again before it touches any published property.
///
/// It exists because *publication* — not the network call — is what has to be
/// fenced. Cancelling a superseded request is an optimisation and a race:
/// cancellation may not arrive, and a task that has already returned cannot be
/// cancelled at all. Comparing this token to the store's counters is a decision
/// the main actor makes synchronously, at the instant of the write, and it
/// cannot be lost.
struct DocumentQueryOwner {
    /// The read request that captured the token. Moves on every replacement
    /// query.
    let generation: UInt64
    /// The question that captured it. Moves on a filter change, a logout and a
    /// module stand-down — never on a plain reload.
    let epoch: UInt64
    /// The facets the request was issued with, captured so the request itself
    /// can never be re-read from mutable state after an `await`.
    let filter: DocumentListFilter
    /// The keyset cursor the request was issued with; `nil` for a replacement.
    let cursor: String?
    /// The Phase-06 authenticated lease the request was issued under.
    let lease: AuthenticatedSessionLease
}
