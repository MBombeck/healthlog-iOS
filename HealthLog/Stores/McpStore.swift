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

    /// R2 / #115 A3 — set when the server wants a fresh proof for a mint;
    /// the mint sheet asks for it and mints again. SEC — on a server that reads
    /// the proof, the store asks before the first attempt (``mintToken(name:scope:)``).
    public let stepUp: StepUpRetry

    private let repo: McpRepository
    private let proofUpFront: @MainActor () async -> Bool

    /// - Parameters:
    ///   - proofUpFront: whether a mint needs a step-up elevation before it is
    ///     sent. The screen passes ``resolveProofUpFront(security:)``; without
    ///     one the store asks for the proof (fail closed).
    ///   - now: the clock the held elevation ages against (tests).
    public init(
        repo: McpRepository,
        proofUpFront: (@MainActor () async -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repo = repo
        self.proofUpFront = proofUpFront ?? { true }
        stepUp = StepUpRetry(now: now)
    }

    /// A mint the proof was waived for: the account turned out to hold
    /// nothing to prove (``waiveProof()``), or the server said so
    /// (`auth.stepup.mfa_not_enrolled`). Spent by the next mint.
    @ObservationIgnored private var proofWaived = false

    /// POLISH-C (C1, #163 B1) — the server's `elevation-if-enrolled` rule
    /// for `POST /api/mcp/tokens`, mirrored: an account with a second factor
    /// (an authenticator or a security key) or a passkey brings a fresh
    /// proof; one without any of them (most SSO-only accounts) mints on the
    /// token. The server version plays no part, so an unknown version or a
    /// failed `GET /api/version` can never let an enrolled account's
    /// credential leave without the proof.
    ///
    /// Anything short of a loaded status counts as enrolled: not loaded yet,
    /// a failed read, a server without the native status route
    /// (`.unavailable`), and a status without `proofMethods` (server before
    /// 1.46.2), where a passkey cannot be ruled out. The proof sheet then
    /// asks; if no proof is possible, the server's `mfa_not_enrolled` lets
    /// the mint go without one (``mintToken(name:scope:)``).
    nonisolated static func accountNeedsProof(_ state: AccountSecurityStore.TwoFactorState) -> Bool {
        guard case let .loaded(status) = state else { return true }
        if status.totp.enabled || !status.webauthn.isEmpty { return true }
        guard let methods = status.proofMethods else { return true }
        return methods.contains("passkey")
    }

    /// The gate at the moment of a mint: the account's second-factor status,
    /// read once if it is not loaded yet.
    static func resolveProofUpFront(security: AccountSecurityStore) async -> Bool {
        if case .loaded = security.twoFactor {} else { await security.loadTwoFactor() }
        return accountNeedsProof(security.twoFactor)
    }

    /// The proof sheet learned that this account holds nothing to prove: the
    /// next mint goes on the token, once.
    public func waiveProof() {
        proofWaived = true
        stepUp.cancel()
        if error == StepUpRetry.requiredMessage { error = nil }
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
    ///
    /// SEC — when ``proofUpFront`` holds, nothing is sent without a fresh
    /// elevation: the store asks for one (``StepUpRetry/require()``) and
    /// returns; the sheet re-runs the mint once the proof is given. A closed
    /// proof sheet, an elevation past ``StepUpRetry/maximumAge`` and one dropped
    /// by ``abandonMint()`` all end here again.
    @discardableResult
    public func mintToken(name: String, scope: McpTokenScope) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMinting else { return false }
        // Claimed before the first suspension: a second tap finds `isMinting`
        // set and the elevation gone.
        isMinting = true
        error = nil
        defer { isMinting = false }
        let elevation = stepUp.take()
        let waived = proofWaived
        proofWaived = false
        if elevation == nil, !waived, await proofUpFront() {
            stepUp.require()
            error = StepUpRetry.requiredMessage
            return false
        }

        do {
            freshToken = try await mintOnce(name: trimmed, scope: scope, elevation: elevation)
            tokens = await (try? repo.listTokens()) ?? tokens
            return true
        } catch let err as HLError {
            error = stepUp.requestIfProofRefusal(err) ? StepUpRetry.requiredMessage : err.userFacingDescription
            return false
        } catch {
            self.error = String(localized: "Couldn't create the token. Please try again.")
            return false
        }
    }

    /// One mint. A proof the server cannot use because the account has no
    /// second factor (`auth.stepup.mfa_not_enrolled`) is no reason to stop:
    /// the server's own rule lets such an account mint on the token, so the
    /// mint goes once more without it.
    private func mintOnce(name: String, scope: McpTokenScope, elevation: String?) async throws -> ApiTokenMintResponse {
        do {
            return try await repo.mintToken(name: name, scope: scope, elevation: elevation)
        } catch let err as HLError where elevation != nil && SecurityStepUp.isMfaNotEnrolled(err) {
            return try await repo.mintToken(name: name, scope: scope, elevation: nil)
        }
    }

    /// SEC — the mint sheet went away (closed, swiped down, or unmounted by
    /// the privacy shield when the app left the foreground): a proof given for
    /// it, or asked for it, is not carried to a later mint.
    public func abandonMint() {
        stepUp.cancel()
        proofWaived = false
        if error == StepUpRetry.requiredMessage { error = nil }
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
        stepUp.cancel()
        proofWaived = false
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
