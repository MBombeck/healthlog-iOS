import Foundation

/// #37 / v1.23.0 — the second factors the server can challenge a password
/// login with. Decoded leniently from the login `meta.methods` list; unknown
/// strings are dropped at the call site so a future server-added method never
/// breaks the decode.
public enum MfaMethod: String, Sendable, Equatable, CaseIterable {
    case totp
    case recovery
    case webauthn
}

/// #37 — the outcome of `POST /api/auth/login`. The 200 body is
/// `anyOf [LoginResponse, MfaRequiredResponse]`: either a full token bundle
/// (``session``) or a "password accepted, second factor required" challenge
/// (``mfaRequired``). Before #37 the MFA branch fell through to a raw decode
/// and threw a misleading "no Bearer token" error, hard-locking every
/// MFA-enrolled user out of the native app.
public enum LoginOutcome: Sendable {
    case session(AuthSession)
    case mfaRequired(ticket: String, methods: [MfaMethod])
}

public actor AuthService {
    // 24-01 — internal, not `private`: Swift's `private` is file-scoped and the
    // blanked-identity repair lives in `AuthService+IdentityRecovery.swift`.
    // Still actor-isolated; no caller reaches either without awaiting the actor.
    let api: APIClientProtocol
    let keychain: KeychainStoring
    private let passkey: PasskeyServiceProtocol

    /// Monotonic lease for suspended credential writes. A refresh captures the
    /// current value before its network hop and may persist only if no confirmed
    /// account deletion advanced the boundary in the meantime.
    private var credentialPersistenceGeneration: UInt64 = 0

    /// 13-02 — the web-login route verdict, remembered per host so the auth
    /// step probes on step transitions rather than on renders. Keyed on the
    /// host it was measured against: re-targeting the app at another server
    /// re-asks instead of reusing a verdict about somebody else's instance.
    var cachedWebLoginRouteStatus: (host: String?, status: WebLoginRouteStatus)?

    public init(api: APIClientProtocol, keychain: KeychainStoring, passkey: PasskeyServiceProtocol) {
        self.api = api
        self.keychain = keychain
        self.passkey = passkey
    }

    public var isAuthenticated: Bool {
        keychain.getString(forKey: KeychainKey.authToken) != nil
    }

    // MARK: - Email/Password

    public func login(email: String, password: String) async throws -> LoginOutcome {
        struct Body: Encodable {
            let email: String
            let password: String
        }
        // Server liefert bei `X-Client-Type: native` (von APIClient gesetzt)
        // `{ user, token, tokenExpiresAt }` zurück.
        // `maxRetries: 0` — auth endpoints rate-limit aggressively (5/15min);
        // a user-action must equal one network call. #96 — `failFast: true` →
        // APIClient's no-wait-for-connectivity auth session, so a no-network
        // sign-in fails the door immediately.
        let req: APIRequest<NativeLoginResponse> = try .post(
            "/api/auth/login",
            body: Body(email: email, password: password),
            maxRetries: 0,
            failFast: true
        )
        // #37 — read the envelope's `meta` (not just `data`). The 200 is
        // `anyOf [LoginResponse, MfaRequiredResponse]`; an MFA-enrolled user's
        // password login returns `data: null` + `meta.mfaRequired: true`. The
        // mfaTicket is **sensitive** — it is held transiently by the caller and
        // never logged here.
        let (payload, meta) = try await api.sendEnvelope(req)
        if let meta, meta.mfaRequired == true {
            // L1 — a challenge MUST carry its ticket; a `mfaRequired:true` with a
            // missing `mfaTicket` is a malformed server response. Surface it as an
            // explicit error instead of falling through to the old "no Bearer
            // token" message (which misleads the user into a credentials retry).
            guard let ticket = meta.mfaTicket else {
                throw HLError.unknown("Malformed MFA challenge: server requested a second factor without a ticket.")
            }
            let methods = (meta.methods ?? []).compactMap(MfaMethod.init(rawValue:))
            return .mfaRequired(ticket: ticket, methods: methods)
        }
        guard let payload else {
            throw HLError.unknown("Server hat keinen Bearer-Token zurückgegeben (X-Client-Type: native fehlt?)")
        }
        let session = try payload.asAuthSession()
        try persist(session)
        return .session(session)
    }

    /// #37 — completes a TOTP / recovery-code second-factor challenge against
    /// `POST /api/auth/mfa/verify`. The response `data` is the SAME
    /// `AccessRefreshBundle` the password path issues, so it decodes through the
    /// existing ``NativeLoginResponse`` DTO unchanged → persists the session and
    /// returns it, exactly like ``login`` does on the no-MFA path.
    ///
    /// `maxRetries: 0` + `failFast: true` — same rate-limit / no-wait-for-
    /// connectivity discipline as `login`. `rememberDevice` is web-cookie-only
    /// trust the native Bearer client can't persist, so it is **omitted** when
    /// `false` (the default) rather than promising a no-op device-trust.
    /// The `code` + `ticket` are sensitive — never logged.
    public func verifyMFA(
        ticket: String,
        method: MfaMethod,
        code: String,
        rememberDevice: Bool = false
    ) async throws -> AuthSession {
        struct Body: Encodable {
            let mfaTicket: String
            let method: String
            let code: String
            let rememberDevice: Bool?
        }
        // Only `totp` / `recovery` reach this endpoint; webauthn goes through
        // `mfaWebauthnVerify`. Map anything unexpected to `totp` defensively.
        let serverMethod = method == .recovery ? "recovery" : "totp"
        let req: APIRequest<NativeLoginResponse> = try .post(
            "/api/auth/mfa/verify",
            body: Body(
                mfaTicket: ticket,
                method: serverMethod,
                code: code,
                rememberDevice: rememberDevice ? true : nil
            ),
            maxRetries: 0,
            failFast: true
        )
        let response = try await api.send(req)
        let session = try response.asAuthSession()
        try persist(session)
        return session
    }

    /// #49 / v1.30.11 — exchanges a native OIDC one-time handoff code (from the
    /// `healthlog://oidc-callback?code=hlh_…` redirect) for the STANDARD native
    /// token bundle at `POST /api/auth/oidc/native/token`. The body carries the
    /// opaque `code` + the app's in-memory PKCE `codeVerifier`; the exchange also
    /// pins `X-Client-Type: native` explicitly (the server requires the native
    /// transport, and it makes the header contract-visible even though the client
    /// sets it globally). The `data` is the SAME `AccessRefreshBundle` password /
    /// passkey login issues, so it decodes through the existing
    /// ``NativeLoginResponse`` DTO unchanged → persists the session and returns it.
    ///
    /// **Exchange exactly once.** `maxRetries: 0` keeps this to a single network
    /// call — a replayed/consumed code revokes the freshly-issued pair server-side
    /// (interception containment), so any failure (single generic 401) is a login
    /// failure the caller surfaces, never a retry. `failFast: true` matches the
    /// other interactive auth legs. The `code` + `codeVerifier` + tokens are
    /// sensitive — never logged.
    public func oidcNativeTokenExchange(code: String, codeVerifier: String) async throws -> AuthSession {
        struct Body: Encodable {
            let code: String
            let codeVerifier: String
        }
        let bodyData = try JSONEncoder.hlDefault.encode(Body(code: code, codeVerifier: codeVerifier))
        let req = APIRequest<NativeLoginResponse>(
            method: .post,
            path: "/api/auth/oidc/native/token",
            body: bodyData,
            extraHeaders: ["X-Client-Type": "native"],
            maxRetries: 0,
            failFast: true
        )
        let response = try await api.send(req)
        let session = try response.asAuthSession()
        try persist(session)
        return session
    }

    /// #37 — completes a WebAuthn (security-key / platform-passkey) second
    /// factor. Two legs, both presenting the login `mfaTicket`:
    /// 1. `POST /api/auth/mfa/webauthn/verify/options` → assertion options +
    ///    `challengeId`.
    /// 2. `passkey.assert(...)` (REUSED verbatim — the exact assertion ceremony
    ///    the passkey login already runs, zero `PasskeyService` change).
    /// 3. `POST /api/auth/mfa/webauthn/verify` → the SAME `AccessRefreshBundle`,
    ///    decoded via the existing ``NativeLoginResponse`` DTO.
    ///
    /// WebAuthn is RP-bound to the app's associated domain, so the **caller**
    /// gates this on the default host + `methods.contains(.webauthn)` (same gate
    /// as the passkey login CTA). TOTP/recovery is the universal fallback.
    /// - Parameter rememberDevice: parity item 2.4. The security-key verify
    ///   route accepts the same trusted-device opt-in as the TOTP route
    ///   (`src/app/api/auth/mfa/webauthn/verify/route.ts:64, 136-137`), so the
    ///   toggle on the challenge sheet applies to both factors rather than
    ///   silently doing nothing when the user completes with a key.
    public func mfaWebauthnVerify(
        ticket: String,
        presentationAnchor: ASPresentationAnchorProvider,
        rememberDevice: Bool = false
    ) async throws -> AuthSession {
        struct OptionsBody: Encodable {
            let mfaTicket: String
        }
        let optsReq: APIRequest<MfaWebauthnOptionsResponse> = try .post(
            "/api/auth/mfa/webauthn/verify/options",
            body: OptionsBody(mfaTicket: ticket),
            maxRetries: 0,
            failFast: true
        )
        let optsResponse = try await Self.withTimeout(seconds: 12) {
            try await self.api.send(optsReq)
        }

        let assertion = try await passkey.assert(
            challenge: optsResponse.options.challenge,
            rpId: optsResponse.options.rpId,
            allowCredentialIDs: optsResponse.options.allowCredentials?.map(\.id) ?? [],
            anchor: presentationAnchor
        )

        struct VerifyBody: Encodable {
            let mfaTicket: String
            let challengeId: String
            let credential: WebAuthnAssertionDTO
            /// Omitted (rather than sent as `false`) when the user did not opt
            /// in, matching the TOTP body's convention above so the wire shape
            /// stays identical to what the server's zod schema expects as a
            /// default.
            let rememberDevice: Bool?
        }
        let body = VerifyBody(
            mfaTicket: ticket,
            challengeId: optsResponse.challengeId,
            credential: WebAuthnAssertionDTO(
                id: assertion.credentialID,
                rawId: assertion.credentialID,
                type: "public-key",
                response: .init(
                    clientDataJSON: assertion.clientDataJSON,
                    authenticatorData: assertion.authenticatorData,
                    signature: assertion.signature,
                    userHandle: assertion.userHandle
                )
            ),
            rememberDevice: rememberDevice ? true : nil
        )
        let verifyReq: APIRequest<NativeLoginResponse> = try .post(
            "/api/auth/mfa/webauthn/verify",
            body: body,
            maxRetries: 0,
            failFast: true
        )
        let response = try await Self.withTimeout(seconds: 12) {
            try await self.api.send(verifyReq)
        }
        let session = try response.asAuthSession()
        try persist(session)
        return session
    }

    /// Two-stage native registration per `05-auth-flows.md §3` /  `M2-A11 §6.1`:
    /// server's `POST /api/auth/register` returns `201` with `{ user }` but no
    /// token (web is cookie-based), so iOS chains a `POST /api/auth/login`
    /// against the same credentials for the Bearer token. Both rate-limited
    /// (5/15min/IP) → `maxRetries: 0` (one user-action == one network call).
    /// b182 W-B182-INVITE (GH #16) — `inviteToken` (server invite `hlv_<64 hex>`)
    /// is threaded into the register body. The server's `registerSchema` accepts
    /// it as an optional field; on a closed-registration instance it is the door
    /// key (missing/invalid → `403`), on an open instance it is consumed for
    /// ledger correctness. Omitted from the JSON when `nil` (synthesized
    /// `Encodable` uses `encodeIfPresent` for optionals). The token is sensitive
    /// — it never appears in any log line on this path.
    public func register(
        email: String,
        username: String,
        password: String,
        timezone: String = TimeZone.current.identifier,
        inviteToken: String? = nil
    ) async throws -> AuthSession {
        struct RegisterBody: Encodable {
            let email: String
            let username: String
            let password: String
            let timezone: String
            let inviteToken: String?
        }
        let registerReq: APIRequest<EmptyPayload> = try .post(
            "/api/auth/register",
            body: RegisterBody(
                email: email,
                username: username,
                password: password,
                timezone: timezone,
                inviteToken: inviteToken
            ),
            maxRetries: 0,
            failFast: true // #96 — interactive auth door, fail fast on no connectivity.
        )
        try await api.sendVoid(registerReq)
        // Server returned 201 — chain login to get the Bearer token. A freshly
        // registered account cannot yet have a second factor enrolled (MFA setup
        // is a post-registration, cookie-only flow), so the chained login must
        // resolve to `.session`. If the server ever challenges here, treat it as
        // an error rather than silently dropping the new account into a dead end.
        switch try await login(email: email, password: password) {
        case let .session(session):
            return session
        case .mfaRequired:
            throw HLError.unknown("Unexpected MFA challenge on a freshly registered account.")
        }
    }

    /// Probe `GET /api/auth/registration-status` to check whether the
    /// currently-targeted server allows new registrations. Self-hosted
    /// instances frequently disable registration after bootstrapping; the
    /// onboarding UI hides the "Neues Konto" affordance accordingly.
    /// Un-authenticated route, safe to call before any login attempt.
    public func registrationEnabled() async -> Bool {
        struct Response: Decodable { let registrationEnabled: Bool }
        let req: APIRequest<Response> = APIRequest(
            method: .get,
            path: "/api/auth/registration-status",
            maxRetries: 0,
            failFast: true // #96 — onboarding pre-flight, fail fast on no connectivity.
        )
        do {
            let resp = try await api.send(req)
            return resp.registrationEnabled
        } catch {
            // On failure: assume enabled. The actual registration call will
            // surface the precise reason if disabled (409 with a clear message).
            return true
        }
    }

    /// parity 2.9 — probe `GET /api/auth/oidc/status` so the auth step renders
    /// only the doors this instance actually opens. Un-authenticated, pure env
    /// reads server-side ("nothing here can throw" — `oidc/status/route.ts`),
    /// safe to call before any login attempt.
    ///
    /// Before this, iOS rendered the SSO button unconditionally *and* always
    /// rendered password + passkey + register: an instance without an IdP
    /// showed a dead SSO button, and an `OIDC_ONLY` instance showed three CTAs
    /// the server refuses.
    ///
    /// Failure → ``OidcStatus/unknown`` (show everything), never a lockout.
    public func oidcStatus() async -> OidcStatus {
        struct Response: Decodable {
            let enabled: Bool
            let buttonLabel: String?
            let only: Bool
        }
        let req: APIRequest<Response> = APIRequest(
            method: .get,
            path: "/api/auth/oidc/status",
            maxRetries: 0,
            failFast: true // #96 — onboarding pre-flight, fail fast on no connectivity.
        )
        do {
            let resp = try await api.send(req)
            return OidcStatus(enabled: resp.enabled, buttonLabel: resp.buttonLabel, only: resp.only)
        } catch {
            return .unknown
        }
    }

    /// GDPR-style hard-delete: ruft `DELETE /api/settings/account` mit dem vom
    /// Server geforderten Confirm-Body (`{ confirm: "DELETE_ACCOUNT" }`) auf.
    /// Bei 2xx → kompletter Keychain-Wipe (Bearer + Refresh + Expiries +
    /// UserID + DeviceID), so dass kein Token-Reststand einen Re-Login mit
    /// derselben Device-Identität beeinflusst. Wirft bei jedem Server-Fehler
    /// (4xx/5xx) und lässt die Keychain dabei unangetastet — der Aufrufer
    /// (AuthStore) kann den Fehler dann an die UI durchreichen, ohne dass
    /// der User ungewollt ausgeloggt wird.
    ///
    /// `maxRetries: 0` — Account-Deletion ist NICHT idempotent aus Server-Sicht
    /// (zweite Anfrage 401't, weil der User gerade weg ist). Wir wollen genau
    /// einen Versuch.
    public func deleteAccount() async throws {
        struct ConfirmBody: Encodable {
            let confirm: String
        }
        // Server (`/src/app/api/settings/account/route.ts`) erwartet einen
        // Confirm-Body auch beim DELETE-Verb — der Wrapper `.delete(_:)` trägt
        // keinen Body, also bauen wir den `APIRequest` von Hand.
        let body = try JSONEncoder.hlDefault.encode(ConfirmBody(confirm: "DELETE_ACCOUNT"))
        let deleteReq = APIRequest<EmptyPayload>(
            method: .delete,
            path: "/api/settings/account",
            body: body,
            maxRetries: 0
        )
        let previousUserID = keychain.getString(forKey: KeychainKey.userID)
        try await api.sendVoid(deleteReq)
        invalidateAndWipeDeletedAccountCredentials()
        if let cleanup = onLogoutCleanup {
            await cleanup(previousUserID)
        }
    }

    /// Best-effort but fail-closed local Keychain teardown after the server has
    /// irreversibly accepted account deletion. Every targeted key is attempted
    /// even if one removal fails. If any targeted delete fails, a service-wide
    /// wipe is the recovery path: retaining a bearer, consent grant, or provider
    /// secret is worse than making the user re-enter the non-secret server URL.
    ///
    /// This helper deliberately does not throw. Once the server returned 2xx,
    /// `AuthStore` must still run the app-level cache/outbox cleanup and move to
    /// `.unauthenticated`; reporting a retry would be false because the account
    /// no longer exists.
    /// Shared synchronous account-boundary wipe used after both the native
    /// delete endpoint and a confirmed web/MFA deletion. Keeping the primitive
    /// synchronous lets `AuthStore` revalidate the probed session and perform
    /// the destructive keychain step without an actor hop that could admit a
    /// replacement account in between.
    private nonisolated static func wipeDeletedAccountKeychain(using keychain: KeychainStoring) {
        // Normal path: enumerate the account-bound keys explicitly so the
        // configured server URL survives and onboarding can return to the same
        // host. `removeAll()` is reserved for a targeted-removal failure.
        var keys = [
            KeychainKey.authToken,
            KeychainKey.refreshToken,
            KeychainKey.refreshTokenExpiresAt,
            KeychainKey.accessTokenExpiresAt,
            KeychainKey.userID,
            KeychainKey.userDisplayName,
            KeychainKey.deviceID,
            AIConsentStore.serverManagedScope,
            AIConsentStore.serverManagedDeclinedKey
        ]
        // Device-ID rotieren: ein neuer Login danach soll als "neues Gerät"
        // beim Server gelten, sonst könnte der Server-Side-Cleanup auf
        // alte Device-Rows referenzieren (auch wenn Cascade-Delete sie schon
        // abräumt — saubere Trennung zwischen den beiden Sessions).
        // v0.12 W1 (security finding W1-1, Apple 5.1.2(i)) — mirror the
        // AI-consent grant wipe here so the account-deletion direct keychain
        // teardown is self-sufficient even if the `performFullLocalLogout`
        // cascade is ever decoupled from this path. The per-provider
        // `ai-consent.<provider>` grant + the paired `ai-consent-declined.
        // <provider>` marker are the informed-consent record gating
        // off-device LLM transmission; they must not survive the account
        // they were granted under (shared-device inheritance leak).
        // Idempotent — over-removing absent keys is a no-op.
        for provider in AIProvider.allCases where provider != .unconfigured {
            keys.append(AIConsentStore.keyPrefix + provider.rawValue)
            keys.append(AIConsentStore.declinedKeyPrefix + provider.rawValue)
        }
        // v0.13 — mirror the BYO-key consent-grant wipe (`byo-consent.<provider>`)
        // so account deletion is self-sufficient. The client-side BYO path
        // transmits health data off-device, so its consent record must not
        // survive the deleted account.
        keys.append(KeychainKey.lastSessionUserID) // Build 273 (A2) — goes with the outbox
        for provider in BYOProviderID.allCases {
            keys.append(AIConsentStore.byoKeyPrefix + provider.rawValue)
            keys.append(BYOKeyStore.keyPrefix + provider.rawValue)
            keys.append(BYOKeyStore.modelPrefix + provider.rawValue)
            keys.append(BYOKeyStore.baseURLPrefix + provider.rawValue)
        }
        // v0.13 W2 — and wipe the BYO API **key bytes** themselves
        // (`byo.llm.key.<provider>` + model/baseURL overrides) so the secret
        // never survives the deleted account.
        var targetedRemovalFailed = false
        for key in keys {
            do {
                try keychain.remove(forKey: key)
            } catch {
                targetedRemovalFailed = true
            }
        }

        guard targetedRemovalFailed else { return }
        HLLog.security.error(
            "Account-deletion targeted Keychain wipe failed; attempting service-wide fail-closed wipe."
        )
        do {
            try keychain.removeAll()
        } catch {
            HLLog.security.error(
                "Account-deletion service-wide Keychain wipe failed; local credentials may remain on device: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
    }

    /// #37/#38 Privacy H3 (audit-v0162) — the tri-state outcome of probing
    /// whether the currently-persisted session's account still exists on the
    /// server. Used after an MFA-enrolled user was routed to *web* account
    /// deletion (the native Bearer session cannot satisfy the cookie-only fresh-
    /// MFA step-up): once the deletion completes on the web, the local device
    /// still holds full PHI until an incidental call happens to 401. The probe
    /// makes that detection deterministic on the next foreground.
    public enum AccountProbeOutcome: Sendable, Equatable {
        /// `GET /api/auth/me` answered 2xx — the account is still live (the user
        /// has not completed the web deletion, or cancelled). Do NOT wipe.
        case exists
        /// The account is gone: a 401/404 (or a locally-absent token) — the
        /// server no longer recognises this session. Run the full local wipe.
        case gone
        /// Network/offline/5xx — cannot tell. Leave the pending flag armed and
        /// re-probe on the next foreground.
        case inconclusive
    }

    /// #37/#38 Privacy H3 (audit-v0162) — probe `GET /api/auth/me` to decide
    /// whether the account behind the persisted token still exists.
    ///
    /// Routed through the fail-fast auth session (`failFast: true`,
    /// `maxRetries: 0`) so a no-connectivity probe returns `.inconclusive`
    /// immediately instead of parking on the patient outbox timeout. A 401/404 —
    /// or a session that self-heals via the refresh→logout bridge and ends up
    /// token-less — resolves to `.gone`; a merely-expired access token that the
    /// refresh path renews resolves to `.exists` (no false positive). Any other
    /// failure is `.inconclusive`.
    public func probeAccountStatus() async -> AccountProbeOutcome {
        // No local token to authenticate with ⇒ the session is already gone
        // (e.g. an incidental 401 already fired the token-expiry bridge). Treat
        // as gone so the caller still runs the full account-deletion wipe.
        guard isAuthenticated else { return .gone }
        let req = APIRequest<EmptyPayload>(
            method: .get,
            path: "/api/auth/me",
            maxRetries: 0,
            failFast: true
        )
        do {
            try await api.sendVoid(req)
            return .exists
        } catch let error as HLError {
            switch error {
            case let .server(status, _, _) where status == 401 || status == 404:
                return .gone
            case .unauthorized:
                return .gone
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    public func logout() async throws {
        // Best-effort revoke des Refresh-Tokens auf dem Server (`05-auth-flows.md
        // §8.1`): wenn vorhanden, schicken wir `{ refreshToken, revoke: true }`,
        // sonst Fallback auf den (cookie-orientierten) `/logout`-Pfad. Beide
        // Fehler werden geschluckt — Keychain-Wipe passiert immer.
        if let refresh = keychain.getString(forKey: KeychainKey.refreshToken) {
            struct RevokeBody: Encodable {
                let refreshToken: String
                let revoke: Bool
            }
            let revokeReq: APIRequest<EmptyPayload> = (try? .post(
                "/api/auth/refresh",
                body: RevokeBody(refreshToken: refresh, revoke: true),
                maxRetries: 0
            )) ?? APIRequest(method: .post, path: "/api/auth/refresh")
            _ = try? await api.sendVoid(revokeReq)
        } else {
            let req: APIRequest<EmptyPayload> = APIRequest(method: .post, path: "/api/auth/logout")
            _ = try? await api.sendVoid(req)
        }
        // Owner: Composition-Root setzt `onLogoutCleanup` (siehe AppContainer), damit
        // iOS-only Side-Effects (HK-Anchor-Wipe per User-Partition) hier einhängen
        // können, ohne dass `HealthLogCore` selbst die HK-Symbole kennen muss.
        let previousUserID = try invalidateAndWipeSessionCredentials()
        if let cleanup = onLogoutCleanup {
            await cleanup(previousUserID)
        }
    }

    /// Optional hook that fires AFTER the keychain wipe of token/refresh/userID
    /// during `logout()` (and the same shape is used by the 401-bridge in
    /// `AuthStore.handleUnauthorized`). Receives the User-ID that WAS associated
    /// with this session — the Composition-Root uses it to wipe the per-user
    /// HK-Anchor-Partition.
    public func setOnLogoutCleanup(_ cleanup: (@Sendable (String?) async -> Void)?) {
        onLogoutCleanup = cleanup
    }

    private var onLogoutCleanup: (@Sendable (String?) async -> Void)?

    // MARK: - Passkey (WebAuthn)

    public func passkeyLogin(presentationAnchor: ASPresentationAnchorProvider) async throws -> AuthSession {
        // Server-Form: `{ options: PublicKeyCredentialRequestOptionsJSON, challengeId }`.
        // `maxRetries: 0` for the same rate-limit reason as `/api/auth/login`.
        // #96 — `failFast: true` → no-wait-for-connectivity auth session
        // (immediate `HLError.offline` with no network); the `withTimeout(12s)`
        // race below stays as a watchdog for the slow-but-CONNECTED case.
        let optsReq: APIRequest<PasskeyLoginOptionsResponse> = APIRequest(
            method: .post,
            path: "/api/auth/passkey/login-options",
            maxRetries: 0,
            failFast: true
        )
        let optsResponse = try await Self.withTimeout(seconds: 12) {
            try await self.api.send(optsReq)
        }

        let assertion = try await passkey.assert(
            challenge: optsResponse.options.challenge,
            rpId: optsResponse.options.rpId,
            allowCredentialIDs: optsResponse.options.allowCredentials?.map(\.id) ?? [],
            anchor: presentationAnchor
        )

        // Server-Form: `{ challengeId, credential: AuthenticationResponseJSON }`.
        struct VerifyBody: Encodable {
            let challengeId: String
            let credential: WebAuthnAssertionDTO
        }
        let body = VerifyBody(
            challengeId: optsResponse.challengeId,
            credential: WebAuthnAssertionDTO(
                id: assertion.credentialID,
                rawId: assertion.credentialID,
                type: "public-key",
                response: .init(
                    clientDataJSON: assertion.clientDataJSON,
                    authenticatorData: assertion.authenticatorData,
                    signature: assertion.signature,
                    userHandle: assertion.userHandle
                )
            )
        )
        let verifyReq: APIRequest<NativeLoginResponse> = try .post(
            "/api/auth/passkey/login-verify",
            body: body,
            maxRetries: 0,
            failFast: true // #96 — same fail-fast auth session as login-options.
        )
        let response = try await Self.withTimeout(seconds: 12) { // belt-and-suspenders watchdog
            try await self.api.send(verifyReq)
        }
        let session = try response.asAuthSession()
        try persist(session)
        return session
    }

    /// Belt-and-suspenders timeout race scoped to the passkey-login legs.
    /// #96 moved the no-connectivity case to APIClient's fail-fast auth
    /// session; this still guards the slow-but-connected server case, racing
    /// the network op against a `Task.sleep` budget (first finisher wins, the
    /// loser is cancelled) and throwing a passkey-specific "server unreachable"
    /// `HLError` on timeout. Swift-6 strict-concurrency clean.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw HLError.unknown(String(localized: "Server unreachable — passkey sign-in failed."))
            }
            // First child to finish wins; `next()` rethrows its error (timeout
            // or network). Cancel the remaining child before returning.
            guard let result = try await group.next() else {
                throw HLError.unknown(String(localized: "Server unreachable — passkey sign-in failed."))
            }
            group.cancelAll()
            return result
        }
    }

    // Passkey **enrolment** is intentionally absent (CU-15 / catchup-v134 A5).
    //
    // `POST /api/auth/passkey/register-options` and `register-verify` became
    // **cookie-only** (`requireCookieAuth()`) on server v1.34.1 and additionally
    // demand a body carrying either `{ method: "passkey" | "webauthn" }` (which
    // starts a re-proof) or a full step-up proof. A pure Bearer client — which
    // is what this service is — gets `401 "Fresh existing-factor proof
    // required"` on the very first leg, so the native enrolment ceremony could
    // never complete. It was removed rather than left in place to 401.
    //
    // Passkey **login** (`login-options` / `login-verify`) is unaffected and
    // stays exactly as it is above; so do the Bearer-reachable management verbs
    // in `PasskeyRepository` (list / rename / revoke, all on `requireAuth()`).
    // New credentials are registered in the web UI — `PasskeyManagementScreen`
    // links to `<configured server>/settings/security`.
    //
    // Bringing enrolment back natively means implementing the cookie/re-proof
    // handshake (a web-view auth handoff or a step-up-proof-carrying client),
    // which is its own project against the new contract — not a patch here.

    // MARK: - Refresh

    /// Ruft `POST /api/auth/refresh` auf und klassifiziert das Ergebnis
    /// dreiwertig (siehe ``RefreshOutcome``):
    ///
    /// - ``RefreshOutcome/refreshed`` — neues Token-Paar persistiert, Caller
    ///   wiederholt mit frischem Bearer.
    /// - ``RefreshOutcome/authFailure`` — Server hat den Refresh-Token als tot
    ///   verworfen (`revoked` / `reuse` / `invalid`, Server v1.7.0 errorCodes
    ///   `auth.refresh.*`, oder generisch 4xx auf der Refresh-Route). Session
    ///   muss abgerissen werden → Caller feuert `onUnauthorized`.
    /// - ``RefreshOutcome/transient`` — Netzwerk/Offline/5xx/Rate-Limit. Token
    ///   ist mit hoher Wahrscheinlichkeit noch gültig; **kein** Logout. Das ist
    ///   die 401-Cascade-Schutzschicht: ein transienter Refresh-Fehler darf
    ///   nicht in einen Spurious-Logout-Storm kippen (siehe `05-auth-flows.md
    ///   §3 + §6` + R4-Offline-Groundwork).
    ///
    /// **Kein lokaler Refresh-Token** wird als ``transient`` behandelt: wir
    /// haben schlicht nichts zum Refreshen, aber das ist kein Server-Verdikt
    /// über die Gültigkeit des aktuellen Bearer — der Caller soll daraus nicht
    /// ausloggen (der ursprüngliche 401 trägt den Logout, falls der Server den
    /// Bearer selbst verwirft).
    public func refresh() async -> RefreshOutcome {
        guard let refreshToken = keychain.getString(forKey: KeychainKey.refreshToken) else {
            return .transient
        }
        let capturedPersistenceGeneration = credentialPersistenceGeneration
        struct Body: Encodable {
            let refreshToken: String
        }
        // `maxRetries: 0` — `/api/auth/refresh` ist rate-limited (60/15min/IP)
        // und ein zweiter Request mit demselben one-time-use-Token wäre ein
        // sofortiger 401 + revokeAllForUser. Wir müssen jeden Refresh als
        // genau einen Network-Call halten.
        // #96 — refresh rides the fail-fast auth session too: a no-connectivity
        // refresh fails immediately (→ `.transient`) instead of stalling the
        // cold-launch door on the 60 s outbox resource timeout.
        guard let req: APIRequest<NativeLoginResponse> = try? .post(
            "/api/auth/refresh",
            body: Body(refreshToken: refreshToken),
            maxRetries: 0,
            failFast: true
        ) else {
            return .transient
        }
        do {
            let response = try await api.send(req)
            let session = try response.asAuthSession()
            guard capturedPersistenceGeneration == credentialPersistenceGeneration else {
                HLLog.auth.notice("Refresh response discarded after account-boundary invalidation.")
                return .transient
            }
            try persist(session)
            return .refreshed
        } catch {
            let outcome = RefreshOutcome.classify(error)
            HLLog.auth.warning(
                "Refresh fehlgeschlagen (\(String(describing: outcome), privacy: .public)): \(String(describing: error), privacy: .private)"
            )
            return outcome
        }
    }

    // MARK: - Persistence

    /// Atomar persistiertes Credential-Set: entweder ALLE fünf Keychain-Slots
    /// (Bearer, Refresh, Access-Expiry, Refresh-Expiry, User-ID) landen mit
    /// den neuen Werten, oder die vorherigen Werte bleiben unangetastet.
    ///
    /// Hintergrund (Security-Audit v0629 H-3): die alte Implementierung hat die
    /// fünf Slots seriell mit `try` geschrieben. Ein partieller Fehlschlag
    /// (z.B. neuer Bearer landet, neuer Refresh wirft) hätte einen STALEN
    /// Refresh-Token zusammen mit einem frischen Access-Token hinterlassen.
    /// Beim nächsten `/api/auth/refresh` sieht der Server den verbrauchten
    /// Refresh-Token → `revokeAllForUser` → Logout auf allen Geräten.
    ///
    /// Strategie: vor dem Schreiben einen Snapshot der bestehenden Werte
    /// ziehen, dann sequenziell schreiben. Wirft irgendein Write, rollen wir
    /// alle bereits geschriebenen Keys auf den Snapshot zurück und werfen
    /// den ursprünglichen Fehler weiter. So bleibt der vorherige Credential-Satz
    /// konsistent oder der neue komplett, nie ein Mix.
    private func persist(_ session: AuthSession) throws {
        // Zu schreibende Felder (Reihenfolge ist nicht semantisch wichtig, aber
        // stabil für Rollback-Tests). Optionale Felder werden auf den
        // vorherigen Wert "geschrieben" (= unverändert) wenn die Session
        // keinen liefert, damit Rollback-Symmetrie gilt.
        let isoFormatter = ISO8601DateFormatter()
        var pendingWrites: [(key: String, value: String)] = []
        pendingWrites.append((KeychainKey.authToken, session.token))
        if let refresh = session.refreshToken {
            pendingWrites.append((KeychainKey.refreshToken, refresh))
        }
        if let expires = session.expiresAt {
            pendingWrites.append((KeychainKey.accessTokenExpiresAt, isoFormatter.string(from: expires)))
        }
        if let refreshExpires = session.refreshTokenExpiresAt {
            pendingWrites.append((KeychainKey.refreshTokenExpiresAt, isoFormatter.string(from: refreshExpires)))
        }
        // 24-01 — the same guard the `userDisplayName` write below has carried
        // all along, against the same input. The refresh route answers without
        // a `user` block (contract, W2a-A2 §3.1), so `asAuthSession()` hands us
        // a stub `User(id: "")`. Harmless until Phase 06 made this slot a GATE:
        // `setString("")` is a successful upsert, so every lease-fenced store
        // (dashboard summary, medications, measurements, profile) then trims an
        // empty owner id, records `.leaseUnavailable` and returns WITHOUT
        // ISSUING ANY REQUEST — publishing no error either, so the metrics
        // section resolves to a permanent `.skeleton` that survives restarts
        // and updates. A session with no id carries no news about the identity.
        if let resolvedUserID = session.user.id.trimmedNonEmptyHint {
            pendingWrites.append((KeychainKey.userID, resolvedUserID))
        }
        // Cold-launch avatar seed: persist the best-available identity label
        // (displayName → username → email-local-part) so `bootstrap()` can
        // build a NAMED `User` and the avatar paints real initials instead of
        // `"?"` before the server profile round-trips. Only written when the
        // session actually carries a name — the refresh path hands us a stub
        // user (empty id, nil fields), and we must not clobber a good hint
        // with an empty one. Stays in the Keychain, never leaves the device.
        if let nameHint = Self.identityHint(for: session.user) {
            pendingWrites.append((KeychainKey.userDisplayName, nameHint))
        }

        // Snapshot der vorherigen Werte ausschließlich für die Keys, die wir
        // tatsächlich überschreiben — sonst würde ein Rollback Felder auf
        // `nil` zwingen, die wir nie angefasst haben.
        var snapshot: [String: String?] = [:]
        for (key, _) in pendingWrites {
            snapshot[key] = keychain.getString(forKey: key)
        }

        var writtenKeys: [String] = []
        do {
            for (key, value) in pendingWrites {
                try keychain.setString(value, forKey: key)
                writtenKeys.append(key)
            }
        } catch {
            // Rollback: vorherige Werte wiederherstellen für jeden bereits
            // geschriebenen Slot. Rollback-Fehler werden geschluckt — wir
            // können nicht "doppelt failen" und der ursprüngliche Fehler hat
            // Priorität für den Aufrufer.
            for key in writtenKeys {
                if let previous = snapshot[key], let prevValue = previous {
                    try? keychain.setString(prevValue, forKey: key)
                } else {
                    try? keychain.remove(forKey: key)
                }
            }
            HLLog.auth.error("Keychain-persist partial failure, rolled back: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    /// Best-available, non-empty identity label for the cold-launch avatar
    /// seed: `displayName` → `username` → email-local-part (the part before
    /// `@`). Returns `nil` when the user carries no usable label so the
    /// caller skips the Keychain write rather than persisting an empty hint.
    static func identityHint(for user: User) -> String? {
        if let displayName = user.displayName?.trimmedNonEmptyHint {
            return displayName
        }
        if let username = user.username?.trimmedNonEmptyHint {
            return username
        }
        if let email = user.email?.trimmedNonEmptyHint {
            let local = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
            return local.trimmedNonEmptyHint
        }
        return nil
    }
}

// MARK: - Atomic credential teardown

extension AuthService {
    /// Advances the refresh-persistence boundary and wipes every account-bound
    /// credential in one non-suspending actor turn. A refresh queued during the
    /// synchronous Keychain work cannot enter the actor until its token is gone;
    /// a refresh already suspended carries the previous generation and is
    /// discarded on resume.
    func invalidateAndWipeDeletedAccountCredentials() {
        credentialPersistenceGeneration &+= 1
        Self.wipeDeletedAccountKeychain(using: keychain)
    }

    /// Terminal session teardown used by explicit logout and the unauthorized
    /// bridge. Generation invalidation and every auth-bundle removal are one
    /// synchronous actor turn, so a queued refresh cannot observe the advanced
    /// generation while the old refresh token is still present.
    ///
    /// Every key is attempted. Explicit logout still receives the first removal
    /// error after the complete best-effort wipe; terminal unauthorized handling
    /// intentionally ignores it, matching its previous fail-closed behavior.
    func invalidateAndWipeSessionCredentials() throws -> String? {
        let previousUserID = keychain.getString(forKey: KeychainKey.userID)
        if let previousUserID { try? keychain.setString(previousUserID, forKey: KeychainKey.lastSessionUserID) } // A2
        credentialPersistenceGeneration &+= 1
        let requiredKeys = [
            KeychainKey.authToken,
            KeychainKey.refreshToken,
            KeychainKey.refreshTokenExpiresAt,
            KeychainKey.accessTokenExpiresAt,
            KeychainKey.userID
        ]
        var firstError: (any Error)?
        for key in requiredKeys {
            do {
                try keychain.remove(forKey: key)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        // The display-name hint has always been best-effort on explicit logout.
        // Preserve that contract while still attempting it in the same actor turn.
        try? keychain.remove(forKey: KeychainKey.userDisplayName)
        if let firstError { throw firstError }
        return previousUserID
    }
}

// MARK: - Web-handoff login (#65 / v1.32.11)

/// Same-file extension (NOT a separate file): `webLoginTokenExchange` reads the
/// fileprivate `NativeLoginResponse` DTO and the actor-private `persist(_:)`,
/// both of which a same-file extension can still see. Keeping it out of the
/// actor's primary body holds AuthService under the SwiftLint `type_body_length`
/// error (actor body ≤ 500 lines).
public extension AuthService {
    /// #65 / v1.32.11 — exchanges a native web-handoff one-time login code (from
    /// the `healthlog://login-callback?code=hlh_…` redirect) for the STANDARD
    /// native token bundle at `POST /api/auth/native/token`. Structurally
    /// identical to ``oidcNativeTokenExchange(code:codeVerifier:)`` — only the
    /// path differs: the body carries the opaque `code` + the app's in-memory
    /// PKCE `codeVerifier`, and it pins `X-Client-Type: native` explicitly. The
    /// `data` is the SAME `AccessRefreshBundle` password / passkey / OIDC login
    /// issues, so it decodes through the existing ``NativeLoginResponse`` DTO
    /// unchanged → persists via the SAME Keychain path and returns the session.
    /// Web-login and OIDC codes are separate server-side; this route only
    /// honours web-login codes.
    ///
    /// **Exchange exactly once.** `maxRetries: 0` keeps this to a single network
    /// call — a replayed/consumed code revokes the freshly-issued pair
    /// server-side (interception containment), so any failure (single generic
    /// 401 for every invalid-code class) is a login failure the caller surfaces,
    /// never a retry. `failFast: true` matches the other interactive auth legs.
    /// The `code` + `codeVerifier` + tokens are sensitive — never logged.
    func webLoginTokenExchange(code: String, codeVerifier: String) async throws -> AuthSession {
        struct Body: Encodable {
            let code: String
            let codeVerifier: String
        }
        let bodyData = try JSONEncoder.hlDefault.encode(Body(code: code, codeVerifier: codeVerifier))
        let req = APIRequest<NativeLoginResponse>(
            method: .post,
            path: "/api/auth/native/token",
            body: bodyData,
            extraHeaders: ["X-Client-Type": "native"],
            maxRetries: 0,
            failFast: true
        )
        let response = try await api.send(req)
        let session = try response.asAuthSession()
        try persist(session)
        return session
    }

    /// #65 / **13-02** — fail-closed gate: may this server's web-handoff login
    /// be offered to the user?
    ///
    /// **This used to be a version statement, and a version is not a
    /// reachability statement.** `GET /api/version` → `isAtLeast("1.32.11")`
    /// answers "were these routes ever built here", which is necessary and not
    /// sufficient. The operator's instance is far past the floor and its login
    /// route still `307`s to `https://0.0.0.0:3000/…` — a redirect built from
    /// the process bind address instead of the forwarded host
    /// (healthlog-iOS#96, measured). Build 266 therefore showed a brand-new
    /// user a CTA into a browser error page and called it available.
    ///
    /// So the floor is now the *first* of two questions, and the second one
    /// asks the login route itself where it leads. Any failure at either step —
    /// offline, decode error, pre-contract build, missing route, dead-end
    /// redirect — keeps the native password form. Probed off `OnboardingFlow`
    /// alongside `registrationEnabled` + `oidcStatus`.
    func webLoginAvailable() async -> Bool {
        await webLoginRouteStatus().isAvailable
    }

    /// **13-02** — the gate's reasoning, not just its verdict. Callers that
    /// only need yes/no use ``webLoginAvailable()``; this exists so a failure
    /// can be *named* in a log line and in a summary rather than collapsing
    /// into a silent `false`.
    ///
    /// Cached per host for the lifetime of this service, because the auth step
    /// probes on step transitions and must never probe per render. The cache
    /// key is the host the probe was made against, so re-targeting the app at
    /// a different server re-asks rather than reusing a verdict about somebody
    /// else's instance.
    func webLoginRouteStatus() async -> WebLoginRouteStatus {
        let host = AppEnvironment.currentBaseURL(keychain: keychain)?.host?.lowercased()
        if let cached = cachedWebLoginRouteStatus, cached.host == host {
            return cached.status
        }
        let status = await resolveWebLoginRouteStatus()
        cachedWebLoginRouteStatus = (host: host, status: status)
        // Closed-set word, no host, no token — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.auth.debug("Web-login route probe: \(status.logLabel, privacy: .public)")
        return status
    }

    private func resolveWebLoginRouteStatus() async -> WebLoginRouteStatus {
        guard let info = try? await api.fetchServerVersion() else { return .unreachable }
        guard WebHandoffLogin.isAvailable(on: info) else { return .versionTooOld }
        // A throwaway challenge: the probe's state cookie is discarded with the
        // response, and the real flow mints its own inside the browser session.
        return await api.probeWebLoginRoute(codeChallenge: OidcPKCE.generate().codeChallenge)
    }
}
