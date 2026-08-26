import Foundation

// Write-side of `DocumentsStore`: upload, metadata edit, soft-delete + restore
// (undo-backed), bulk actions, and the optional AI extract. All interactive —
// errors surface immediately (no outbox); see `DocumentsRepository` for the
// write-durability rationale.

public extension DocumentsStore {
    // MARK: - Upload

    /// Store one picked/scanned file and **return what happened to it**.
    ///
    /// Pre-flights the per-file cap + quota from the loaded `usage`, then
    /// uploads. On success reloads the list + usage; a same-bytes duplicate
    /// flashes the existing row (a success, not an error). A module gate still
    /// routes through ``applyError(_:)`` because it changes the whole surface.
    ///
    /// The returned outcome is the contract, not ``lastUploadError``. That slot
    /// is sticky and store-wide: a caller reading it afterwards is asking "is
    /// there an error on the store" and hearing it as "did MY upload fail",
    /// which is how an `unauthorized` — re-thrown untyped, so it never reached
    /// the slot at all — used to close the upload sheet as a success. Every
    /// failure now reaches BOTH: the caller gets the classification, and the
    /// slot keeps the typed reason for the surface that shows it.
    @discardableResult
    func upload(_ draft: DocumentUploadDraft) async -> DocumentWriteOutcome {
        guard let owner = captureWriteOwner() else { return .failed(.notAuthenticated) }
        lastUploadError = nil
        highlightedDocumentId = nil
        uploadingCount += 1
        // Clamped: a logout or a module stand-down resets the counter to zero
        // underneath an upload that is still in flight.
        defer {
            if owner.lease.isCurrent {
                uploadingCount = max(0, uploadingCount - 1)
            }
        }
        do {
            let outcome = try await repository.upload(draft, usage: usage)
            guard ownsWrite(owner) else { return .failed(.superseded) }
            if outcome.isDuplicate {
                highlightedDocumentId = outcome.document.id
            }
            await load()
            return .completed(succeeded: 1)
        } catch {
            guard ownsWrite(owner) else { return .failed(.superseded) }
            let classified = Self.classify(error)
            if classified == .moduleDisabled { applyError(error) }
            lastUploadError = Self.uploadFailure(for: error)
            return .failed(classified)
        }
    }

    /// Classify anything the write path can throw into the vocabulary a view is
    /// allowed to read. Nothing here string-matches: the module gate is asked
    /// through the repository's own predicate and the rest is a type check.
    private static func classify(_ error: Error) -> DocumentOperationError {
        if let typed = error as? DocumentUploadError { return .upload(typed) }
        if DocumentsRepository.isModuleDisabled(error) { return .moduleDisabled }
        if let hl = error as? HLError, case .unauthorized = hl { return .notAuthenticated }
        return .upload(.generic(LogSanitizer.redact(String(describing: error))))
    }

    /// The typed reason the *upload surface* shows. Never absent: an upload
    /// that failed always has something to say, even when the underlying error
    /// carried no user-facing classification of its own. The redacted
    /// description rides along in `.generic` for diagnostics; no view reads it.
    private static func uploadFailure(for error: Error) -> DocumentUploadError {
        (error as? DocumentUploadError) ?? .generic(LogSanitizer.redact(String(describing: error)))
    }

    /// Clear the transient upload feedback (after the UI has shown it).
    func acknowledgeUploadFeedback() {
        lastUploadError = nil
        highlightedDocumentId = nil
    }

    // MARK: - Metadata edit

    /// Rename / recategorise / re-file / replace-set the condition links. Returns
    /// the updated detail (with staged facts) on success, `nil` on failure.
    @discardableResult
    func updateMetadata(id: String, _ patch: DocumentPatch) async -> InboundDocumentDetail? {
        guard let owner = captureWriteOwner() else { return nil }
        lastError = nil
        do {
            let detail = try await repository.update(id: id, patch)
            // A superseded write hands NOTHING back: the detail it fetched is
            // the previous account's, and returning it past the boundary is the
            // leak, not the publication (Phase-06 boundary matrix).
            guard ownsWrite(owner) else { return nil }
            replaceDocument(detail.document)
            // A relink changes which episodes carry a live link — refresh the chips.
            await refreshUsage()
            return detail
        } catch {
            guard ownsWrite(owner) else { return nil }
            applyError(error)
            return nil
        }
    }

    // MARK: - Delete + restore (undo-backed)

    /// Optimistically remove a document + raise the app-wide undo pill. The server
    /// soft-delete fires in the background; tapping undo calls `POST /restore`
    /// (lossless within the 30-day grace). On a write failure the optimistic
    /// removal rolls back and the undo toast is dropped.
    ///
    /// The rollback is the fenced half: an optimistic removal that fails belongs
    /// to the query it was made in, and re-inserting it into whatever list is on
    /// screen when the failure lands puts another filter's document — or a
    /// logged-out user's — back into view. The undo toast is dropped on the
    /// wider session scope, because a toast offering to restore a document that
    /// was never deleted is wrong under any filter.
    func delete(_ document: InboundDocument, undoMessage: String) async {
        guard let owner = captureWriteOwner() else { return }
        lastError = nil
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let removed = documents.remove(at: index)
        selection.remove(document.id)

        undo?.enqueue(message: undoMessage) { [weak self] in
            guard owner.lease.isCurrent else { return }
            await self?.restore(removed, sessionLease: owner.lease)
        }

        do {
            _ = try await repository.delete(id: document.id)
            guard ownsWrite(owner) else { return }
            await refreshUsage()
        } catch {
            guard owner.lease.isCurrent else { return }
            undo?.dismiss(reason: .cancelled)
            guard ownsWrite(owner) else { return }
            if documents.firstIndex(where: { $0.id == removed.id }) == nil {
                documents.insert(removed, at: min(index, documents.count))
            }
            applyError(error)
        }
    }

    /// Undo path for a deleted document — `POST /restore` recovers the same id.
    /// On success the list + usage reload (re-inserts in server sort order); a
    /// `409` (purged / live duplicate) surfaces a friendly inline message.
    private func restore(_ document: InboundDocument, sessionLease: AuthenticatedSessionLease) async {
        guard sessionLease.isCurrent else { return }
        lastError = nil
        do {
            _ = try await repository.restore(id: document.id)
            try sessionLease.requireCurrent()
            await load()
            try sessionLease.requireCurrent()
        } catch {
            guard sessionLease.isCurrent else { return }
            if DocumentsRepository.isRestoreConflict(error) {
                lastError = String(localized: "documents.toast.restoreFailed")
            } else {
                applyError(error)
            }
        }
    }

    /// Restore a single discarded document by id (e.g. from a detail-sheet undo).
    /// Throws so the caller can map the `409` conflict inline.
    func restore(id: String) async throws {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        _ = try await repository.restore(id: id)
        try sessionLease.requireCurrent()
        await load()
        try sessionLease.requireCurrent()
    }

    // MARK: - Bulk

    /// Apply a non-delete bulk action over the current selection, then reload.
    /// Returns the per-id result array so the UI can report partial failures.
    @discardableResult
    func runBulk(_ action: DocumentBulkAction, kind: DocumentKind? = nil, episodeId: String? = nil) async -> DocumentBulkResponse? {
        guard let owner = captureWriteOwner() else { return nil }
        let ids = Array(selection)
        guard !ids.isEmpty else { return nil }
        lastError = nil
        do {
            let response = try await repository.bulk(ids: ids, action: action, kind: kind, episodeId: episodeId)
            guard ownsWrite(owner) else { return nil }
            await load()
            guard ownsWrite(owner) else { return nil }
            applyBulkOutcome(response)
            return response
        } catch {
            guard ownsWrite(owner) else { return nil }
            applyError(error)
            return nil
        }
    }

    /// Bulk soft-delete the selection with a single aggregate undo toast (restores
    /// the batch via a bulk `restore`).
    @discardableResult
    func bulkDelete(undoMessage: @escaping @Sendable (Int) -> String) async -> DocumentBulkResponse? {
        guard let owner = captureWriteOwner() else { return nil }
        let ids = Array(selection)
        guard !ids.isEmpty else { return nil }
        lastError = nil
        do {
            let response = try await repository.bulk(ids: ids, action: .delete)
            guard ownsWrite(owner) else { return nil }
            let okIds = response.results.filter(\.ok).map(\.id)
            if !okIds.isEmpty {
                undo?.enqueue(message: undoMessage(okIds.count)) { [weak self] in
                    guard owner.lease.isCurrent else { return }
                    await self?.performBulkUndoRestore(ids: okIds, sessionLease: owner.lease)
                }
            }
            await load()
            guard ownsWrite(owner) else { return nil }
            applyBulkOutcome(response)
            return response
        } catch {
            guard ownsWrite(owner) else { return nil }
            applyError(error)
            return nil
        }
    }

    /// The server's per-id truth, spent instead of discarded.
    ///
    /// Clearing the whole selection on a partial result throws away the only
    /// handle the user has on the rows the server refused: the bulk bar closes,
    /// nothing says which ids failed, and retrying means finding them again by
    /// hand.
    ///
    /// So the two halves of the answer are applied separately rather than by
    /// replacing the selection wholesale — an id the server applied is released,
    /// and an id it refused is selected. Stated that way the rule survives a
    /// selection the user changed while the batch was in flight: nothing they
    /// picked meanwhile is silently dropped, and a refusal cannot go unnoticed
    /// merely because the row was deselected a moment before the answer landed.
    private func applyBulkOutcome(_ response: DocumentBulkResponse) {
        let applied = Set(response.results.filter(\.ok).map(\.id))
        let refused = Set(response.results.filter { !$0.ok }.map(\.id))
        selection.subtract(applied)
        selection.formUnion(refused)
        guard !refused.isEmpty else {
            lastError = nil
            return
        }
        lastError = String(
            format: String(localized: "documents.bulk.partialFailure"),
            refused.count
        )
    }

    /// The bulk-undo restore body, on the main actor so it can surface failures.
    ///
    /// audit-release 05 C-2 — a failed bulk-undo restore used to be swallowed
    /// (`try?`): the docs stayed deleted, `load()` reloaded without them, and the
    /// user who tapped "Rückgängig" got no feedback. Mirrors the single-document
    /// `restore(_:)` path — surfaces an outright failure AND a partial (per-id) one.
    private func performBulkUndoRestore(ids: [String], sessionLease: AuthenticatedSessionLease) async {
        guard sessionLease.isCurrent else { return }
        do {
            let restore = try await repository.bulk(ids: ids, action: .restore)
            try sessionLease.requireCurrent()
            await load()
            try sessionLease.requireCurrent()
            if restore.results.contains(where: { !$0.ok }) {
                lastError = String(localized: "documents.toast.restoreFailed")
            }
        } catch {
            guard sessionLease.isCurrent else { return }
            await load()
            guard sessionLease.isCurrent else { return }
            if DocumentsRepository.isRestoreConflict(error) {
                lastError = String(localized: "documents.toast.restoreFailed")
            } else {
                applyError(error)
            }
        }
    }

    // MARK: - Extract (optional AI)

    /// Trigger AI extraction on a stored document (VISION mode, or TEXT mode when
    /// `text` is supplied). Returns the document + newly staged facts. Throws so
    /// the detail sheet can map `providerUnsupported` / `alreadyPartlyConfirmed`
    /// to inline copy.
    @discardableResult
    func extract(id: String, text: DocumentTextExtractRequest? = nil) async throws -> InboundDocumentDetail {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let detail = try await repository.extract(id: id, text: text)
        try sessionLease.requireCurrent()
        replaceDocument(detail.document)
        return detail
    }
}
