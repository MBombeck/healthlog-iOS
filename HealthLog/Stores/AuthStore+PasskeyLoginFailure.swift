import Foundation

// MARK: - L1 — what a refused passkey sign-in tells the person

extension AuthStore {
    /// `loginWithPasskey(anchor:)`'s failure routing: a refused passkey is not
    /// an expired session. See ``passkeyLoginFailure(_:)``.
    func failPasskeyLogin(_ error: HLError, attempt: AuthAttempt) {
        failAttempt(Self.passkeyLoginFailure(error), for: attempt)
        HLLog.auth.error("Passkey sign-in failed: \(error.localizedDescription, privacy: .private)")
    }

    /// Maps a failed passkey sign-in onto the sentence the sign-in form shows.
    ///
    /// **Why this exists.** Both passkey legs sit under `/api/auth/passkey/`,
    /// which `APIClient.isAuthExempt` keeps out of the refresh bridge, so a 401
    /// from `login-verify` arrives as a bare ``HLError/unauthorized``. That case
    /// means "your session ended" everywhere else, and its
    /// ``HLError/userFacingDescription`` reads "Sign-in expired. Please sign in
    /// again." — which is what a person whose passkey the server refused was
    /// told (J1 walk, 26.09.2026). A refused passkey is not an expired session.
    ///
    /// **Server contract (v1.39.2, `src/app/api/auth/passkey/login-options`
    /// and `login-verify/route.ts`).**
    /// - `401 "Passkey verification failed"` — the assertion did not verify.
    /// - `404 "User not found"` — the passkey's account is gone.
    /// - `422 "challengeId and credential required"` — malformed body.
    /// - `403 { meta.errorCode: "oidc_only" }` — passkey sign-in is off (SSO
    ///   only) on this instance; both legs answer it.
    /// - `429` — 10 attempts / 15 min per IP on each leg.
    /// - An unknown credential or an expired challenge is a plain `throw` in
    ///   `verifyAuthentication` (`src/lib/auth/passkey.ts`) and reaches the
    ///   client as a generic `500 "Interner Serverfehler"`. It is
    ///   indistinguishable from a real server fault and keeps the server-error
    ///   copy here; the server would have to answer 401/404 for it.
    ///
    /// The server prose is English-only, so every mapped sentence comes from
    /// the string catalog. `meta.errorCode` is kept where the server sent one.
    ///
    /// What is NOT mapped, on purpose:
    /// - A cancelled system sheet: `normalizePasskeyError` turns it into
    ///   ``HLError/canceled`` before this runs, and the shared classifier drops
    ///   it without a banner.
    /// - Network trouble (``HLError/offline``, ``HLError/network(_:)``, the
    ///   12 s watchdog's ``HLError/Underlying/timeout``): the sign-in banner
    ///   renders those through ``HLError/signInFacingDescription``.
    nonisolated static func passkeyLoginFailure(_ error: HLError) -> HLError {
        switch error {
        case .unauthorized:
            passkeyRejected(code: nil)
        case let .server(401, code, _), let .server(404, code, _), let .server(422, code, _):
            passkeyRejected(code: code)
        case .server(403, "oidc_only", _):
            .server(
                status: 403,
                code: "oidc_only",
                message: String(localized: "auth.passkey.error.ssoOnly")
            )
        case let .rateLimited(retryAfter):
            rateLimitedSignIn(retryAfter: retryAfter)
        case .server(429, _, _):
            rateLimitedSignIn(retryAfter: nil)
        default:
            error
        }
    }

    private nonisolated static func passkeyRejected(code: String?) -> HLError {
        .server(
            status: 401,
            code: code,
            message: String(localized: "auth.passkey.error.rejected")
        )
    }
}

public extension HLError {
    /// The sentence a sign-in surface (sign-in form, registration sheet, MFA
    /// sheet) shows for this error.
    ///
    /// ``userFacingDescription`` is written for surfaces that already hold
    /// data: offline reads "Offline — showing cached values.", a dropped
    /// connection "We'll retry automatically." Neither is true on a sign-in
    /// form, where nothing is cached and nothing retries. Those cases get a
    /// plain "couldn't reach the server" sentence instead.
    ///
    /// ``HLError/unknown(_:)`` carries its sentence through: on the sign-in
    /// path every producer puts catalog copy into it (the SSO / web-login /
    /// MFA sentences in `AuthStore`, the passkey sentences in
    /// `PasskeyService`, the auth-service guards), and the catch-all for a
    /// non-``HLError`` stores the generic catalog sentence, never the error's
    /// own description. Everything else is ``userFacingDescription``.
    var signInFacingDescription: String {
        switch self {
        case .offline,
             .network(.connectionLost),
             .network(.dnsFailure),
             .network(.sslPinning),
             .network(.writeCancelled),
             .network(.other):
            String(localized: "auth.error.unreachable")
        case let .unknown(message) where !message.isEmpty:
            message
        default:
            userFacingDescription
        }
    }
}
