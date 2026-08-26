import Foundation

// MARK: - Change password

/// Request body for `POST /api/auth/password`.
///
/// All three fields are sent, mirroring the web client
/// (`settings/account-section/index.tsx:190-200`). The server re-checks the
/// `newPassword == confirmPassword` equality itself
/// (`src/lib/validations/auth.ts:88-102`, issue path `["confirmPassword"]`), so
/// dropping `confirmPassword` client-side would trade a clear 422 for a silent
/// contract drift. It stays on the wire.
public struct ChangePasswordBody: Encodable, Sendable, Equatable {
    public let currentPassword: String
    public let newPassword: String
    public let confirmPassword: String

    public init(currentPassword: String, newPassword: String, confirmPassword: String) {
        self.currentPassword = currentPassword
        self.newPassword = newPassword
        self.confirmPassword = confirmPassword
    }
}

/// The single client-side gate before `POST /api/auth/password` fires.
///
/// Deliberately minimal, matching the web dialog
/// (`account-section/index.tsx:182-187`): the **only** local check is the
/// new/confirm mismatch, because it is the one failure the user can fix without
/// a round-trip and the one the server cannot phrase better. Everything else —
/// the 12-character floor (`PASSWORD_MIN_LENGTH`), the zxcvbn score-3 gate, the
/// HIBP breach check, "must differ from current" — is server truth and is
/// surfaced verbatim from the envelope. Re-implementing those rules here would
/// create two sources of truth that drift the moment the operator retunes the
/// server policy.
public enum ChangePasswordValidation: Equatable, Sendable {
    /// Local pre-flight outcome. `nil` from ``validate(new:confirm:)`` means
    /// "nothing locally wrong — let the server judge it".
    public enum Failure: Equatable, Sendable {
        /// New and confirmation differ. Never reaches the network.
        case mismatch
        /// A required field is empty. The web dialog leaves the button live and
        /// lets the server 422; we block it instead, because an empty-field
        /// round-trip on a rate-limited endpoint (5 attempts / 15 min) spends a
        /// scarce attempt on a mistake the client can see.
        case incomplete
    }

    /// Validates the two locally-checkable conditions.
    ///
    /// - Returns: the failure, or `nil` when the form may be submitted.
    public static func validate(
        current: String,
        new: String,
        confirm: String
    ) -> Failure? {
        if current.isEmpty || new.isEmpty || confirm.isEmpty { return .incomplete }
        if new != confirm { return .mismatch }
        return nil
    }
}

// MARK: - Passkey rename

/// Request body for `PATCH /api/auth/passkeys/{id}`.
///
/// The server field is `name` (`src/app/api/auth/passkeys/[id]/route.ts:15`,
/// `webauthnKeyNameSchema`: trimmed, 1–64 chars, required). The trim happens
/// here so the 1-char floor is evaluated against the same string the server
/// will store — a whitespace-only name must fail the client gate, not arrive as
/// a 422.
public struct PasskeyRenameBody: Encodable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// Client-side rules for a passkey/security-key display name, mirroring
/// `webauthnKeyNameSchema` so the disabled-submit state and the server's 422
/// agree on what "valid" means.
public enum WebAuthnKeyName {
    /// Server contract: `z.string().trim().min(1).max(64)`.
    public static let maxLength = 64

    /// Normalises a user-typed name to what should go on the wire.
    public static func normalized(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    /// Whether `raw` may be submitted. Mirrors the web submit-disabled rule
    /// (`security-keys-card.tsx`: `editName.trim().length === 0`).
    public static func isValid(_ raw: String) -> Bool {
        !normalized(raw).isEmpty
    }
}

// MARK: - Step-up

/// Classifies the server's `auth.stepup.*` 401 so the UI can say something true
/// about it *inline* instead of bouncing the user to Safari.
///
/// **Why this needs a typed home.** `POST /api/auth/password` is gated on
/// `requireFreshMfaIfEnrolled` (`src/lib/api-handler.ts:603-621`). For an
/// account with **no** second factor that is a pass-through and a Bearer token
/// is enough. For an account **with** TOTP or a security key it delegates to
/// `requireFreshMfa`, which resolves the session via `getSession()` only — it is
/// cookie-only *by construction*, and the server says so in as many words:
/// "a token transport carries no `mfaVerifiedAt` and cannot acquire one, so the
/// boundary is structural, not a softenable runtime check"
/// (`api-handler.ts:530-537`). A native Bearer client therefore **cannot**
/// satisfy step-up at all today.
///
/// So the honest iOS behaviour is not a retry loop and not a Safari hand-off:
/// it is to name the wall. The user is told the password change needs the web
/// app *because* their account has 2FA on — which is also the only place iOS
/// can currently learn that 2FA is on at all (see the screen's note).
///
/// **Detection rule** mirrors the web helper verbatim
/// (`totp-card.tsx:47-65` / `security-keys-card.tsx:44-61`): status **401**
/// AND `meta.errorCode` present AND prefixed `auth.stepup`. The prefix (not
/// equality) is deliberate — it covers `auth.stepup.required` and
/// `auth.stepup.mfa_not_enrolled` and any later sibling without a client change.
public enum SecurityStepUp {
    /// The wire prefix the server stamps into `meta.errorCode`.
    public static let errorCodePrefix = "auth.stepup"

    /// Whether `error` is a step-up rejection.
    ///
    /// `APIClient` surfaces `meta.errorCode` as `HLError.server(code:)`
    /// (`APIClient.swift:258, 768` — `envelope.meta?.errorCode ?? envelope.errorCode`),
    /// so the code is already where we need it.
    ///
    /// Both conditions are required. A bare `401` with **no** code is an
    /// ordinary auth failure — on this endpoint it is most likely
    /// "Current password is incorrect", which the server also returns as 401
    /// (`src/app/api/auth/password/route.ts`). Treating a code-less 401 as
    /// step-up would tell a user with a typo'd password that they need to sign
    /// in on the web — precisely the wrong instruction.
    /// The one sibling code that means something *different* to the user: the
    /// elevation was fine, the account simply has no second factor to be fresh
    /// about (`api-handler.ts:848` — the Bearer path holds the cookie path's
    /// `requireFreshMfa` line rather than becoming the softer route).
    public static let mfaNotEnrolledCode = "auth.stepup.mfa_not_enrolled"

    public static func isRequired(_ error: HLError) -> Bool {
        guard case let .server(status, code, _) = error else { return false }
        guard status == 401, let code else { return false }
        return code.hasPrefix(errorCodePrefix)
    }

    /// Whether `error` is the "this account has no second factor enrolled"
    /// variant. Checked **before** ``isRequired(_:)`` (which matches it too, by
    /// prefix) because the remedy differs: re-verifying cannot help, enrolling
    /// can.
    public static func isMfaNotEnrolled(_ error: HLError) -> Bool {
        guard case let .server(status, code, _) = error else { return false }
        return status == 401 && code == mfaNotEnrolledCode
    }

    /// Whether a **failed** management call spent the elevation server-side.
    ///
    /// The server validates an elevation *without* consuming it and claims it
    /// only when it is about to act — `requireMfaManagementAuth` returns a
    /// `commitElevation` closure (`src/lib/api-handler.ts:851-866`) that every
    /// gated route calls **after** its own cheap checks:
    /// `…/mfa/disable/route.ts:84-87` ("a wrong code or a 429 above costs the
    /// caller nothing"), `…/recovery-codes/regenerate/route.ts:48` (after the
    /// 409 + 429), `…/webauthn/[id]/route.ts:53, 88` (after the 422 / 404),
    /// `…/totp/setup/route.ts:61`, `…/totp/confirm/route.ts:109`.
    ///
    /// So exactly one failure class burns the proof: a rejection at the gate
    /// itself, which arrives as the uniform `auth.stepup.*` 401. Everything else
    /// — 429, 422, 404, 409, a wrong TOTP/recovery code, a transport error —
    /// leaves it unspent, and the client MUST keep it. Re-minting instead would
    /// spend one of only **five** per-account mints per 15 minutes
    /// (`src/app/api/auth/step-up/route.ts:63-65`), so a user who mistypes a
    /// disable code twice could lock themselves out of their own teardown.
    public static func consumesElevation(_ error: Error) -> Bool {
        guard let hl = error as? HLError else { return false }
        return isRequired(hl)
    }
}

// MARK: - The elevation-accepting operations

/// The management operations an elevation reaches, and which of them the server
/// additionally gates on a **fresh second factor**.
///
/// Single-sourced here so the arm picker cannot drift from the server: a route
/// marked `requiresFreshFactor` must never be offered the password arm, because
/// a password-proved elevation is refused *at the gate* — and a gate refusal is
/// the one failure class that does burn the proof (see
/// ``SecurityStepUp/consumesElevation(_:)``).
///
/// **Verified against the server, not against prose.** The fresh-factor flag is
/// exactly `requireMfaManagementAuth({ freshFactor: true })` at the route:
/// `…/mfa/disable/route.ts:41`, `…/mfa/recovery-codes/regenerate/route.ts:27`,
/// and the **DELETE** half of `…/mfa/webauthn/[id]/route.ts:73`. The **PATCH**
/// (rename) half at `…/webauthn/[id]/route.ts:31` calls
/// `requireMfaManagementAuth()` with no options and is therefore NOT a
/// fresh-factor route — unchanged between v1.34.2 and v1.34.3. Three fresh
/// routes, not four; see the CU-22 report.
///
/// `webauthn/register/options` + `/verify` are absent because the native client
/// has no security-key registration ceremony to drive them (see
/// `TwoFactorManagementScreen`'s honest note) — they were removed rather than
/// left as unreachable repository methods.
public enum MfaManagementOperation: String, Sendable, Equatable, CaseIterable {
    case totpSetup
    case totpConfirm
    case totpDisable
    case recoveryRegenerate
    case securityKeyRename
    case securityKeyRemove

    public var requiresFreshFactor: Bool {
        switch self {
        case .totpDisable, .recoveryRegenerate, .securityKeyRemove: true
        case .totpSetup, .totpConfirm, .securityKeyRename: false
        }
    }

    /// The mint methods this operation accepts. Reads as the contract does:
    /// password is refused exactly where a fresh second factor is demanded.
    public var acceptedMethods: [StepUpMethod] {
        StepUpMethod.allCases.filter { !requiresFreshFactor || $0.satisfiesFreshFactor }
    }
}

// MARK: - Native 2FA management (#57 — step-up elevation contract)

//
// Verified against the server v1.32.9 (`src/app/api/auth/step-up/*`,
// `src/app/api/auth/me/mfa/*`, `src/lib/validations/step-up.ts`,
// `src/lib/validations/mfa.ts`, `docs/api/openapi.yaml:1604-1868`) on 2026-07-24.
// The whole surface is reachable from a Bearer client because every MFA-
// management MUTATION now accepts a single-use step-up **elevation** presented
// in the `X-Step-Up` header alongside `Authorization: Bearer` — the mechanism
// the earlier "web only" doc comments predate.

/// The wire header carrying a single-use step-up elevation on the Bearer path.
/// Server constant `STEP_UP_ELEVATION_HEADER = "x-step-up"` (`api-handler.ts`);
/// HTTP header names are case-insensitive so the canonical `X-Step-Up` casing
/// here matches.
public enum SecurityHTTPHeader {
    public static let stepUp = "X-Step-Up"
}

/// A re-proved factor, discriminated exactly as the server's `stepUpMintSchema`.
///
/// The choice is an **authorisation** input, not a preference: only `totp`,
/// `webauthn`, and `passkey` satisfy the fresh-factor routes (disable,
/// recovery-code rotation, security-key removal). A `password` elevation reaches
/// only what a plain cookie session reaches — mirroring the web, where a
/// password login never stamps a session second-factor-verified. `iOS` picks the
/// ceremony **up front** on `satisfiesFreshFactor` so it never spends a proof on
/// a route that will reject it (a rejected fresh-factor route still consumes the
/// elevation server-side — `step-up.ts:245ff`).
public enum StepUpMethod: String, Sendable, Equatable, CaseIterable {
    case password
    case totp
    case webauthn
    case passkey

    /// Mirrors the server's `isFreshFactorMethod` / `FRESH_FACTOR_METHODS`: every
    /// method except `password` satisfies the destructive routes.
    public var satisfiesFreshFactor: Bool {
        self != .password
    }
}

/// Which assertion ceremony to begin at `POST /api/auth/step-up/options`.
/// `passkey` asserts against the account's PRIMARY passkeys; `webauthn` against
/// its registered SECOND-FACTOR security keys.
public enum StepUpCeremony: String, Sendable, Equatable {
    case passkey
    case webauthn

    /// The `StepUpMethod` an assertion of this ceremony proves at the mint.
    public var mintMethod: StepUpMethod {
        switch self {
        case .passkey: .passkey
        case .webauthn: .webauthn
        }
    }
}

// MARK: Step-up — request bodies

/// `POST /api/auth/step-up/options` body: `{ method: "passkey" | "webauthn" }`.
public struct StepUpOptionsRequestBody: Encodable, Sendable, Equatable {
    public let method: String
    public init(ceremony: StepUpCeremony) {
        method = ceremony.rawValue
    }
}

/// A SimpleWebAuthn **assertion** payload, camelCase on the wire — the exact
/// envelope shape the server's `webauthnCredentialSchema` pins. Built from a
/// ``PasskeyAssertion`` at the call site.
public struct WebAuthnAssertionCredential: Encodable, Sendable, Equatable {
    public struct Response: Encodable, Sendable, Equatable {
        public let clientDataJSON: String
        public let authenticatorData: String
        public let signature: String
        public let userHandle: String?
        public init(clientDataJSON: String, authenticatorData: String, signature: String, userHandle: String?) {
            self.clientDataJSON = clientDataJSON
            self.authenticatorData = authenticatorData
            self.signature = signature
            self.userHandle = userHandle
        }
    }

    public let id: String
    public let rawId: String
    public let type: String
    public let response: Response

    public init(id: String, rawId: String, response: Response) {
        self.id = id
        self.rawId = rawId
        type = "public-key"
        self.response = response
    }
}

/// `POST /api/auth/step-up` body — the discriminated union the server parses.
/// Encodes `method` plus exactly the arm's fields, so a body test can pin the
/// wire shape against `stepUpMintSchema`.
public enum StepUpMintBody: Encodable, Sendable {
    case password(String)
    case totp(String)
    case webauthn(challengeId: String, credential: WebAuthnAssertionCredential)
    case passkey(challengeId: String, credential: WebAuthnAssertionCredential)

    private enum CodingKeys: String, CodingKey {
        case method, password, code, challengeId, credential
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .password(password):
            try c.encode(StepUpMethod.password.rawValue, forKey: .method)
            try c.encode(password, forKey: .password)
        case let .totp(code):
            try c.encode(StepUpMethod.totp.rawValue, forKey: .method)
            try c.encode(code, forKey: .code)
        case let .webauthn(challengeId, credential):
            try c.encode(StepUpMethod.webauthn.rawValue, forKey: .method)
            try c.encode(challengeId, forKey: .challengeId)
            try c.encode(credential, forKey: .credential)
        case let .passkey(challengeId, credential):
            try c.encode(StepUpMethod.passkey.rawValue, forKey: .method)
            try c.encode(challengeId, forKey: .challengeId)
            try c.encode(credential, forKey: .credential)
        }
    }
}

// MARK: Step-up — response shapes

/// `POST /api/auth/step-up/options` → SimpleWebAuthn assertion options + the
/// server-issued challenge id. The server types `options` loosely; we decode the
/// same `{ challenge, rpId, allowCredentials }` subset the login/verify paths use.
public struct StepUpOptionsResponse: Decodable, Sendable, Equatable {
    public struct Options: Decodable, Sendable, Equatable {
        public struct Descriptor: Decodable, Sendable, Equatable {
            public let id: String
            public let type: String
        }

        public let challenge: String
        public let rpId: String
        public let allowCredentials: [Descriptor]?
    }

    public let challengeId: String
    public let options: Options
}

/// `POST /api/auth/step-up` → the minted elevation. `elevation` is the raw
/// `hle_…` secret, returned exactly once; it is held in memory only and NEVER
/// logged or persisted (`LogSanitizer` also carries an `hle_` rule as
/// defence-in-depth).
public struct StepUpMintResponse: Decodable, Sendable, Equatable {
    public let elevation: String
    public let expiresAt: String
    public let expiresInSeconds: Int
    public let method: String
    public let satisfiesFreshFactor: Bool
}

// MARK: MFA status (`GET /api/auth/me/mfa`)

/// `GET /api/auth/me/mfa` — plain-Bearer status read (no elevation). Metadata
/// only: no secret, no code, no public key. The single source of truth for the
/// Settings → Security 2FA card's status (verified: `/api/auth/me` does NOT
/// expose `totpConfirmedAt` in its payload — the only `totpConfirmedAt`
/// reference there feeds `syncMfaEnrollCookie`, an internal cookie sync).
public struct MfaStatus: Decodable, Sendable, Equatable {
    public struct Totp: Decodable, Sendable, Equatable {
        public let enabled: Bool
    }

    /// A registered second-factor security key. Dates decode as raw ISO strings
    /// for tolerance (no dependency on the decoder's date strategy); the UI
    /// parses them leniently and hides the date on a parse miss.
    public struct SecurityKey: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let createdAt: String?
        public let lastUsedAt: String?

        public init(id: String, name: String, createdAt: String? = nil, lastUsedAt: String? = nil) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
        }
    }

    public let totp: Totp
    public let recoveryCodesRemaining: Int
    public let webauthn: [SecurityKey]
    public let passkeyNudgeDismissed: Bool

    public init(totp: Totp, recoveryCodesRemaining: Int, webauthn: [SecurityKey], passkeyNudgeDismissed: Bool) {
        self.totp = totp
        self.recoveryCodesRemaining = recoveryCodesRemaining
        self.webauthn = webauthn
        self.passkeyNudgeDismissed = passkeyNudgeDismissed
    }
}

// MARK: TOTP enrolment (`…/mfa/totp/setup`, `…/mfa/totp/confirm`)

/// `POST …/mfa/totp/setup` → the pending secret. `totpSecret` (Base32) and
/// `otpauthUri` are sensitive: shown once for QR/manual entry, held in the
/// enrolment sheet's own state, never logged or persisted.
public struct TotpSetupResponse: Decodable, Sendable, Equatable {
    public let otpauthUri: String
    public let totpSecret: String
}

/// `POST …/mfa/totp/confirm` body: `{ code }` (6-digit). The server trims +
/// regex-validates; we clamp to digits at the field so an obvious typo never
/// spends a rate-limited attempt.
public struct TotpConfirmRequestBody: Encodable, Sendable, Equatable {
    public let code: String
    public init(code: String) {
        self.code = code
    }
}

/// `POST …/mfa/totp/confirm` → activation + the recovery-code batch, delivered
/// **exactly once**. Codes are shown once (copy/share), then only
/// `recoveryCodesRemaining` is ever surfaced again.
public struct TotpConfirmResponse: Decodable, Sendable, Equatable {
    public let enabled: Bool
    public let recoveryCodes: [String]
    public let recoveryCodesRemaining: Int
}

// MARK: Disable + recovery-code rotation (fresh-factor routes)

/// `POST …/mfa/disable` body: a current TOTP or recovery code proving live
/// possession at the destructive moment, on top of the fresh-factor elevation.
public struct MfaDisableRequestBody: Encodable, Sendable, Equatable {
    /// Second-factor material the disable proves possession of.
    public enum Method: String, Sendable, Equatable {
        case totp
        case recovery
    }

    public let code: String
    public let method: String

    public init(code: String, method: Method) {
        self.code = code
        self.method = method.rawValue
    }
}

/// `POST …/mfa/recovery-codes/regenerate` → the fresh batch, delivered once,
/// invalidating the entire prior set.
public struct RecoveryRegenerateResponse: Decodable, Sendable, Equatable {
    public let recoveryCodes: [String]
    public let recoveryCodesRemaining: Int
}

// MARK: Security keys (WebAuthn second factor)

// `POST …/mfa/webauthn/register/options` + `/verify` are deliberately ABSENT.
//
// They are elevation-gated like the rest of the surface, but the ceremony
// between them needs an `ASAuthorizationSecurityKeyPublicKeyCredentialProvider`
// flow that `PasskeyService` does not implement (it is platform-credential
// only). Wiring the two calls without that ceremony would leave a repository
// method no caller can reach, so CU-22 removed them rather than keeping dead
// code behind an honest note. The 2FA hub says so on the surface
// (`settings.security.twoFactor.securityKeys.addOnWeb`); registering a key
// stays a web action, while renaming and removing one are fully native.
//
// Note for whoever revisits this: `PasskeyServiceProtocol.register(...)` is NOT
// the ceremony that would be needed here — that is the *platform* provider used
// for primary passkeys. A security key needs the security-key provider and a
// separate delegate branch, so reviving one does not revive the other.
