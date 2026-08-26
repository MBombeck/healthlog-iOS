import Foundation

// Vault Phase 2 (server v1.27.22, iOS issue #43) — store passthroughs for the
// additive AI-assist + content-search actions. The detail screen owns the
// transient results (suggestion drafts + session-only summaries live in the
// screen's `@State`, never on the store) so these are thin, throwing hops that
// let the screen map `providerUnsupported` etc. to inline copy. The only local
// state the store touches is refreshing `usage` after an index / reindex so the
// content-search coverage caption updates in lockstep.

public extension DocumentsStore {
    /// Whether the AI-assist actions may be offered from the *data* side — the
    /// server reports a document-scan provider is configured + its own checks
    /// pass. The UI ANDs this with the app's AI-consent gate before rendering
    /// any affordance (see `DocumentDetailScreen`), so this alone never opens the
    /// surface; it just hides everything the moment the server withdraws it.
    var assistAvailable: Bool {
        usage?.assistAvailable ?? false
    }

    /// Whether the server can build the blind content-search index at all (a
    /// vision provider is configured). Gates the "durchsuchbar" caption + index
    /// affordances; still ANDed with AI consent for the mutating actions.
    var contentIndexEnabled: Bool {
        usage?.contentIndex?.enabled ?? false
    }

    // MARK: - Suggest / summary (session-only; nothing persisted)

    /// Fetch a filing-metadata DRAFT for a stored document. Writes nothing — the
    /// detail sheet prefills its editable fields and the user saves. Throws so
    /// the caller can map `providerUnsupported` to inline copy.
    func suggest(id: String, text: DocumentAiTextRequest? = nil) async throws -> DocumentSuggestion {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let suggestion = try await repository.suggest(id: id, text: text)
        try sessionLease.requireCurrent()
        return suggestion
    }

    /// Fetch a session-only summary (or raw text) of a stored document. Nothing
    /// is persisted; the result is descriptive only, not a diagnosis.
    func summarise(
        id: String,
        mode: DocumentSummaryMode = .summary,
        text: DocumentAiTextRequest? = nil
    ) async throws -> DocumentSummary {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let summary = try await repository.summary(id: id, mode: mode, text: text)
        try sessionLease.requireCurrent()
        return summary
    }

    // MARK: - Content index

    /// Index / re-index one document for content search, then refresh the usage
    /// coverage so the caption updates. Returns the index result so the caller
    /// can reflect the new `hasContentIndex` immediately.
    @discardableResult
    func indexContent(id: String, text: DocumentAiTextRequest? = nil) async throws -> DocumentIndexResult {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let result = try await repository.index(id: id, text: text)
        try sessionLease.requireCurrent()
        await refreshUsage()
        try sessionLease.requireCurrent()
        return result
    }

    /// Fire the corpus backfill (bounded, resumable, off-request), then refresh
    /// usage. Throws so the caller can map `providerUnsupported`.
    @discardableResult
    func reindexAll() async throws -> DocumentReindexResult {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let result = try await repository.reindexAll()
        try sessionLease.requireCurrent()
        await refreshUsage()
        try sessionLease.requireCurrent()
        return result
    }
}
