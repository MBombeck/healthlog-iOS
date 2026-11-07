import Foundation

// MARK: - Recently deleted (#151, server v1.46.0)

/// Why a restore or a purge from Recently deleted was refused. The screen
/// words each one and reloads the list where the row's state has moved on.
public enum DocumentTrashRefusal: Sendable, Equatable {
    /// `409 documents.inbound.restoreDuplicate`: an identical live document exists.
    case duplicateExists
    /// `409 documents.inbound.restoreGone`: purged already, nothing to restore.
    case gone
    /// `409 documents.inbound.notDeleted`: restored meanwhile, nothing to purge.
    case notDeleted
    /// `404 documents.inbound.notFound`: no such document any more.
    case notFound
}

public extension DocumentsRepository {
    /// `GET /api/documents/inbound/deleted`: the caller's deleted documents the
    /// purge has not removed yet, newest deletion first, capped at 200 rows
    /// (`meta.truncated`, `meta.limit`). Owner-only: refused (403) inside
    /// somebody else's record.
    func deletedDocuments() async throws -> ListPage<DeletedDocumentList> {
        let req: APIRequest<DeletedDocumentList> = .get("/api/documents/inbound/deleted")
        return try await api.listPage(req)
    }

    /// `POST /api/documents/inbound/{id}/purge`: removes one deleted document
    /// for good now instead of when its grace window ends.
    @discardableResult
    func purge(id: String) async throws -> Bool {
        let req: APIRequest<DocumentPurgeResult> = try .post(
            "/api/documents/inbound/\(id)/purge", body: EmptyPayload()
        )
        return try await api.send(req).purged
    }

    /// The refusal a restore or purge ran into, `nil` for every other error.
    /// A `409` without a known code reads as ``DocumentTrashRefusal/gone`` for
    /// a restore (the 1.46 server's only other 409) and as
    /// ``DocumentTrashRefusal/notDeleted`` for a purge.
    internal nonisolated static func trashRefusal(_ error: Error, purging: Bool) -> DocumentTrashRefusal? {
        guard case let HLError.server(status, code, _) = error else { return nil }
        switch (status, code) {
        case (404, _): return .notFound
        case (409, "documents.inbound.restoreDuplicate"): return .duplicateExists
        case (409, "documents.inbound.restoreGone"): return .gone
        case (409, "documents.inbound.notDeleted"): return .notDeleted
        case (409, _): return purging ? .notDeleted : .gone
        default: return nil
        }
    }
}
