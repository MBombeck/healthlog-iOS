import Foundation

/// The server's unified connection state (`ConnectionHealth`, since
/// server v1.42.4).
///
/// Every integration status read carries it: `GET /api/integrations/status`
/// per entry, the per-provider `GET /api/{withings,whoop,fitbit,google-health,
/// polar,oura,strava,nightscout}/status`, and the Apple Health read
/// `GET /api/integrations/healthkit`. It supersedes the legacy fields
/// (`state`, `lastError`, `consecutiveFailuresByKind`, `syncHealth`,
/// `tokenExpired`, `needsReauth`, `hasActivityScope`, `planUnavailable`,
/// `scopeReconnect`), which v1.43 marks deprecated and v1.44 removes.
///
/// **Render from `state` / `reason` / `action` only.** The app picks one
/// sentence per `reason` and offers at most one button for `action`; it never
/// derives its own state from the older fields.
///
/// **Tolerant on every field.** A word this build does not know becomes
/// ``State/unknown`` / ``Reason/unknown`` / no action, never a failed status
/// read. Callers decode the whole object with `try?` so a malformed `health`
/// reads as absent rather than breaking the integration card.
public struct ConnectionHealth: Codable, Sendable, Hashable {
    public let state: State
    public let reason: Reason
    /// When the current degraded / action_required condition started. Null for
    /// ok and limited.
    public let since: Date?
    /// The one action that resolves the state, or `nil` when nothing the user
    /// can do helps (or the server sent a word this build does not know).
    public let action: Action?
    /// Data types this connection cannot deliver. Empty when nothing is withheld.
    public let unavailable: [Unavailable]
    /// Last successful sync (Apple Health: the last accepted batch).
    public let lastSuccessAt: Date?
    /// Newest data this source delivered.
    public let lastDataAt: Date?

    public init(
        state: State,
        reason: Reason,
        since: Date? = nil,
        action: Action? = nil,
        unavailable: [Unavailable] = [],
        lastSuccessAt: Date? = nil,
        lastDataAt: Date? = nil
    ) {
        self.state = state
        self.reason = reason
        self.since = since
        self.action = action
        self.unavailable = unavailable
        self.lastSuccessAt = lastSuccessAt
        self.lastDataAt = lastDataAt
    }

    private enum CodingKeys: String, CodingKey {
        case state, reason, since, action, unavailable, lastSuccessAt, lastDataAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = State(wire: try? c.decodeIfPresent(String.self, forKey: .state))
        reason = Reason(wire: try? c.decodeIfPresent(String.self, forKey: .reason))
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        action = (try? c.decodeIfPresent(String.self, forKey: .action)).flatMap(Action.init(rawValue:))
        unavailable = (try? c.decodeIfPresent([Unavailable].self, forKey: .unavailable)) ?? []
        lastSuccessAt = try? c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastDataAt = try? c.decodeIfPresent(Date.self, forKey: .lastDataAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state.wireValue, forKey: .state)
        try c.encode(reason.wireValue, forKey: .reason)
        try c.encodeIfPresent(since, forKey: .since)
        try c.encodeIfPresent(action?.rawValue, forKey: .action)
        try c.encode(unavailable, forKey: .unavailable)
        try c.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
        try c.encodeIfPresent(lastDataAt, forKey: .lastDataAt)
    }

    /// `ok` | `limited` | `degraded` | `action_required`, plus a catch for a
    /// word this build does not know (shown neutral, never red).
    public enum State: Sendable, Hashable {
        case ok
        case limited
        case degraded
        case actionRequired
        case unknown(String)

        init(wire: String?) {
            switch wire {
            case "ok": self = .ok
            case "limited": self = .limited
            case "degraded": self = .degraded
            case "action_required": self = .actionRequired
            default: self = .unknown(wire ?? "")
            }
        }

        var wireValue: String {
            switch self {
            case .ok: "ok"
            case .limited: "limited"
            case .degraded: "degraded"
            case .actionRequired: "action_required"
            case let .unknown(raw): raw
            }
        }
    }

    /// One code per branch of the server's state derivation. The sentence is
    /// picked from this code alone.
    public enum Reason: Sendable, Hashable {
        case dataArriving
        case firstSyncPending
        case planLimited
        case permissionLimited
        case providerErrors
        case syncStalled
        case noNewData
        case unexpectedSilence
        case reauthRequired
        case pausedAfterErrors
        case unknown(String)

        init(wire: String?) {
            switch wire {
            case "data_arriving": self = .dataArriving
            case "first_sync_pending": self = .firstSyncPending
            case "plan_limited": self = .planLimited
            case "permission_limited": self = .permissionLimited
            case "provider_errors": self = .providerErrors
            case "sync_stalled": self = .syncStalled
            case "no_new_data": self = .noNewData
            case "unexpected_silence": self = .unexpectedSilence
            case "reauth_required": self = .reauthRequired
            case "paused_after_errors": self = .pausedAfterErrors
            default: self = .unknown(wire ?? "")
            }
        }

        var wireValue: String {
            switch self {
            case .dataArriving: "data_arriving"
            case .firstSyncPending: "first_sync_pending"
            case .planLimited: "plan_limited"
            case .permissionLimited: "permission_limited"
            case .providerErrors: "provider_errors"
            case .syncStalled: "sync_stalled"
            case .noNewData: "no_new_data"
            case .unexpectedSilence: "unexpected_silence"
            case .reauthRequired: "reauth_required"
            case .pausedAfterErrors: "paused_after_errors"
            case let .unknown(raw): raw
            }
        }
    }

    /// `reconnect` runs the provider's connect flow again; `resume` POSTs the
    /// provider's resume route.
    public enum Action: String, Sendable, Hashable {
        case reconnect
        case resume
    }

    /// One data type the connection cannot deliver, and why.
    public struct Unavailable: Codable, Sendable, Hashable {
        /// Provider data-type key, e.g. `spo2`, `vo2Max`, `activity`.
        public let item: String
        /// `plan` or `permission`; kept as text so a new word never drops the row.
        public let cause: String

        public init(item: String, cause: String) {
            self.item = item
            self.cause = cause
        }

        private enum CodingKeys: String, CodingKey {
            case item, cause
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            item = (try? c.decodeIfPresent(String.self, forKey: .item)) ?? ""
            cause = (try? c.decodeIfPresent(String.self, forKey: .cause)) ?? ""
        }
    }
}

public extension ConnectionHealth {
    /// Decodes `health` from a status object without ever failing it: absent,
    /// `null` and malformed all read as `nil` (a server before v1.42.4, or a
    /// shape this build cannot read).
    static func tolerant<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> ConnectionHealth? {
        try? container.decodeIfPresent(ConnectionHealth.self, forKey: key)
    }

    /// The connection is broken until the person reconnects.
    var needsReconnect: Bool {
        state == .actionRequired && action == .reconnect
    }

    /// The server paused syncing and the person can resume it.
    var canResume: Bool {
        action == .resume
    }
}
