import Foundation

/// Drives Settings → MCP (Build 2 / 2.7): the live-connection list, the
/// connector-token list, minting, and — the reason this surface exists at all —
/// revocation of both.
///
/// **Secret handling:** ``freshToken`` holds the raw `hlk_…` bearer for exactly
/// as long as the show-once sheet is on screen. It is never persisted, never
/// logged, and cleared on dismissal and on logout.
@MainActor
@Observable
public final class McpStore {
    public private(set) var connections: [McpConnectionDTO] = []
    public private(set) var tokens: [ApiTokenDTO] = []
    public private(set) var isLoading = false
    public private(set) var isMinting = false
    /// Ids with a revoke in flight — drives the per-row spinner and keeps a
    /// double-tap from firing two DELETEs.
    public private(set) var revoking: Set<String> = []
    public private(set) var error: String?

    /// The raw secret from the most recent mint. Non-nil only while the
    /// show-once sheet is presented.
    public private(set) var freshToken: ApiTokenMintResponse?

    private let repo: McpRepository

    public init(repo: McpRepository) {
        self.repo = repo
    }

    /// Tokens that can still be used — the ones worth revoking.
    public var activeTokens: [ApiTokenDTO] {
        tokens.filter { $0.isLive() }
    }

    /// Revoked or expired tokens, kept behind a disclosure for auditability.
    public var inactiveTokens: [ApiTokenDTO] {
        tokens.filter { !$0.isLive() }
    }

    /// Load both lists. They are independent surfaces, so a failure on one must
    /// not blank the other — in particular a token-list failure must never hide
    /// the CONNECTION list, which is the security-critical one.
    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        async let connectionsResult = fetchConnections()
        async let tokensResult = fetchTokens()
        let (conns, toks) = await (connectionsResult, tokensResult)

        var failures: [String] = []
        switch conns {
        case let .success(value): connections = value
        case let .failure(err): failures.append(err.message)
        }
        switch toks {
        case let .success(value): tokens = value
        case let .failure(err): failures.append(err.message)
        }
        error = failures.first
    }

    /// `Swift.Result` requires its `Failure` to conform to `Error`, which
    /// `String` does not. This carries the already-user-facing message without
    /// making `String` globally `Error`-conforming.
    private struct LoadFailure: Error {
        let message: String
    }

    private func fetchConnections() async -> Result<[McpConnectionDTO], LoadFailure> {
        do {
            let value = try await repo.listConnections()
            return .success(value)
        } catch let err as HLError {
            return .failure(LoadFailure(message: err.userFacingDescription))
        } catch {
            return .failure(LoadFailure(message: String(localized: "Couldn't load MCP connections. Please try again.")))
        }
    }

    private func fetchTokens() async -> Result<[ApiTokenDTO], LoadFailure> {
        do {
            let value = try await repo.listTokens()
            return .success(value)
        } catch let err as HLError {
            return .failure(LoadFailure(message: err.userFacingDescription))
        } catch {
            return .failure(LoadFailure(message: String(localized: "Couldn't load MCP tokens. Please try again.")))
        }
    }

    /// Cut a live assistant connection. Optimistically removes the row so the
    /// user gets immediate confirmation that access is gone, then reconciles.
    public func revokeConnection(id: String) async {
        guard !revoking.contains(id) else { return }
        revoking.insert(id)
        error = nil
        defer { revoking.remove(id) }

        let previous = connections
        connections.removeAll { $0.id == id }
        do {
            try await repo.revokeConnection(id: id)
        } catch let err as HLError {
            connections = previous
            error = err.userFacingDescription
        } catch {
            connections = previous
            self.error = String(localized: "Couldn't revoke the connection. Please try again.")
        }
    }

    public func revokeToken(id: String) async {
        guard !revoking.contains(id) else { return }
        revoking.insert(id)
        error = nil
        defer { revoking.remove(id) }

        do {
            try await repo.revokeToken(id: id)
            tokens = await (try? repo.listTokens()) ?? tokens
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't revoke the token. Please try again.")
        }
    }

    /// Mint a connector token. On success the raw secret lands in
    /// ``freshToken`` for the show-once sheet.
    @discardableResult
    public func mintToken(name: String, scope: McpTokenScope) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMinting else { return false }
        isMinting = true
        error = nil
        defer { isMinting = false }

        do {
            freshToken = try await repo.mintToken(name: trimmed, scope: scope)
            tokens = await (try? repo.listTokens()) ?? tokens
            return true
        } catch let err as HLError {
            error = err.userFacingDescription
            return false
        } catch {
            self.error = String(localized: "Couldn't create the token. Please try again.")
            return false
        }
    }

    /// Drop the raw secret once the show-once sheet is dismissed.
    public func clearFreshToken() {
        freshToken = nil
    }

    public func clearError() {
        error = nil
    }

    /// Wipe every trace on logout — a raw bearer must not outlive the session.
    public func clearOnLogout() {
        connections = []
        tokens = []
        freshToken = nil
        error = nil
        revoking = []
    }
}

/// Drives Settings → API tokens (Build 2 / 2.8). **List + revoke only** — the
/// generic mint route was removed server-side (see ``ApiTokenRepository``), so
/// there is deliberately no create path here.
@MainActor
@Observable
public final class ApiTokenStore {
    public private(set) var tokens: [ApiTokenDTO] = []
    public private(set) var isLoading = false
    public private(set) var revoking: Set<String> = []
    public private(set) var error: String?

    private let repo: ApiTokenRepository

    public init(repo: ApiTokenRepository) {
        self.repo = repo
    }

    /// Usable tokens — a leaked one of these is the thing 2.8 exists to kill.
    public var activeTokens: [ApiTokenDTO] {
        tokens.filter { $0.isLive() }
    }

    /// Revoked or expired, retained for auditability behind a disclosure.
    public var inactiveTokens: [ApiTokenDTO] {
        tokens.filter { !$0.isLive() }
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            tokens = try await repo.list()
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't load API tokens. Please try again.")
        }
    }

    public func revoke(id: String) async {
        guard !revoking.contains(id) else { return }
        revoking.insert(id)
        error = nil
        defer { revoking.remove(id) }
        do {
            try await repo.revoke(id: id)
            await load()
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't revoke the token. Please try again.")
        }
    }

    public func clearError() {
        error = nil
    }

    public func clearOnLogout() {
        tokens = []
        error = nil
        revoking = []
    }
}
