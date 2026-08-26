import Foundation

/// The terminal signal of the WHOOP OAuth connect flow, parsed from the final
/// redirect URL the server lands on after the WHOOP callback.
///
/// **Server contract (B5).** On success the callback issues `302 →
/// `/settings/integrations?whoop=connected``; on failure `302 →
/// `/settings/integrations?whoop=error&reason=<reason>``. There is **no custom
/// scheme** today — the final redirect is a plain web URL on the app's own host
/// (the same host the `baseURL` points at), so we detect the outcome purely from
/// the `whoop` query item. (`ASWebAuthenticationSession` is opened with an HTTPS
/// callback at the `/settings/integrations` path so the session resolves the
/// moment that redirect lands — see ``WhoopConnectService``.)
///
/// The connect itself is gated server-side and the *authoritative* connected
/// state is always re-read from `GET /api/whoop/status` (`configured &&
/// connected`) after the flow — this enum is only the in-flight signal that
/// decides whether to surface success, an error reason, or stay quiet on cancel.
public enum WhoopConnectOutcome: Equatable, Sendable {
    /// Final redirect carried `whoop=connected`.
    case connected
    /// Final redirect carried `whoop=error&reason=<reason>` (reason may be empty
    /// if the server omitted it).
    case failed(reason: String)
    /// The user dismissed the auth sheet before the flow completed
    /// (`ASWebAuthenticationSessionError.canceledLogin`). Surfaces no error.
    case canceled

    /// Parses the outcome from the session's terminal callback URL.
    ///
    /// Returns `nil` when the URL carries no `whoop` query item at all — the
    /// caller treats that as "inconclusive, fall back to a status re-read"
    /// rather than inventing a success/failure.
    public static func from(callbackURL url: URL) -> WhoopConnectOutcome? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else
        {
            return nil
        }
        return from(queryItems: items)
    }

    /// Parses the outcome from already-extracted query items. Split out so the
    /// parse logic is testable without minting a full URL.
    public static func from(queryItems items: [URLQueryItem]) -> WhoopConnectOutcome? {
        guard let whoop = items.first(where: { $0.name == "whoop" })?.value else {
            return nil
        }
        switch whoop {
        case "connected":
            return .connected
        case "error":
            let reason = items.first(where: { $0.name == "reason" })?.value ?? ""
            return .failed(reason: reason)
        default:
            // An unknown `whoop=<x>` value is inconclusive — let the caller
            // re-read status rather than guess.
            return nil
        }
    }

    /// Maps a `whoop=error` `reason` token to a localized, user-facing message.
    /// Mirrors the server's documented reasons (`rate_limited`, `connect`,
    /// plus the credential / upstream family the `test` probe surfaces). Unknown
    /// reasons fall back to a generic connect failure.
    public var userFacingMessage: String? {
        switch self {
        case .connected, .canceled:
            nil
        case let .failed(reason):
            switch reason {
            case "rate_limited":
                String(localized: "WHOOP is rate-limiting requests. Try again in a moment.")
            case "connect", "":
                String(localized: "Couldn't start the WHOOP connection. Please try again.")
            case "denied", "access_denied":
                String(localized: "WHOOP access was declined. Connect again to grant access.")
            case "invalid_state", "state":
                String(localized: "The WHOOP sign-in expired. Please connect again.")
            case "not_configured", "credentials":
                String(localized: "Save your WHOOP credentials before connecting.")
            default:
                String(localized: "WHOOP connection failed. Please try again.")
            }
        }
    }
}
