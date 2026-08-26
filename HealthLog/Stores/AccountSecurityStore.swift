import Foundation
import Observation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

/// Outcome of the last change-password submit, rendered as a single inline
/// message — the web surface's one-`role="alert"`-row model
/// (`account-section/index.tsx:554-565`), not a toast and not an alert sheet.
///
/// Deliberately declared at file scope rather than nested inside
/// ``AccountSecurityStore``: a type nested in a `@MainActor` class inherits that
/// global-actor isolation, which would make this value type unusable from a
/// nonisolated context (including the tests that exercise the classifier).
public enum ChangePasswordOutcome: Equatable, Sendable {
    case success
    /// A local pre-flight failure; never hit the network.
    case validation(ChangePasswordValidation.Failure)
    /// The account has a second factor, so the server demands a fresh cookie
    /// step-up that a Bearer client cannot produce. Distinct from `.failure`
    /// because the remedy is different and specific.
    case stepUpRequired
    /// Server prose, shown verbatim (wrong current password, too weak,
    /// breached, rate-limited …).
    case failure(String)
}

/// `@Observable` state for the Settings → Security password-change surface.
///
/// Holds no password material beyond the in-flight call: the fields live in the
/// sheet's `@State` and are cleared by it on success, matching the web dialog
/// (`account-section/index.tsx:211-213`). Nothing here is persisted.
@MainActor
@Observable
public final class AccountSecurityStore {
    public private(set) var isSaving: Bool = false
    public private(set) var outcome: ChangePasswordOutcome?

    private let repo: AccountSecurityRepository
    #if canImport(AuthenticationServices)
        private let stepUp: StepUpElevationService?
    #endif

    #if canImport(AuthenticationServices)
        public init(repo: AccountSecurityRepository, stepUp: StepUpElevationService? = nil) {
            self.repo = repo
            self.stepUp = stepUp
        }
    #else
        public init(repo: AccountSecurityRepository) {
            self.repo = repo
        }
    #endif

    /// Runs the local gate, then the request. Safe to call repeatedly; a second
    /// call while one is in flight is ignored so a double-tap cannot spend two
    /// of the five allowed attempts per 15 minutes.
    public func changePassword(current: String, new: String, confirm: String) async {
        guard !isSaving else { return }

        if let failure = ChangePasswordValidation.validate(current: current, new: new, confirm: confirm) {
            outcome = .validation(failure)
            return
        }

        isSaving = true
        outcome = nil
        defer { isSaving = false }

        do {
            try await repo.changePassword(current: current, new: new, confirm: confirm)
            outcome = .success
        } catch let err as HLError {
            outcome = Self.classify(err)
        } catch {
            outcome = .failure(LogSanitizer.redact(String(describing: error)))
        }
    }

    /// Maps a thrown `HLError` onto the surfaced outcome.
    ///
    /// Step-up is checked **first** and on the typed code, never on the status
    /// alone: this endpoint returns 401 for a wrong current password too, and
    /// only the step-up rejection carries `meta.errorCode`.
    ///
    /// `nonisolated` + `static` so the mapping is unit-testable without a
    /// `@MainActor` hop or a live repository.
    nonisolated static func classify(_ err: HLError) -> ChangePasswordOutcome {
        if SecurityStepUp.isRequired(err) { return .stepUpRequired }
        if case let .server(_, _, message) = err, !message.isEmpty {
            // Server prose is written for the end user and is more specific
            // than anything we could substitute ("Current password is
            // incorrect", "New password must differ from current password",
            // the zxcvbn feedback line, the 15-minute rate-limit notice).
            return .failure(message)
        }
        return .failure(err.localizedDescription)
    }

    /// Clears the inline message (e.g. when the user edits a field again).
    public func clearOutcome() {
        outcome = nil
    }

    public func clearOnLogout() {
        outcome = nil
        isSaving = false
        twoFactor = .idle
        isBusy = false
        actionError = nil
        // Session-scoped sensitive material must NOT survive a sign-out.
        revealedRecoveryCodes = nil
        pendingTotpSetup = nil
    }

    // MARK: - Native 2FA management (#57)

    /// The 2FA card's status, resolved server-side.
    public enum TwoFactorState: Equatable, Sendable {
        /// Not yet loaded.
        case idle
        case loading
        /// Server is below the minimum version that exposes the native
        /// management routes — the honest "manage 2FA on the web" card renders.
        case unavailable
        /// Real status from `GET /api/auth/me/mfa`.
        case loaded(MfaStatus)
        /// The status read failed (transport/decoding). Distinct from
        /// `unavailable`, which is a deliberate server-capability gate.
        case failed(String)
    }

    public private(set) var twoFactor: TwoFactorState = .idle
    /// A management action (mint / setup / confirm / disable / …) is in flight.
    public private(set) var isBusy: Bool = false
    /// The last management-action error, user-facing. `nil` once cleared.
    public private(set) var actionError: String?
    /// Recovery codes surfaced **exactly once** (after confirm or regenerate).
    /// Held here only until the presenting sheet copies/dismisses them, then
    /// cleared via ``consumeRevealedRecoveryCodes()``. Never logged/persisted.
    public private(set) var revealedRecoveryCodes: [String]?
    /// The pending TOTP secret + otpauth URI, surfaced once during enrolment.
    public private(set) var pendingTotpSetup: TotpSetupResponse?

    /// Whether the account currently has an active authenticator factor.
    ///
    /// The step-up arm picker reads this instead of assuming: a TOTP arm on an
    /// account with no authenticator is a field that can only ever fail, and a
    /// security-key-only account (enrolled, so `mfa_not_enrolled` never fires)
    /// would be left staring at it on every fresh-factor route.
    public var isTotpEnabled: Bool {
        if case let .loaded(status) = twoFactor { return status.totp.enabled }
        return false
    }

    /// Loads the 2FA surface: version-gate first (older self-hosted servers keep
    /// the web-only card), then the real status.
    public func loadTwoFactor() async {
        twoFactor = .loading
        actionError = nil
        do {
            let version = try await repo.serverVersion()
            guard TwoFactorManagement.isAvailable(on: version) else {
                twoFactor = .unavailable
                return
            }
            let status = try await repo.mfaStatus()
            twoFactor = .loaded(status)
        } catch {
            twoFactor = .failed(Self.userMessage(for: error))
        }
    }

    /// Re-reads status only (after a mutation). Leaves `unavailable` untouched.
    public func refreshTwoFactorStatus() async {
        guard case .loaded = twoFactor else { return }
        do {
            twoFactor = try await .loaded(repo.mfaStatus())
        } catch {
            // Keep the last-known status painted; surface the refresh miss.
            actionError = Self.userMessage(for: error)
        }
    }

    public func clearActionError() {
        actionError = nil
    }

    /// Reads and clears the one-time recovery codes so a second read yields nil.
    public func consumeRevealedRecoveryCodes() -> [String]? {
        defer { revealedRecoveryCodes = nil }
        return revealedRecoveryCodes
    }

    public func clearPendingTotpSetup() {
        pendingTotpSetup = nil
    }

    // MARK: Step-up ceremony (mint helpers)

    #if canImport(AuthenticationServices)
        /// Mints a password elevation (non-fresh routes only).
        public func mint(password: String) async throws -> ConsumableElevation {
            guard let stepUp else { throw HLError.unknown("Step-up unavailable") }
            return try await stepUp.elevate(password: password)
        }

        /// Mints a TOTP elevation (a fresh factor).
        public func mint(totp code: String) async throws -> ConsumableElevation {
            guard let stepUp else { throw HLError.unknown("Step-up unavailable") }
            return try await stepUp.elevate(totp: code)
        }

        /// Mints a passkey elevation (a fresh factor). A 409 (no passkey)
        /// propagates so the caller can offer another arm.
        public func mintWithPasskey(anchor: ASPresentationAnchorProvider) async throws -> ConsumableElevation {
            guard let stepUp else { throw HLError.unknown("Step-up unavailable") }
            return try await stepUp.elevateWithPasskey(anchor: anchor)
        }
    #endif

    // MARK: Management actions (each consumes one elevation)

    /// Begins TOTP enrolment. Non-fresh route (a password elevation suffices).
    /// On success `pendingTotpSetup` holds the once-shown secret/URI.
    public func beginTotpSetup(elevation: ConsumableElevation) async {
        await run(elevation: elevation) { token in
            self.pendingTotpSetup = try await self.repo.totpSetup(elevation: token)
        }
    }

    /// Confirms enrolment with a code. On success `revealedRecoveryCodes` holds
    /// the once-delivered batch and status is refreshed.
    public func confirmTotp(code: String, elevation: ConsumableElevation) async {
        await run(elevation: elevation) { token in
            let result = try await self.repo.totpConfirm(code: code, elevation: token)
            self.revealedRecoveryCodes = result.recoveryCodes
            self.pendingTotpSetup = nil
            await self.refreshTwoFactorStatus()
        }
    }

    /// Disables the second factor. Fresh-factor route: the elevation MUST be
    /// totp/passkey-proved (never a password), enforced by the caller's arm
    /// choice.
    public func disableTotp(
        code: String,
        method: MfaDisableRequestBody.Method,
        elevation: ConsumableElevation
    ) async {
        await run(elevation: elevation) { token in
            try await self.repo.disableTotp(code: code, method: method, elevation: token)
            await self.refreshTwoFactorStatus()
        }
    }

    /// Rotates the recovery-code batch. Fresh-factor route. On success
    /// `revealedRecoveryCodes` holds the new batch.
    public func regenerateRecoveryCodes(elevation: ConsumableElevation) async {
        await run(elevation: elevation) { token in
            let result = try await self.repo.regenerateRecoveryCodes(elevation: token)
            self.revealedRecoveryCodes = result.recoveryCodes
            await self.refreshTwoFactorStatus()
        }
    }

    /// Renames a registered security key. Non-fresh route.
    public func renameSecurityKey(id: String, name: String, elevation: ConsumableElevation) async {
        await run(elevation: elevation) { token in
            try await self.repo.renameSecurityKey(id: id, name: name, elevation: token)
            await self.refreshTwoFactorStatus()
        }
    }

    /// Removes a registered security key. Fresh-factor route.
    public func deleteSecurityKey(id: String, elevation: ConsumableElevation) async {
        await run(elevation: elevation) { token in
            try await self.repo.deleteSecurityKey(id: id, elevation: token)
            await self.refreshTwoFactorStatus()
        }
    }

    /// Shared action wrapper: borrows the elevation, runs the mutation, and maps
    /// errors. Refuses a spent elevation up front (defence in depth — the store
    /// never re-uses one, but a double-tap could).
    ///
    /// **The elevation is given back when the server did not spend it.** Only a
    /// gate rejection (`auth.stepup.*`) burns the proof; a 429, 422, 404, 409 or
    /// a wrong code in the body leaves it alive server-side, and re-minting
    /// there would spend one of five per-account mints per 15 minutes. See
    /// ``SecurityStepUp/consumesElevation(_:)`` for the route-by-route evidence.
    private func run(
        elevation: ConsumableElevation,
        _ body: @escaping (_ token: String) async throws -> Void
    ) async {
        guard !isBusy else { return }
        guard let proof = elevation.consume() else {
            actionError = String(localized: "settings.security.twoFactor.error.reverify")
            return
        }
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            try await body(proof.token)
        } catch let err as HLError where SecurityStepUp.isMfaNotEnrolled(err) {
            // The proof was fine; the account simply has no second factor for a
            // fresh-factor route to be fresh about. Re-verifying cannot fix that
            // — enrolling can, so say that instead of "please confirm again".
            actionError = String(localized: "settings.security.twoFactor.error.notEnrolled")
        } catch let err as HLError where SecurityStepUp.isRequired(err) {
            // The gate refused the elevation (missing / expired / already spent /
            // minted from too weak a factor / bound to another token). The
            // refusal is deliberately uniform, so do NOT try to diagnose it:
            // drop the proof and ask for a fresh one.
            actionError = String(localized: "settings.security.twoFactor.error.reverify")
        } catch {
            if !SecurityStepUp.consumesElevation(error) { elevation.restore(proof) }
            actionError = Self.userMessage(for: error)
        }
    }

    /// Maps a thrown error to a user-facing string WITHOUT leaking secrets — an
    /// `HLError` never carries token material, but a stray `String(describing:)`
    /// runs through `LogSanitizer` as belt-and-braces.
    nonisolated static func userMessage(for error: Error) -> String {
        if let hl = error as? HLError { return hl.userFacingDescription }
        return LogSanitizer.redact(String(describing: error))
    }
}
