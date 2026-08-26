import Foundation

/// A minted bearer credential as listed by `GET /api/tokens` and
/// `GET /api/mcp/tokens`. **Both routes select the identical Prisma column
/// set**, so one DTO serves both surfaces:
///
/// ```
/// { id, name, permissions, lastUsedAt, expiresAt, createdAt, revoked }
/// ```
///
/// The raw secret is NEVER part of this shape — it exists exactly once, in the
/// mint response (``ApiTokenMintResponse``), and is unrecoverable afterwards.
///
/// **Decode-tolerant** (the house idiom): every field except `id` has a safe
/// fallback, so one unexpected row can never collapse the whole list and strand
/// the user without a revoke button. That matters more here than anywhere else
/// — this list IS the revocation surface. A row we cannot fully parse must
/// still render with a working revoke action.
public struct ApiTokenDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Granted scopes, e.g. `["health:read"]` or
    /// `["health:read", "health:write"]`. Never `["*"]` from these routes.
    public let permissions: [String]
    public let lastUsedAt: Date?
    public let expiresAt: Date?
    public let createdAt: Date?
    public let revoked: Bool

    public init(
        id: String,
        name: String = "",
        permissions: [String] = [],
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        createdAt: Date? = nil,
        revoked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.permissions = permissions
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.revoked = revoked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is the only hard requirement — without it there is nothing to
        // revoke, so a row lacking one is genuinely unusable.
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        permissions = (try? c.decode([String].self, forKey: .permissions)) ?? []
        lastUsedAt = try? c.decode(Date.self, forKey: .lastUsedAt)
        expiresAt = try? c.decode(Date.self, forKey: .expiresAt)
        createdAt = try? c.decode(Date.self, forKey: .createdAt)
        // An unparseable `revoked` defaults to `false` so the row stays visible
        // in the ACTIVE list — i.e. it keeps its revoke button. Defaulting to
        // `true` would hide a possibly-live credential.
        revoked = (try? c.decode(Bool.self, forKey: .revoked)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, permissions, lastUsedAt, expiresAt, createdAt, revoked
    }

    /// Whether the server-stated expiry has passed. A token can be un-revoked
    /// but expired; both mean "cannot be used", and the UI says so.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Live == neither revoked nor expired. The only state worth a prominent
    /// revoke button.
    public func isLive(now: Date = Date()) -> Bool {
        !revoked && !isExpired(now: now)
    }

    /// Display name, falling back to a non-empty placeholder so an unnamed
    /// token never renders as a blank, untappable-looking row.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Unnamed token") : trimmed
    }

    /// Whether this credential carries the MCP write scope. Drives the "can
    /// also write" warning badge — a user scanning the list should be able to
    /// spot the more dangerous grant without opening anything.
    public var grantsWrite: Bool {
        permissions.contains("health:write")
    }
}

/// The scope choice `POST /api/mcp/tokens` accepts. A **closed** two-value
/// enum server-side (`z.enum(["read", "read_write"])`) — the endpoint cannot be
/// coerced into minting a wildcard, and neither can this client.
public enum McpTokenScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `["health:read"]` — least privilege, the default.
    case read
    /// `["health:read", "health:write"]`. The write half stays audience-bound
    /// to `/mcp`; it never admits a REST write.
    case readWrite = "read_write"

    public var id: String {
        rawValue
    }

    /// The permission array the server will materialise for this choice. Used
    /// by tests to pin the client's understanding against the route.
    public var expectedPermissions: [String] {
        switch self {
        case .read: ["health:read"]
        case .readWrite: ["health:read", "health:write"]
        }
    }
}

/// `POST /api/mcp/tokens` body. `expiresInDays` is omitted so the server
/// applies its own 90-day default rather than the client inventing a policy.
public struct McpTokenMintBody: Encodable, Sendable, Equatable {
    public let name: String
    public let scope: McpTokenScope

    public init(name: String, scope: McpTokenScope = .read) {
        self.name = name
        self.scope = scope
    }
}

/// `POST /api/mcp/tokens` 201 response — the **only** time the raw secret is
/// ever transmitted. Shown once, then dropped from memory.
public struct ApiTokenMintResponse: Decodable, Sendable, Equatable {
    /// The raw `hlk_…` bearer. Never logged, never persisted.
    public let token: String
    public let name: String
    public let expiresAt: Date?

    public init(token: String, name: String = "", expiresAt: Date? = nil) {
        self.token = token
        self.name = name
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        expiresAt = try? c.decode(Date.self, forKey: .expiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case token, name, expiresAt
    }
}

/// An MCP OAuth **connection** — the revocable unit for a remote connector
/// (a third-party client) authorized through the OAuth
/// bridge. `GET /api/mcp/connections` lists only live ones (the server filters
/// `revokedAt: null`), so everything returned here is an assistant that can
/// read the record *right now*.
///
/// This is the security-critical half of the MCP surface: revoking a connection
/// terminates its whole refresh chain, unlike the transient 60-minute access
/// tokens it issues.
public struct McpConnectionDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Client-supplied display name from OAuth registration. **Untrusted
    /// third-party text** — render it as data, never as markup or instruction.
    public let clientName: String
    /// Space-separated granted scopes, e.g. `"health:read"`.
    public let scope: String
    public let createdAt: Date?
    public let lastUsedAt: Date?

    public init(
        id: String,
        clientName: String = "",
        scope: String = "",
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.clientName = clientName
        self.scope = scope
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        clientName = (try? c.decode(String.self, forKey: .clientName)) ?? ""
        scope = (try? c.decode(String.self, forKey: .scope)) ?? ""
        createdAt = try? c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try? c.decode(Date.self, forKey: .lastUsedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, clientName, scope, createdAt, lastUsedAt
    }

    /// Never render an empty client name — an unnamed connection must still be
    /// identifiable enough to revoke with confidence.
    public var displayName: String {
        let trimmed = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Unknown assistant") : trimmed
    }

    /// Individual scope tokens, for badge rendering.
    public var scopeTokens: [String] {
        scope.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Whether this live connection can write to the record.
    public var grantsWrite: Bool {
        scopeTokens.contains("health:write")
    }
}
