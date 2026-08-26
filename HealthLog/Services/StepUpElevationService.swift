import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

// MARK: - StepUpElevation

/// A minted, in-memory-only step-up elevation. The `token` is the raw `hle_…`
/// secret — it is held only for the lifetime of the single management call it
/// authorises, and is NEVER logged (`LogSanitizer` carries an `hle_` rule as a
/// second line of defence) or persisted.
public struct StepUpElevation: Sendable, Equatable {
    public let token: String
    public let method: StepUpMethod
    /// Whether this elevation reaches the fresh-factor routes (disable,
    /// recovery-code rotation, security-key removal). A password elevation does
    /// not; the caller picks the ceremony up front on this flag so it never
    /// spends a proof on a route that will reject it.
    public let satisfiesFreshFactor: Bool

    public init(token: String, method: StepUpMethod, satisfiesFreshFactor: Bool) {
        self.token = token
        self.method = method
        self.satisfiesFreshFactor = satisfiesFreshFactor
    }
}

// MARK: - ConsumableElevation

/// Single-use wrapper that models the elevation's single-use nature in the type
/// system: ``consume()`` yields the elevation exactly once and `nil` on every
/// call thereafter. The store threads it straight into one management call and
/// discards it — there is no cache, no property that retains it, no Keychain.
///
/// Reference type on purpose: a value type would let a caller copy the elevation
/// and use it twice. `@unchecked Sendable` + an `NSLock` because the consume is
/// the atomic single-use claim across the `@MainActor` store and the `actor`
/// service boundary.
public final class ConsumableElevation: @unchecked Sendable {
    private var value: StepUpElevation?
    private let lock = NSLock()

    public init(_ elevation: StepUpElevation) {
        value = elevation
    }

    /// Returns the elevation the first time, `nil` afterwards.
    public func consume() -> StepUpElevation? {
        lock.lock()
        defer { lock.unlock() }
        defer { value = nil }
        return value
    }

    /// Hands a *borrowed* elevation back after a call the server did NOT spend
    /// it on.
    ///
    /// This is not a loophole in the single-use rule, it is the client half of
    /// it. The server validates an elevation without consuming it and claims it
    /// only when it is about to act (`src/lib/api-handler.ts:851-866` +
    /// each route's `commitElevation()` placement — see
    /// ``SecurityStepUp/consumesElevation(_:)``). A 429, a 422, a 404, or a
    /// mistyped TOTP code in the body therefore leaves the proof alive on the
    /// server. Dropping it here would force a re-mint out of one of only five
    /// per-account mints per 15 minutes, so a user who fat-fingers a disable
    /// code twice could be locked out of their own teardown.
    ///
    /// Idempotent and refill-safe: it only restores into an empty slot, so it
    /// can never overwrite a newer elevation nor resurrect one that was already
    /// spent and replaced.
    func restore(_ elevation: StepUpElevation) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return }
        value = elevation
    }

    /// Non-consuming peek at whether a fresh factor was proved — the UI reads
    /// this to decide whether an elevation may drive a fresh-factor route
    /// without spending it.
    public var satisfiesFreshFactor: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value?.satisfiesFreshFactor ?? false
    }

    public var isSpent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == nil
    }
}

// MARK: - StepUpElevationService

#if canImport(AuthenticationServices)

    /// Runs the step-up ceremony (`options → assertion → mint`) and hands back a
    /// single-use ``ConsumableElevation``. Kept as an `actor` so the mint is
    /// serialised and the raw secret never sits on a shared mutable surface.
    ///
    /// **Reachable arms.** `password` and `totp` mint directly (no ceremony).
    /// `passkey` runs the PRIMARY-passkey assertion the login flow already uses
    /// (reused verbatim — zero `PasskeyService` change). The `webauthn`
    /// (physical security-key) assertion is deliberately absent: it needs an
    /// `ASAuthorizationSecurityKeyPublicKeyCredentialProvider` ceremony the
    /// current `PasskeyService` (platform-provider only) does not implement, and
    /// `totp` / `passkey` already cover every fresh-factor action a native client
    /// needs.
    public actor StepUpElevationService {
        private let repo: AccountSecurityRepository
        private let passkey: PasskeyServiceProtocol

        public init(repo: AccountSecurityRepository, passkey: PasskeyServiceProtocol) {
            self.repo = repo
            self.passkey = passkey
        }

        /// Mint an elevation by re-proving the account password. Reaches only the
        /// non-fresh routes (setup / confirm / register-options / rename).
        public func elevate(password: String) async throws -> ConsumableElevation {
            let mint = try await repo.stepUpMint(.password(password))
            return Self.wrap(mint, fallback: .password)
        }

        /// Mint an elevation by re-proving a current TOTP code. A fresh factor —
        /// reaches the destructive routes.
        public func elevate(totp code: String) async throws -> ConsumableElevation {
            let mint = try await repo.stepUpMint(.totp(code))
            return Self.wrap(mint, fallback: .totp)
        }

        /// Mint an elevation by asserting a PRIMARY passkey. A fresh factor.
        ///
        /// `options → passkey.assert → mint`. A **409** from `options` (no passkey
        /// on the account) propagates so the caller can offer another arm.
        public func elevateWithPasskey(anchor: ASPresentationAnchorProvider) async throws -> ConsumableElevation {
            let opts = try await repo.stepUpOptions(.passkey)
            let assertion = try await passkey.assert(
                challenge: opts.options.challenge,
                rpId: opts.options.rpId,
                allowCredentialIDs: opts.options.allowCredentials?.map(\.id) ?? [],
                anchor: anchor
            )
            let credential = WebAuthnAssertionCredential(
                id: assertion.credentialID,
                rawId: assertion.credentialID,
                response: .init(
                    clientDataJSON: assertion.clientDataJSON,
                    authenticatorData: assertion.authenticatorData,
                    signature: assertion.signature,
                    userHandle: assertion.userHandle
                )
            )
            let mint = try await repo.stepUpMint(
                .passkey(challengeId: opts.challengeId, credential: credential)
            )
            return Self.wrap(mint, fallback: .passkey)
        }

        /// Wraps a mint response, trusting the server's echoed `method` /
        /// `satisfiesFreshFactor` but falling back to the arm we asked for if the
        /// method string ever drifts.
        private static func wrap(_ mint: StepUpMintResponse, fallback: StepUpMethod) -> ConsumableElevation {
            let method = StepUpMethod(rawValue: mint.method) ?? fallback
            return ConsumableElevation(
                StepUpElevation(
                    token: mint.elevation,
                    method: method,
                    satisfiesFreshFactor: mint.satisfiesFreshFactor
                )
            )
        }
    }

#endif
