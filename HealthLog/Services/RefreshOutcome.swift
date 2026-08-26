import Foundation

/// Three-way result of a `POST /api/auth/refresh` attempt.
///
/// **Why three-way (401-cascade gating, v0.10.0):** the pre-v0.10.0 refresh
/// path returned a plain `Bool` and treated *every* non-success as "logout the
/// user." That conflated two very different failures:
///
/// - A **genuine auth failure** — the server says the refresh token is
///   `revoked` / `reuse`-detected / `invalid` (server v1.7.0 stable errorCodes
///   `auth.refresh.{revoked,reuse,invalid}`). The session is dead; the user
///   must re-authenticate. → ``authFailure``.
/// - A **transient failure** — offline, DNS, timeout, 5xx, rate-limit, or any
///   network error mid-refresh. The token is almost certainly still valid; a
///   later request will refresh successfully. Nuking the session here is a
///   spurious logout the user never deserved (the 401-cascade failure mode).
///   → ``transient``.
///
/// The APIClient maps these: ``refreshed`` → retry the original request;
/// ``authFailure`` → fire `onUnauthorized` (logout cascade); ``transient`` →
/// **do not** fire `onUnauthorized` — the request fails this once, the session
/// survives.
public enum RefreshOutcome: Sendable, Equatable {
    /// A fresh token pair was persisted — the caller should retry with the new
    /// bearer.
    case refreshed
    /// The server rejected the refresh token as genuinely dead
    /// (`revoked` / `reuse` / `invalid`, or any other 401/403 on the refresh
    /// route). The session must be torn down.
    case authFailure
    /// The refresh could not complete for a transient reason (network/offline/
    /// 5xx/rate-limit). The session is left intact; a later attempt may succeed.
    case transient

    /// Convenience for the APIClient retry gate: did we obtain a usable token?
    public var didRefresh: Bool {
        self == .refreshed
    }

    /// Should the caller tear down the session (fire `onUnauthorized`)? Only on
    /// a genuine auth failure — never on a transient one.
    public var shouldLogout: Bool {
        self == .authFailure
    }

    /// Classifies a refresh-route failure into ``authFailure`` vs ``transient``.
    ///
    /// Genuine-auth signals: any `HLError.unauthorized`, or an
    /// `HLError.server` with a `4xx` status (the server uses `401`/`403` +
    /// `auth.refresh.{revoked,reuse,invalid}` for the dead-token cases — a
    /// `4xx` on the refresh route is definitionally an auth verdict, not a
    /// transient hiccup). Everything else — offline, network, timeout, 5xx,
    /// rate-limit, decode — is transient and must NOT log the user out.
    public static func classify(_ error: Error) -> RefreshOutcome {
        guard let hl = error as? HLError else { return .transient }
        switch hl {
        case .unauthorized:
            return .authFailure
        case let .server(status, _, _):
            return (400 ... 499).contains(status) ? .authFailure : .transient
        // `.writeConflictUnresolved` is a CU-20 write-path verdict and can
        // never originate on the refresh route; classified transient so it
        // could never log the user out.
        // `.serverNotConfigured` heisst, dass gar keine Adresse hinterlegt
        // ist — kein Auth-Urteil. Transient, denn ein Logout waere die
        // falsche Antwort auf "noch nicht eingerichtet".
        // `.refusedWithReason` is likewise a domain verdict from a route that
        // is not this one: the promotion is opt-in per error code and no auth
        // code is on that list, so it can never mean "log the user out".
        case .network, .offline, .rateLimited, .canceled, .decoding,
             .assistantDisabled, .moduleDisabled, .notPersisted,
             .writeConflictUnresolved, .serverNotConfigured, .refusedWithReason,
             .unknown:
            return .transient
        }
    }
}
