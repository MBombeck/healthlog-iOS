import Foundation
import Observation

/// `@Observable` wrapper over `SessionsRepository` for the Settings → Account →
/// "Active sessions" surface (parity item 2.2).
///
/// **No persistence.** The list is server-authoritative and re-fetched on every
/// screen open / pull-to-refresh. Caching a security inventory would let a
/// revoked session keep painting as live, which is the one failure mode this
/// screen exists to prevent. Mirrors `PasskeyManagementStore`.
@MainActor
@Observable
public final class SessionsStore {
    public private(set) var sessions: [SessionEntry] = []
    public private(set) var isLoading: Bool = false
    /// Id of the session currently being revoked — drives the per-row spinner
    /// and keeps a second tap on the same row inert.
    public private(set) var revokingID: String?
    public private(set) var isRevokingOthers: Bool = false
    public private(set) var error: HLError?
    /// Set after a successful "sign out everywhere else" so the screen can
    /// confirm the outcome. Carries the server's `Session`-row count, which is
    /// NOT a device count (see `SessionsRepository.revokeOthers`).
    public private(set) var lastRevokedOthersCount: Int?

    private let repo: SessionsRepository

    public init(repo: SessionsRepository) {
        self.repo = repo
    }

    /// (Re)loads the active sessions.
    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            sessions = try await repo.list()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Revokes a single session, then re-loads so the list reflects server
    /// truth rather than an optimistic local removal (a revoke that silently
    /// failed must not leave the row hidden).
    public func revoke(id: String) async {
        guard revokingID == nil else { return }
        revokingID = id
        error = nil
        defer { revokingID = nil }
        do {
            try await repo.revoke(id: id)
            await load()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Revokes every other session. See `SessionsRepository.revokeOthers` for
    /// why this also revokes the *caller's* refresh token on a native client —
    /// the screen's confirmation copy is written around that reality.
    public func revokeOthers() async {
        guard !isRevokingOthers else { return }
        isRevokingOthers = true
        error = nil
        defer { isRevokingOthers = false }
        do {
            lastRevokedOthersCount = try await repo.revokeOthers()
            await load()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func clearError() {
        error = nil
    }

    public func clearRevokedOthersConfirmation() {
        lastRevokedOthersCount = nil
    }

    public func clearOnLogout() {
        sessions = []
        revokingID = nil
        isRevokingOthers = false
        lastRevokedOthersCount = nil
        error = nil
    }
}
