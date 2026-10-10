import Foundation

/// One row of `GET /api/auth/me/sessions` (server `SessionDTO`, see
/// `src/app/api/auth/me/sessions/route.ts:28-36`).
///
/// **What this list actually contains — read before trusting the UI copy.**
/// The route enumerates `prisma.session` rows, i.e. **browser** logins. A
/// native iOS sign-in does NOT create a `Session` row: `finishLogin`
/// (`src/lib/auth/login-response.ts:66-101`) routes a cookie-less native caller
/// to `issueAccessAndRefresh`, which mints an `ApiToken` + a `RefreshToken` and
/// never touches `Session`. Consequences the surface must not lie about:
///
/// 1. An iOS-only account sees an **empty** list. That is correct, not a bug.
/// 2. `isCurrent` can never be `true` for an iOS caller. `requireAuth`'s Bearer
///    branch puts the *token* id in `session.id`
///    (`src/lib/api-handler.ts:356-358`), which is compared against `Session`
///    row ids — they are different id spaces, so the comparison never matches.
///    The screen therefore treats `isCurrent` as a best-effort marker and never
///    relies on "exactly one row is current".
///
/// Decode-tolerant on every nullable the server declares nullable, so a partial
/// deploy degrades to a blank secondary line rather than a thrown decode.
public struct SessionEntry: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    /// Coarse device label (`coarseDeviceLabel(userAgent)`), e.g. "Safari on
    /// macOS". Never the raw User-Agent.
    public let device: String
    /// Masked source IP (`maskIp`) — never the full address. Null when the
    /// server recorded no IP for the session.
    public let ipMasked: String?
    /// Coarse geo-resolution of the IP. Null when unresolvable or IP-less.
    public let location: String?
    /// Sliding last-activity stamp. Null for a session that has not been used
    /// since the column was introduced.
    public let lastActiveAt: Date?
    public let createdAt: Date
    /// Server-computed "this is the caller's own session". See the type doc —
    /// structurally always `false` for a native iOS caller.
    public let isCurrent: Bool

    public init(
        id: String,
        device: String,
        ipMasked: String? = nil,
        location: String? = nil,
        lastActiveAt: Date? = nil,
        createdAt: Date,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.device = device
        self.ipMasked = ipMasked
        self.location = location
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.isCurrent = isCurrent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? String(localized: "sessions.device.unknown")
        ipMasked = try c.decodeIfPresent(String.self, forKey: .ipMasked)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isCurrent = try c.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, device, ipMasked, location, lastActiveAt, createdAt, isCurrent
    }
}

public extension SessionEntry {
    /// Secondary row line: coarse location and masked IP, whichever the server
    /// actually supplied. Pure + `nonisolated` so the row layout is unit-testable
    /// without standing up the view tree (the `PasskeyEntry.deviceLabel`
    /// precedent).
    ///
    /// Order mirrors the web card (`security-sessions-card.tsx:139-189`):
    /// location first (the human-readable anchor), masked IP second (the
    /// forensic one). Returns `nil` when the server supplied neither, so the
    /// caller can omit the line entirely instead of painting an empty row.
    var locationLine: String? {
        let parts = [location, ipMasked].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The timestamp the row should date-stamp with: last activity when the
    /// server tracked it, otherwise the creation stamp. Pure — the view only
    /// applies `.relative(presentation: .named)` to the result.
    var effectiveActivityDate: Date {
        lastActiveAt ?? createdAt
    }

    /// Whether the date-stamp represents real activity (vs. a fallback to
    /// `createdAt`). Drives which of the two localized captions the row uses, so
    /// a session with no recorded activity is not mislabelled "last active".
    var hasRecordedActivity: Bool {
        lastActiveAt != nil
    }
}

/// Envelope payload of `GET /api/auth/me/sessions` — the route answers
/// `apiSuccess({ sessions: [...] })`, so the `data` member is an object with a
/// single `sessions` key, not a bare array.
public struct SessionListResponse: Decodable, Sendable, Equatable {
    public let sessions: [SessionEntry]

    public init(sessions: [SessionEntry]) {
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([SessionEntry].self, forKey: .sessions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
    }
}

/// Envelope payload of `DELETE /api/auth/me/sessions`.
///
/// `sessionsRevoked` counts only the deleted **`Session` rows** (browser
/// sign-ins); device logins are revoked too and not counted there, so the UI
/// must not present the number as "devices signed out".
///
/// R2 / #115 A7 — server v1.39.3 widened "sign out everywhere": the same call
/// now also revokes AI-assistant connections, every API token except the
/// caller's own access token, every clinician share link (unless
/// `?keepShareLinks=1`) and pending sharing invitations, and lists the accepted
/// access grants it deliberately left standing (`grantsKept`). Every field is
/// decoded tolerantly: an older server sends only `sessionsRevoked`, and a
/// malformed grant row is dropped rather than failing the whole answer (the
/// revoke has already happened when this decodes).
public struct SessionRevokeOthersResponse: Decodable, Sendable, Equatable {
    /// One accepted access grant the revoke left standing (server
    /// `{ id, account: { id, username, displayName }, access }`).
    public struct KeptGrant: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let username: String?
        public let displayName: String?
        public let access: String?

        public init(id: String, username: String? = nil, displayName: String? = nil, access: String? = nil) {
            self.id = id
            self.username = username
            self.displayName = displayName
            self.access = access
        }

        /// The name a person recognises: display name, else username.
        public var label: String? {
            for candidate in [displayName, username] {
                if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            if let account = try? c.nestedContainer(keyedBy: AccountKeys.self, forKey: .account) {
                username = try? account.decodeIfPresent(String.self, forKey: .username)
                displayName = try? account.decodeIfPresent(String.self, forKey: .displayName)
            } else {
                username = nil
                displayName = nil
            }
            access = try? c.decodeIfPresent(String.self, forKey: .access)
        }

        private enum CodingKeys: String, CodingKey {
            case id, account, access
        }

        private enum AccountKeys: String, CodingKey {
            case username, displayName
        }
    }

    public let sessionsRevoked: Int
    public let accessTokensRevoked: Int?
    public let connectorsRevoked: Int?
    public let shareLinksRevoked: Int?
    public let pendingInvitesRevoked: Int?
    public let grantsKept: [KeptGrant]

    public init(
        sessionsRevoked: Int,
        accessTokensRevoked: Int? = nil,
        connectorsRevoked: Int? = nil,
        shareLinksRevoked: Int? = nil,
        pendingInvitesRevoked: Int? = nil,
        grantsKept: [KeptGrant] = []
    ) {
        self.sessionsRevoked = sessionsRevoked
        self.accessTokensRevoked = accessTokensRevoked
        self.connectorsRevoked = connectorsRevoked
        self.shareLinksRevoked = shareLinksRevoked
        self.pendingInvitesRevoked = pendingInvitesRevoked
        self.grantsKept = grantsKept
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionsRevoked = (try? c.decodeIfPresent(Int.self, forKey: .sessionsRevoked)) ?? 0
        accessTokensRevoked = try? c.decodeIfPresent(Int.self, forKey: .accessTokensRevoked)
        connectorsRevoked = try? c.decodeIfPresent(Int.self, forKey: .connectorsRevoked)
        shareLinksRevoked = try? c.decodeIfPresent(Int.self, forKey: .shareLinksRevoked)
        pendingInvitesRevoked = try? c.decodeIfPresent(Int.self, forKey: .pendingInvitesRevoked)
        // Lossy per row: one malformed grant must not hide the others.
        let rows = (try? c.decodeIfPresent([LossyGrant].self, forKey: .grantsKept)) ?? []
        grantsKept = rows.compactMap(\.value)
    }

    private struct LossyGrant: Decodable {
        let value: KeptGrant?
        init(from decoder: Decoder) throws {
            value = try? KeptGrant(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionsRevoked, accessTokensRevoked, connectorsRevoked
        case shareLinksRevoked, pendingInvitesRevoked, grantsKept
    }
}
