import Foundation

/// Server-owned MCP connector surface (server v1.22.0). Wraps the five verbs
/// behind Settings → MCP:
///
/// - `GET    /api/mcp/connections`      — live OAuth connections (assistants).
/// - `DELETE /api/mcp/connections/:id`  — revoke one, killing its refresh chain.
/// - `GET    /api/mcp/tokens`           — manually-minted connector tokens.
/// - `POST   /api/mcp/tokens`           — mint one (raw secret returned ONCE).
/// - `DELETE /api/mcp/tokens/:id`       — revoke one.
///
/// **Why this exists (Build 2 / 2.7):** until now zero files in the iOS source
/// mentioned MCP, so a user could not see — let alone cut — an external
/// assistant's live connection to their health record from the device they
/// actually carry. Revocation is the security-critical half.
///
/// All five routes 403 when the operator has globally disabled the API, and the
/// whole surface additionally gates on the opt-in `mcp` module.
public actor McpRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    // MARK: - Connections (the revocation-critical half)

    /// Live connections only — the server filters `revokedAt: null`, so every
    /// row returned is an assistant with current read access.
    public func listConnections() async throws -> [McpConnectionDTO] {
        let req: APIRequest<[McpConnectionDTO]> = .get("/api/mcp/connections")
        return try await api.send(req)
    }

    /// Revoke a connection: stamps `revokedAt` and kills every access token it
    /// ever issued, so the whole refresh chain dies.
    ///
    /// A `404` is treated as success — the connection is already gone, which is
    /// precisely the state the caller asked for. Surfacing an error there would
    /// tell a user who just revoked from two devices that the revoke failed.
    public func revokeConnection(id: String) async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/mcp/connections/\(id)")
        do {
            try await api.sendVoid(req)
        } catch let HLError.server(status, _, _) where status == 404 {
            return
        }
    }

    // MARK: - Connector tokens

    /// Manually-minted `health:read` connector tokens. Transient OAuth access
    /// rows are deliberately excluded server-side — those surface as
    /// connections instead.
    public func listTokens() async throws -> [ApiTokenDTO] {
        let req: APIRequest<[ApiTokenDTO]> = .get("/api/mcp/tokens")
        return try await api.send(req)
    }

    /// Mint a connector token. The response carries the raw `hlk_…` secret
    /// **once** — it is unrecoverable afterwards, so the caller must surface it
    /// immediately and must never persist or log it.
    public func mintToken(name: String, scope: McpTokenScope) async throws -> ApiTokenMintResponse {
        let body = McpTokenMintBody(name: name, scope: scope)
        let req: APIRequest<ApiTokenMintResponse> = try .post("/api/mcp/tokens", body: body)
        return try await api.send(req)
    }

    /// Revoke a connector token. `404` treated as success (already gone).
    public func revokeToken(id: String) async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/mcp/tokens/\(id)")
        do {
            try await api.sendVoid(req)
        } catch let HLError.server(status, _, _) where status == 404 {
            return
        }
    }
}

/// Server-owned generic API tokens (`/api/tokens`).
///
/// **Read + revoke only, deliberately.** The generic mint (`POST /api/tokens`)
/// was REMOVED server-side: it issued a `["medication:ingest"]` token that
/// could never do its advertised job, because the external ingest surface gates
/// on the per-medication `medication:<id>:ingest` grant this route never
/// issued. The working credential is minted by the per-medication API-endpoint
/// toggle instead. Listing and revoking remain so pre-existing tokens stay
/// visible and — the point of Build 2 / 2.8 — revocable from the phone.
///
/// Adding a create button here would POST to a route that no longer exists.
public actor ApiTokenRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Every token on the account, revoked ones included (the server does not
    /// filter). The store splits them for display.
    public func list() async throws -> [ApiTokenDTO] {
        let req: APIRequest<[ApiTokenDTO]> = .get("/api/tokens")
        return try await api.send(req)
    }

    /// Revoke a token. `404` treated as success (already gone).
    public func revoke(id: String) async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/tokens/\(id)")
        do {
            try await api.sendVoid(req)
        } catch let HLError.server(status, _, _) where status == 404 {
            return
        }
    }
}
