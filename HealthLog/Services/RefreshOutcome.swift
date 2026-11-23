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
    /// The server rejected the refresh token as genuinely dead: a `401` on
    /// the refresh route (`auth.refresh.{revoked,reuse,invalid}`). The session
    /// must be torn down.
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

    /// The server's code for the loser of a concurrent refresh (#191).
    public static let supersededCode = "auth.refresh.superseded"

    /// `409 auth.refresh.superseded`: another refresh of this session won.
    public static func isSuperseded(_ error: Error) -> Bool {
        guard case let .server(status, code, _) = error as? HLError else { return false }
        return status == 409 && code == supersededCode
    }

    /// Classifies a refresh-route failure into ``authFailure`` vs ``transient``.
    ///
    /// The refresh route has exactly one way of saying "this token is dead":
    /// `401`, with `auth.refresh.{revoked,reuse,invalid}`. `APIClient` hands
    /// that over as `HLError.unauthorized`. Every other `4xx` is something
    /// else: a proxy or WAF answering in the server's place (`403`, `404`), a
    /// request this build shaped wrongly (`400`, `422`), a body too large for
    /// an intermediary (`413`). None of them is a verdict on the token, and a
    /// sign-out on any of them costs the user a session the server still
    /// honours. They are transient, like offline, timeout, 5xx and rate-limit.
    public static func classify(_ error: Error) -> RefreshOutcome {
        guard let hl = error as? HLError else { return .transient }
        // #191 — a lost refresh race is no verdict on the session.
        // `AuthService.refresh()` re-reads the stored pair first
        // (`adoptWinnerOfRefreshRace`); classified on its own it is transient.
        if isSuperseded(hl) { return .transient }
        switch hl {
        case .unauthorized:
            return .authFailure
        case let .server(status, code, _):
            if status == 401 { return .authFailure }
            // Named by the server as a refresh verdict, whatever the status.
            let namedVerdict = (400 ... 499).contains(status) && code?.hasPrefix("auth.refresh.") == true
            return namedVerdict ? .authFailure : .transient
        // KONTO (1.46.0) — `403 auth.account.deletion_pending`: the account is
        // locked for deletion, a verdict the server names explicitly.
        case .accountDeletionPending:
            return .authFailure
        // `.writeConflictUnresolved` is a CU-20 write-path verdict and can
        // never originate on the refresh route; classified transient so it
        // could never log the user out.
        // `.serverNotConfigured` heisst, dass gar keine Adresse hinterlegt
        // ist — kein Auth-Urteil. Transient, denn ein Logout waere die
        // falsche Antwort auf "noch nicht eingerichtet".
        // `.refusedWithReason` is likewise a domain verdict from a route that
        // is not this one: the promotion is opt-in per error code and no auth
        // code is on that list, so it can never mean "log the user out".
        // `.idempotencyReplayInFlight` is a write-route conflict
        // (the refresh leg carries no idempotency key), and it says "retry",
        // which is the definition of transient.
        case .network, .offline, .rateLimited, .canceled, .decoding,
             .aiUnavailable, .moduleDisabled, .notPersisted,
             .writeConflictUnresolved, .serverNotConfigured, .refusedWithReason,
             .idempotencyReplayInFlight, .unknown:
            return .transient
        }
    }
}
