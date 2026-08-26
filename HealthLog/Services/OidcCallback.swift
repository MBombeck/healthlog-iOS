import Foundation

/// #49 / v1.30.11 — the closed set of `error=<reason>` values the native OIDC
/// callback can return on `healthlog://oidc-callback?error=…`. Each maps to a
/// localized, surfaced message — the app never renders a web error page.
public enum OidcErrorReason: Sendable, Equatable {
    case denied
    case noEmail
    case emailUnverified
    case identityConflict
    case registrationDisabled
    case rateLimited
    /// A reason outside the documented closed set (forward-compat) — surfaced
    /// with the generic SSO-failure copy. Carries the raw token for the log
    /// label only (the reason word is a closed vocabulary, not PII/secret).
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "denied": self = .denied
        case "no-email": self = .noEmail
        case "email-unverified": self = .emailUnverified
        case "identity-conflict": self = .identityConflict
        case "registration-disabled": self = .registrationDisabled
        case "rate-limited": self = .rateLimited
        default: self = .unknown(raw)
        }
    }

    /// Localized, user-facing message (de+en) surfaced on the auth step.
    public var localizedMessage: String {
        switch self {
        case .denied: String(localized: "onboarding.sso.error.denied")
        case .noEmail: String(localized: "onboarding.sso.error.noEmail")
        case .emailUnverified: String(localized: "onboarding.sso.error.emailUnverified")
        case .identityConflict: String(localized: "onboarding.sso.error.identityConflict")
        case .registrationDisabled: String(localized: "onboarding.sso.error.registrationDisabled")
        case .rateLimited: String(localized: "onboarding.sso.error.rateLimited")
        case .unknown: String(localized: "onboarding.sso.error.generic")
        }
    }

    /// Non-sensitive diagnostic label. An out-of-set reason logs as `unknown`.
    public var logLabel: String {
        switch self {
        case .denied: "denied"
        case .noEmail: "no-email"
        case .emailUnverified: "email-unverified"
        case .identityConflict: "identity-conflict"
        case .registrationDisabled: "registration-disabled"
        case .rateLimited: "rate-limited"
        case .unknown: "unknown"
        }
    }
}

/// The parsed outcome of a `healthlog://oidc-callback?…` redirect (#49). One of:
/// a one-time handoff `code`, an `mfa_ticket` (+ offered methods), a closed-set
/// `error`, or an unrecognized shape.
public enum OidcCallback: Sendable, Equatable {
    /// `code=hlh_…` — exchange once at `POST /api/auth/oidc/native/token`.
    case code(String)
    /// `mfa_ticket=…&methods=totp,recovery,webauthn` — route into the existing
    /// #37 MFA-verify flow with native headers.
    case mfa(ticket: String, methods: [MfaMethod])
    /// `error=<reason>` from the documented closed set — surfaced natively.
    case error(OidcErrorReason)
    /// A callback whose query carried none of the recognised keys.
    case unrecognized

    /// Parses the callback URL's query. Precedence: `error` → `code` →
    /// `mfa_ticket`. The `code`/`mfa_ticket` values are sensitive — the caller
    /// never logs them.
    public static func parse(_ url: URL) -> OidcCallback {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .unrecognized
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nilIfEmpty
        }
        if let error = value("error") {
            return .error(OidcErrorReason(raw: error))
        }
        if let code = value("code") {
            return .code(code)
        }
        if let ticket = value("mfa_ticket") {
            let methods = (value("methods") ?? "")
                .split(separator: ",")
                .compactMap { MfaMethod(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            return .mfa(ticket: ticket, methods: methods)
        }
        return .unrecognized
    }
}

/// Native OIDC flow constants + authorize-URL builder (#49 / v1.30.11).
public enum OidcNativeFlow {
    /// The registered custom scheme (matches `CFBundleURLSchemes: [healthlog]`),
    /// used as the `ASWebAuthenticationSession` `callbackURLScheme`. The server's
    /// `NATIVE_OIDC_REDIRECT_URI` constant is fixed to `healthlog://oidc-callback`
    /// (there is intentionally no client-supplied `redirect_uri` — that removes
    /// the open-redirect / scheme-hijack primitive by construction).
    public static let callbackScheme = "healthlog"

    /// Builds `<baseURL>/api/auth/oidc/login?client=native&code_challenge=<S256>`
    /// — the authorize entry opened inside the auth session.
    public static func loginURL(baseURL: URL, codeChallenge: String) -> URL? {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("/api/auth/oidc/login"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "client", value: "native"),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]
        return comps?.url
    }
}
