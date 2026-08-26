import Foundation

/// parity 2.9 — the pre-session answer from `GET /api/auth/oidc/status`, the
/// same probe the web login page reads before deciding which doors to render
/// (`auth/login/page.tsx:83-100, 325-330`).
///
/// Three fields, three consequences:
/// * ``enabled`` — the instance has an IdP configured. `false` → the SSO button
///   is a dead affordance and must not be shown.
/// * ``only`` — `OIDC_ONLY` mode: the server *refuses* password + passkey +
///   registration. Showing those CTAs promises a door the server will slam.
/// * ``buttonLabel`` — the operator's own wording for the SSO button
///   ("Sign in with Acme SSO"). `nil` → fall back to the generic string.
public struct OidcStatus: Sendable, Equatable {
    public let enabled: Bool
    public let buttonLabel: String?
    public let only: Bool

    public init(enabled: Bool, buttonLabel: String? = nil, only: Bool = false) {
        self.enabled = enabled
        // An operator who sets an empty label means "no label", not "".
        let trimmed = buttonLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.buttonLabel = (trimmed?.isEmpty == false) ? trimmed : nil
        self.only = only
    }

    /// Whether password / passkey / registration CTAs must be hidden.
    ///
    /// Deliberately `enabled && only`, never `only` alone: `only` is a bare env
    /// read on the server and is independent of whether an IdP actually
    /// resolved. A misconfigured instance (`OIDC_ONLY=true` with no working
    /// provider) would otherwise render a login screen with *no doors at all* —
    /// an unrecoverable lockout. If SSO is not actually available we keep the
    /// password form, which at worst fails with the server's own message.
    public var hidesPasswordAffordances: Bool {
        enabled && only
    }

    /// Fail-soft default when the probe could not be answered (offline, 5xx,
    /// pre-flight against an unreachable host). Mirrors
    /// ``AuthService/registrationEnabled()``'s "assume open" stance: when we
    /// cannot know, show *every* door rather than hide one that works. The
    /// actual login call still surfaces the precise server refusal.
    public static let unknown = OidcStatus(enabled: true, buttonLabel: nil, only: false)
}
