import Foundation

// MARK: - J1 / F1 — what a refused password sign-in tells the person

extension AuthStore {
    /// `login(email:password:)`'s failure routing: a refused password is not
    /// an expired session. See ``passwordLoginFailure(_:)``.
    func failPasswordLogin(_ error: HLError, attempt: AuthAttempt) {
        failAttempt(Self.passwordLoginFailure(error), for: attempt)
        HLLog.auth.error("Auth-Fehler: \(error.localizedDescription, privacy: .private)")
    }

    /// Maps a failed `POST /api/auth/login` onto the sentence the sign-in form
    /// shows.
    ///
    /// **Why this exists.** `/api/auth/login` is auth-exempt in `APIClient`, so
    /// its 401 never enters the refresh bridge and arrives as a bare
    /// ``HLError/unauthorized``. That case means "your session ended" everywhere
    /// else, and its ``HLError/userFacingDescription`` reads "Sign-in expired.
    /// Please sign in again." — which is what a person who mistyped their
    /// password was told (App Review walk, 26.09.2026). A mistyped password is
    /// not an expired session.
    ///
    /// **Server contract (v1.39.2, `src/app/api/auth/login/route.ts`).**
    /// - `401 { error: "Invalid credentials" }` — unknown identifier, account
    ///   without a password, wrong password. One body for all three on purpose
    ///   (no account-enumeration channel), and no `meta.errorCode`.
    /// - `422 { error: "Invalid credentials", details }` — the zod parse
    ///   refused an empty identifier or password.
    /// - `429 { error: "Too many login attempts…" }` — 5 attempts / 15 min per IP;
    ///   since v1.39.3 also the per-account back-off from an unknown device
    ///   (`Retry-After` doubling from 30 s to 15 min). R2 / B — when the 429
    ///   names its wait, the sentence says how long (``rateLimitedSignIn(retryAfter:)``).
    /// - `403 { meta.errorCode: "oidc_only" }` — password sign-in is off on this
    ///   instance.
    ///
    /// `meta.errorCode` wins where the server sends one: a 401 that carries a
    /// code keeps it on the mapped error, and any code this build does not know
    /// passes through untouched (its server sentence stays the banner). The
    /// server prose itself is English-only, so the sentences for the known arms
    /// come from the string catalog.
    ///
    /// Only the password door uses this. A session that really expired still
    /// surfaces ``HLError/unauthorized`` and its "Sign-in expired" copy.
    nonisolated static func passwordLoginFailure(_ error: HLError) -> HLError {
        switch error {
        case .unauthorized:
            invalidCredentials(code: nil)
        case let .server(401, code, _), let .server(422, code, _):
            invalidCredentials(code: code)
        case let .rateLimited(retryAfter):
            rateLimitedSignIn(retryAfter: retryAfter)
        case .server(429, _, _):
            rateLimitedSignIn(retryAfter: nil)
        case .server(403, "oidc_only", _):
            .server(
                status: 403,
                code: "oidc_only",
                message: String(localized: "onboarding.auth.error.passwordLoginDisabled")
            )
        default:
            error
        }
    }

    /// R2 / #115 B — the sign-in rate-limit sentence, with the server's wait
    /// when the 429 carried one (`Retry-After`, read by `RateLimitDelay` in
    /// `APIClient` and handed through ``HLError/rateLimited(retryAfter:)``).
    /// Without a usable wait the sentence stays the J1 one ("a few minutes").
    /// Shared by the password and the passkey door.
    nonisolated static func rateLimitedSignIn(retryAfter: TimeInterval?) -> HLError {
        guard let retryAfter, retryAfter > 0, retryAfter.isFinite else {
            return .server(
                status: 429,
                code: nil,
                message: String(localized: "onboarding.auth.error.rateLimited")
            )
        }
        let wait = signInRetryWait(retryAfter)
        return .server(
            status: 429,
            code: nil,
            message: String(localized: "onboarding.auth.error.rateLimitedRetry \(wait)")
        )
    }

    /// "30 seconds" below a minute, otherwise whole minutes rounded up ("2
    /// minutes" for 90 s, "15 minutes" for 900 s) — never a promise that ends
    /// before the server's window does. Localised by Foundation.
    nonisolated static func signInRetryWait(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 60 {
            return Duration.seconds(whole).formatted(.units(allowed: [.seconds], width: .wide).locale(locale))
        }
        let minutes = (whole + 59) / 60
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide).locale(locale))
    }

    private nonisolated static func invalidCredentials(code: String?) -> HLError {
        .server(
            status: 401,
            code: code,
            message: String(localized: "onboarding.auth.error.invalidCredentials")
        )
    }
}
