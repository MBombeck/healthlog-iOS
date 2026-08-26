import Foundation

/// Owns the account-security verbs that a **Bearer** client can actually reach:
///
/// - `POST /api/auth/password` — change password.
///
/// **Why this repo is so small.** The web security hub also drives TOTP
/// enrolment/disable, recovery-code regeneration and WebAuthn security keys.
/// Every one of those routes is gated on `requireCookieAuth` or `requireFreshMfa`,
/// both of which resolve the caller via `getSession()` and never fall through to
/// the `Authorization: Bearer` branch (`src/lib/api-handler.ts:487-500, 543-583`).
/// The native login path issues a token bundle and **no session cookie** — the
/// two branches in `finishLogin` are mutually exclusive
/// (`src/lib/auth/login-response.ts:66-116`). So those endpoints are not
/// "unimplemented on iOS", they are *unreachable* from iOS until the server
/// grows a Bearer-satisfiable step-up. They are deliberately absent here rather
/// than present-and-always-401.
///
/// **Idempotency.** `POST` carries the standard header key via
/// `HTTPMethod.requiresIdempotency`. **No Outbox `Kind` is wired**, and that is
/// intentional: a password change must never be replayed from a queue minutes or
/// hours later against a credential the user may since have changed elsewhere,
/// and the endpoint is rate-limited to 5 attempts / 15 min per user. A failed
/// attempt surfaces as an error the user retries deliberately — same stance the
/// `PasskeyRepository` doc takes on revoke.
public actor AccountSecurityRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Changes the account password.
    ///
    /// `maxRetries: 0` — this is an interactive, rate-limited, non-idempotent-
    /// in-effect credential mutation (the server destroys every other session on
    /// success, `src/app/api/auth/password/route.ts:108-114`). A transparent
    /// retry could burn a second of the five allowed attempts against a
    /// request that may well have succeeded.
    ///
    /// - Throws: `HLError.server` carrying the envelope message verbatim. The
    ///   caller distinguishes a step-up rejection via ``SecurityStepUp/isRequired(_:)``;
    ///   everything else (wrong current password, too weak, breached, rate
    ///   limited) is server prose meant to be shown as-is.
    public func changePassword(
        current: String,
        new: String,
        confirm: String
    ) async throws {
        let body = ChangePasswordBody(
            currentPassword: current,
            newPassword: new,
            confirmPassword: confirm
        )
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/auth/password",
            body: body,
            maxRetries: 0,
            failFast: true
        )
        try await api.sendVoid(req)
    }

    // MARK: - Native 2FA management (#57 — step-up elevation contract)

    //
    // Verified against server v1.32.9 on 2026-07-24, re-audited against v1.34.3
    // on 2026-07-31 (CU-22): contract unchanged. Every mutation below carries a
    // single-use step-up **elevation** in the `X-Step-Up` header — an explicit
    // per-call parameter, never global `APIClient` state, so an elevation can
    // never leak onto an unrelated request. All are interactive, rate-limited,
    // credential-adjacent calls → `maxRetries: 0, failFast: true`.
    //
    // Three of these are fresh-factor routes (disable, recovery-code
    // regenerate, security-key DELETE) — see ``MfaManagementOperation``.

    /// Reads the running server's version so the caller can gate the 2FA-
    /// management surface behind ≥ v1.32.3 (older self-hosted instances keep the
    /// honest "manage on the web" card). Reuses the existing `/api/version`
    /// probe (`APIClient+ServerVersion`).
    public func serverVersion() async throws -> ServerVersionInfo {
        try await api.fetchServerVersion()
    }

    /// `GET /api/auth/me/mfa` — the plain-Bearer status read (no elevation).
    public func mfaStatus() async throws -> MfaStatus {
        let req: APIRequest<MfaStatus> = APIRequest(
            method: .get,
            path: "/api/auth/me/mfa",
            maxRetries: 0,
            failFast: true
        )
        return try await api.send(req)
    }

    // MARK: Step-up ceremony

    /// `POST /api/auth/step-up/options` — begin an assertion ceremony. A **409**
    /// (no credential of that kind) is the honest discovery path; the caller
    /// offers another arm. Bearer-only.
    public func stepUpOptions(_ ceremony: StepUpCeremony) async throws -> StepUpOptionsResponse {
        let req: APIRequest<StepUpOptionsResponse> = try .post(
            "/api/auth/step-up/options",
            body: StepUpOptionsRequestBody(ceremony: ceremony),
            maxRetries: 0,
            failFast: true
        )
        return try await api.send(req)
    }

    /// `POST /api/auth/step-up` — re-prove a factor and mint a single-use,
    /// token-bound elevation (5-min TTL). Every failure class is a generic 401.
    public func stepUpMint(_ body: StepUpMintBody) async throws -> StepUpMintResponse {
        let req: APIRequest<StepUpMintResponse> = try .post(
            "/api/auth/step-up",
            body: body,
            maxRetries: 0,
            failFast: true
        )
        return try await api.send(req)
    }

    // MARK: TOTP

    /// `POST …/mfa/totp/setup` (elevation gated; password elevation suffices).
    public func totpSetup(elevation: String) async throws -> TotpSetupResponse {
        let req: APIRequest<TotpSetupResponse> = APIRequest(
            method: .post,
            path: "/api/auth/me/mfa/totp/setup",
            extraHeaders: [SecurityHTTPHeader.stepUp: elevation],
            maxRetries: 0,
            failFast: true
        )
        return try await api.send(req)
    }

    /// `POST …/mfa/totp/confirm` (elevation gated). Returns the recovery-code
    /// batch **once**.
    public func totpConfirm(code: String, elevation: String) async throws -> TotpConfirmResponse {
        let data = try JSONEncoder.hlDefault.encode(TotpConfirmRequestBody(code: code))
        let req: APIRequest<TotpConfirmResponse> = APIRequest(
            method: .post,
            path: "/api/auth/me/mfa/totp/confirm",
            body: data,
            extraHeaders: [SecurityHTTPHeader.stepUp: elevation],
            maxRetries: 0,
            failFast: true
        )
        return try await api.send(req)
    }

    /// `POST …/mfa/disable` — **fresh-factor** route. The elevation MUST have
    /// been minted from a totp/webauthn/passkey proof (password is rejected); the
    /// caller picks the ceremony up front on `satisfiesFreshFactor`.
    public func disableTotp(code: String, method: MfaDisableRequestBody.Method, elevation: String) async throws {
        let data = try JSONEncoder.hlDefault.encode(MfaDisableRequestBody(code: code, method: method))
        let req: APIRequest<EmptyPayload> = APIRequest(
            method: .post,
            path: "/api/auth/me/mfa/disable",
            body: data,
            extraHeaders: [SecurityHTTPHeader.stepUp: elevation],
            maxRetries: 0,
            failFast: true
        )
        try await api.sendVoid(req)
    }

    /// `POST …/mfa/recovery-codes/regenerate` — **fresh-factor** route. New batch
    /// delivered once, prior set invalidated.
    public func regenerateRecoveryCodes(elevation: String) async throws -> RecoveryRegenerateResponse {
        let req: APIRequest<RecoveryRegenerateResponse> = APIRequest(
            method: .post,
            path: "/api/auth/me/mfa/recovery-codes/regenerate",
            extraHeaders: [SecurityHTTPHeader.stepUp: elevation],
            maxRetries: 0,
            failFast: true
        )
        return try await api.send(req)
    }

    // MARK: Security keys (WebAuthn)

    // Registering a NEW key (`…/webauthn/register/options` + `/verify`) has no
    // native ceremony and therefore no repository method — see the note in
    // `AccountSecurityBodies.swift`.

    /// `PATCH …/mfa/webauthn/{id}` — rename. Elevation gated but **not** a
    /// fresh-factor route: the server calls `requireMfaManagementAuth()` with no
    /// options here (`src/app/api/auth/me/mfa/webauthn/[id]/route.ts:31`), in
    /// contrast to the DELETE half at `:73`. A password-proved elevation is
    /// accepted. The name is normalised to the server's `webauthnKeyNameSchema`
    /// (trim + 64) so an over-long / whitespace entry is corrected here, not
    /// bounced as a 422.
    public func renameSecurityKey(id: String, name: String, elevation: String) async throws {
        let data = try JSONEncoder.hlDefault.encode(PasskeyRenameBody(name: WebAuthnKeyName.normalized(name)))
        let req: APIRequest<EmptyPayload> = APIRequest(
            method: .patch,
            path: "/api/auth/me/mfa/webauthn/\(id)",
            body: data,
            extraHeaders: [SecurityHTTPHeader.stepUp: elevation],
            maxRetries: 0,
            failFast: true
        )
        try await api.sendVoid(req)
    }

    /// `DELETE …/mfa/webauthn/{id}` — **fresh-factor** route
    /// (`…/webauthn/[id]/route.ts:73`, `requireMfaManagementAuth({ freshFactor: true })`).
    public func deleteSecurityKey(id: String, elevation: String) async throws {
        let req: APIRequest<EmptyPayload> = APIRequest(
            method: .delete,
            path: "/api/auth/me/mfa/webauthn/\(id)",
            extraHeaders: [SecurityHTTPHeader.stepUp: elevation],
            maxRetries: 0,
            failFast: true
        )
        try await api.sendVoid(req)
    }
}
