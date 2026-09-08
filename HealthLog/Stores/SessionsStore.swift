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

    /// v1.38.11 — whether the running server spares THIS device when "sign out
    /// everywhere" is used (``SignOutEverywhereElse``). Drives which of the two
    /// consequence texts the screen shows; `false` is the conservative verdict
    /// (the old copy, which warns that this device may be signed out too), so an
    /// unknown or unreachable server never produces a promise the server does
    /// not keep. Resolved on every ``load()``.
    public private(set) var sparesThisDevice: Bool = false

    private let repo: SessionsRepository
    private let serverVersion: @Sendable () async throws -> ServerVersionInfo

    /// v1.38.11 — `serverVersion` reads the running build's `/api/version`
    /// payload so the screen can pick honest copy. Injected rather than taken
    /// off `SessionsRepository`: the probe already exists on
    /// `AccountSecurityRepository` (the 2FA gate uses it), and the sessions
    /// repository has no business growing a second one.
    public init(
        repo: SessionsRepository,
        serverVersion: @escaping @Sendable () async throws -> ServerVersionInfo
    ) {
        self.repo = repo
        self.serverVersion = serverVersion
    }

    /// (Re)loads the active sessions — and, alongside them, the server verdict
    /// that decides the "sign out everywhere" wording. The two run concurrently
    /// on purpose: the list is the security surface and must not queue behind a
    /// probe that only picks between two texts.
    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let verdict = resolvedSparesThisDevice()
        do {
            sessions = try await repo.list()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
        sparesThisDevice = await verdict
    }

    /// v1.38.11 — best-effort version read. A miss is deliberately silent and
    /// answers `false`: the verdict only picks between two truthful texts, so
    /// surfacing it as an error would put a red alert in front of a user whose
    /// session list loaded perfectly well. `nonisolated` so `load()` can run it
    /// alongside the list rather than in front of it.
    private nonisolated func resolvedSparesThisDevice() async -> Bool {
        guard let version = try? await serverVersion() else { return false }
        return SignOutEverywhereElse.sparesThisDevice(on: version)
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

    /// Revokes every other session. See `SessionsRepository.revokeOthers`: below
    /// server v1.38.11 this also revokes the *caller's* refresh token, from
    /// v1.38.11 it does not. ``sparesThisDevice`` carries that distinction to
    /// the screen, whose confirmation copy is written around it.
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
        // v1.38.11 — the next account may sit on a different server, so the
        // copy verdict must not outlive the sign-out that produced it.
        sparesThisDevice = false
        error = nil
    }
}
