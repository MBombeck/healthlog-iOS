import Foundation

/// #65 / v1.32.11 — the closed set of `error=<reason>` values the native
/// web-handoff login callback can return on
/// `healthlog://login-callback?error=…`. Each maps to a localized, surfaced
/// message — the app never renders a web error page.
///
/// Mirror of ``OidcErrorReason`` (#49), but a DISTINCT vocabulary: the
/// web-login contract uses **underscore** tokens (`invalid_state`,
/// `no_session`, `stale_session`, `rate_limited`) where OIDC used hyphens.
/// Don't cross-wire them.
public enum WebLoginErrorReason: Sendable, Equatable {
    /// The encrypted state cookie could not be matched to this handoff — the
    /// user must restart the sign-in from the app.
    case invalidState
    /// No interactive login was completed in the browser session.
    case noSession
    /// The browser session was authenticated, but not freshly enough — the
    /// server requires a fresh interactive login (no silent ambient-session
    /// reuse). The user re-authenticates in the sheet.
    case staleSession
    /// Too many handoff attempts — back off and retry.
    case rateLimited
    /// A reason outside the documented closed set (forward-compat) — surfaced
    /// with the generic web-login-failure copy. Carries the raw token for the
    /// log label only (a closed vocabulary word, not PII/secret).
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "invalid_state": self = .invalidState
        case "no_session": self = .noSession
        case "stale_session": self = .staleSession
        case "rate_limited": self = .rateLimited
        default: self = .unknown(raw)
        }
    }

    /// Localized, user-facing message (de+en) surfaced on the auth step.
    public var localizedMessage: String {
        switch self {
        case .invalidState: String(localized: "onboarding.webLogin.error.invalidState")
        case .noSession: String(localized: "onboarding.webLogin.error.noSession")
        case .staleSession: String(localized: "onboarding.webLogin.error.staleSession")
        case .rateLimited: String(localized: "onboarding.webLogin.error.rateLimited")
        case .unknown: String(localized: "onboarding.webLogin.error.generic")
        }
    }

    /// Non-sensitive diagnostic label. An out-of-set reason logs as `unknown`.
    public var logLabel: String {
        switch self {
        case .invalidState: "invalid_state"
        case .noSession: "no_session"
        case .staleSession: "stale_session"
        case .rateLimited: "rate_limited"
        case .unknown: "unknown"
        }
    }
}

/// The parsed outcome of a `healthlog://login-callback?…` redirect (#65). One
/// of: a one-time handoff `code`, a closed-set `error`, or an unrecognized
/// shape. **No MFA branch** — the second factor is handled entirely inside the
/// browser session, so the native side only ever sees a finished `code`.
public enum WebLoginCallback: Sendable, Equatable {
    /// `code=hlh_…` — exchange once at `POST /api/auth/native/token`.
    case code(String)
    /// `error=<reason>` from the documented closed set — surfaced natively.
    case error(WebLoginErrorReason)
    /// A callback whose host or query carried none of the recognised shapes.
    case unrecognized

    /// Parses the callback URL. Precedence: `error` → `code`. The host is
    /// checked against ``WebLoginNativeFlow/callbackHost`` first — the auth
    /// session captures EVERY `healthlog://` URL, so a stray OIDC callback
    /// (`healthlog://oidc-callback?…`) that reaches this parser must resolve
    /// to `.unrecognized`, not accidentally exchange an OIDC code on the
    /// web-login token route (cross-flow containment). The `code` value is
    /// sensitive — the caller never logs it.
    public static func parse(_ url: URL) -> WebLoginCallback {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .unrecognized
        }
        guard comps.host == WebLoginNativeFlow.callbackHost else {
            return .unrecognized
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nilIfEmpty
        }
        if let error = value("error") {
            return .error(WebLoginErrorReason(raw: error))
        }
        if let code = value("code") {
            return .code(code)
        }
        return .unrecognized
    }
}

/// Native web-handoff flow constants + login-URL builder (#65 / v1.32.11).
///
/// Mirrors ``OidcNativeFlow`` but targets the web-login route. The server's
/// native login redirect URI is fixed to `healthlog://login-callback` (there
/// is intentionally no client-supplied `redirect_uri` — removing the
/// open-redirect / scheme-hijack primitive by construction), and the only
/// query the contract accepts is `code_challenge` (no `client=native`).
public enum WebLoginNativeFlow {
    /// The registered custom scheme (matches `CFBundleURLSchemes: [healthlog]`),
    /// used as the `ASWebAuthenticationSession` `callbackURLScheme`. Shared with
    /// the OIDC flow — the two are separated by the callback HOST, not the scheme.
    public static let callbackScheme = "healthlog"

    /// The web-login callback host — distinct from OIDC's `oidc-callback`, so a
    /// callback can be attributed to the flow that opened it.
    public static let callbackHost = "login-callback"

    /// Builds `<baseURL>/api/auth/native/login?code_challenge=<S256>` — the
    /// web-login entry opened inside the auth session. The server sets an
    /// encrypted state cookie and 307-redirects to `/auth/login?flow=native`.
    ///
    /// 13-02 — forwards to ``WebLoginRoute/loginURL(baseURL:codeChallenge:)``.
    /// The availability probe lives in `HealthLogCore`, where this type does
    /// not, and a probe measuring a *different* address than the one the
    /// browser opens would be worse than no probe at all. One builder, two
    /// callers.
    public static func loginURL(baseURL: URL, codeChallenge: String) -> URL? {
        WebLoginRoute.loginURL(baseURL: baseURL, codeChallenge: codeChallenge)
    }
}
