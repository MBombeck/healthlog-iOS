import Foundation

/// Wraps `GET /api/sync/state` (server v1.4.30).
///
/// **Cache strategy:** none. The endpoint is a handshake that bumps
/// `User.lastSyncedAt` server-side on every call. Caching would skip
/// the bump and re-emit a stale checkpoint to the caller. Refresh
/// surfaces — pair / unpair, foreground revalidate, pre-anchored-HK-
/// query — drive the call directly when they need a fresh snapshot.
///
/// **Why a thin actor wrap:** the call is one network read, the DTO is
/// the entire payload (no transformation), and no client logic depends
/// on the wire-form details beyond the decoded `ServerSyncStateDTO`.
/// The actor exists for API symmetry with the other repos and to
/// localise the path/query construction in one place.
///
/// **Server-error surface:** routes the standard `HLError.server(...)`
/// up the stack — callers decide whether to surface the failure
/// (e.g. SyncMode store sets a `lastHandshakeError` flag) or swallow
/// (e.g. background sync coordinator just retries).
public actor SyncStateRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetches the latest sync state. Side-effect server-side: bumps
    /// `User.lastSyncedAt`. The returned `lastSyncedAt` is the PRE-bump
    /// value so callers learn the previous checkpoint cleanly.
    public func handshake() async throws -> ServerSyncStateDTO {
        let req: APIRequest<ServerSyncStateDTO> = .get("/api/sync/state")
        return try await api.send(req)
    }
}
