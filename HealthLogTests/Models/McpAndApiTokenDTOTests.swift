import Foundation
@testable import HealthLog
import Testing

/// **MCP + API-token wire contract (Build 2 / 2.7 + 2.8).**
///
/// These DTOs back the surface a user reaches for when they want to cut an
/// external assistant's access to their health record. A decode that throws on
/// one odd row would blank the list — and a blank list looks exactly like
/// "nothing has access", which is the most dangerous lie this screen could
/// tell. So the decode is deliberately tolerant, and these tests pin that.
@Suite("MCP connections + tokens — wire decode")
struct McpConnectionDecodeTests {
    @Test("Full connection row decodes")
    func fullConnectionDecodes() throws {
        let json = Data("""
        {
          "id": "conn-1",
          "clientName": "Desktop dashboard",
          "scope": "health:read",
          "createdAt": "2026-07-01T08:00:00.000Z",
          "lastUsedAt": "2026-07-18T19:30:00.000Z"
        }
        """.utf8)
        let conn = try JSONDecoder.hlDefault.decode(McpConnectionDTO.self, from: json)
        #expect(conn.id == "conn-1")
        #expect(conn.clientName == "Desktop dashboard")
        #expect(conn.displayName == "Desktop dashboard")
        #expect(conn.scopeTokens == ["health:read"])
        #expect(!conn.grantsWrite)
        #expect(conn.createdAt != nil)
        #expect(conn.lastUsedAt != nil)
    }

    @Test("Tolerant decode: only an id still yields a usable, revocable row")
    func minimalConnectionDecodes() throws {
        // The row must survive, because `id` is all the revoke call needs.
        let json = Data(#"{"id":"conn-min"}"#.utf8)
        let conn = try JSONDecoder.hlDefault.decode(McpConnectionDTO.self, from: json)
        #expect(conn.id == "conn-min")
        #expect(conn.clientName.isEmpty)
        #expect(conn.displayName == String(localized: "Unknown assistant"), "never render a blank row")
        #expect(conn.scopeTokens.isEmpty)
        #expect(conn.lastUsedAt == nil)
    }

    @Test("Explicit nulls decode to nil, not a throw")
    func explicitNullsDecode() throws {
        let json = Data("""
        {"id":"conn-null","clientName":null,"scope":null,"createdAt":null,"lastUsedAt":null}
        """.utf8)
        let conn = try JSONDecoder.hlDefault.decode(McpConnectionDTO.self, from: json)
        #expect(conn.lastUsedAt == nil)
        #expect(conn.createdAt == nil)
        #expect(conn.displayName == String(localized: "Unknown assistant"))
    }

    @Test("A wrong-typed field degrades that field only — the row still revokes")
    func wrongTypedFieldDegrades() throws {
        // A server bug (or a future shape change) must not cost the user their
        // ability to cut this connection.
        let json = Data(#"{"id":"conn-odd","clientName":42,"scope":["health:read"]}"#.utf8)
        let conn = try JSONDecoder.hlDefault.decode(McpConnectionDTO.self, from: json)
        #expect(conn.id == "conn-odd")
        #expect(conn.clientName.isEmpty, "unparseable name degrades to empty, not a throw")
        #expect(conn.scope.isEmpty)
    }

    @Test("A row without an id is the ONE genuine failure")
    func missingIdThrows() {
        let json = Data(#"{"clientName":"Ghost"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder.hlDefault.decode(McpConnectionDTO.self, from: json)
        }
    }

    @Test("One bad row does not collapse the whole connection list")
    func listSurvivesOddRow() throws {
        let json = Data("""
        {"data":[
          {"id":"a","clientName":"Desktop dashboard","scope":"health:read"},
          {"id":"b","clientName":null,"scope":null},
          {"id":"c","clientName":"Research client","scope":"health:read health:write"}
        ]}
        """.utf8)
        struct Env: Decodable { let data: [McpConnectionDTO] }
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: json).data
        #expect(list.count == 3, "every connection must stay revocable")
        #expect(list[2].grantsWrite, "write scope must be visible to the user")
        #expect(list[0].grantsWrite == false)
    }

    @Test("Write scope is detected from a space-separated scope string")
    func writeScopeDetected() {
        let readOnly = McpConnectionDTO(id: "r", scope: "health:read")
        let readWrite = McpConnectionDTO(id: "w", scope: "health:read health:write")
        #expect(!readOnly.grantsWrite)
        #expect(readWrite.grantsWrite)
        #expect(readWrite.scopeTokens == ["health:read", "health:write"])
    }

    @Test("Scope splitting tolerates padding without emitting empty tokens")
    func scopeSplittingIgnoresPadding() {
        let padded = McpConnectionDTO(id: "p", scope: "  health:read   health:write  ")
        #expect(padded.scopeTokens == ["health:read", "health:write"])
    }
}

@Suite("API + MCP tokens — wire decode and state")
struct ApiTokenDecodeTests {
    @Test("Full token row decodes")
    func fullTokenDecodes() throws {
        let json = Data("""
        {
          "id": "tok-1",
          "name": "Laptop",
          "permissions": ["health:read"],
          "lastUsedAt": "2026-07-18T10:00:00.000Z",
          "expiresAt": "2026-10-01T00:00:00.000Z",
          "createdAt": "2026-07-01T00:00:00.000Z",
          "revoked": false
        }
        """.utf8)
        let token = try JSONDecoder.hlDefault.decode(ApiTokenDTO.self, from: json)
        #expect(token.id == "tok-1")
        #expect(token.displayName == "Laptop")
        #expect(token.permissions == ["health:read"])
        #expect(!token.revoked)
        #expect(!token.grantsWrite)
    }

    @Test("Tolerant decode: only an id still yields a revocable row")
    func minimalTokenDecodes() throws {
        let json = Data(#"{"id":"tok-min"}"#.utf8)
        let token = try JSONDecoder.hlDefault.decode(ApiTokenDTO.self, from: json)
        #expect(token.id == "tok-min")
        #expect(token.permissions.isEmpty)
        #expect(!token.revoked, "an unknown revoked-state must default to NOT-revoked")
        #expect(token.displayName == String(localized: "Unnamed token"))
    }

    @Test("An unparseable revoked flag keeps the token visible and revocable")
    func unparseableRevokedStaysActive() throws {
        // Defaulting the other way would HIDE a possibly-live credential from
        // the only screen that can kill it.
        let json = Data(#"{"id":"tok-odd","revoked":"maybe"}"#.utf8)
        let token = try JSONDecoder.hlDefault.decode(ApiTokenDTO.self, from: json)
        #expect(!token.revoked)
        #expect(token.isLive(), "must remain in the active list, which is where revoke lives")
    }

    @Test("A row without an id is the ONE genuine failure")
    func missingIdThrows() {
        let json = Data(#"{"name":"Ghost"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder.hlDefault.decode(ApiTokenDTO.self, from: json)
        }
    }

    @Test("One bad row does not collapse the whole token list")
    func listSurvivesOddRow() throws {
        let json = Data("""
        {"data":[
          {"id":"a","name":"One","permissions":["health:read"],"revoked":false},
          {"id":"b","name":null,"permissions":null,"revoked":null},
          {"id":"c","name":"Three","permissions":["health:read","health:write"],"revoked":true}
        ]}
        """.utf8)
        struct Env: Decodable { let data: [ApiTokenDTO] }
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: json).data
        #expect(list.count == 3)
        #expect(list[1].displayName == String(localized: "Unnamed token"))
        #expect(list[2].revoked)
        #expect(list[2].grantsWrite)
    }

    @Test("isLive: revoked or expired both read as not-live")
    func liveStateResolution() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-3600)
        let future = now.addingTimeInterval(3600)

        let live = ApiTokenDTO(id: "1", expiresAt: future, revoked: false)
        let revoked = ApiTokenDTO(id: "2", expiresAt: future, revoked: true)
        let expired = ApiTokenDTO(id: "3", expiresAt: past, revoked: false)
        let never = ApiTokenDTO(id: "4", expiresAt: nil, revoked: false)

        #expect(live.isLive(now: now))
        #expect(!revoked.isLive(now: now))
        #expect(!expired.isLive(now: now))
        #expect(expired.isExpired(now: now))
        #expect(never.isLive(now: now), "no expiry means it never expires on its own")
        #expect(!never.isExpired(now: now))
    }

    @Test("An expiry exactly at now counts as expired")
    func expiryBoundaryIsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let boundary = ApiTokenDTO(id: "b", expiresAt: now, revoked: false)
        #expect(boundary.isExpired(now: now), "the boundary must not be treated as still-valid")
        #expect(!boundary.isLive(now: now))
    }

    @Test("A whitespace-only name still renders a placeholder")
    func whitespaceNameFallsBack() {
        let token = ApiTokenDTO(id: "w", name: "   ")
        #expect(token.displayName == String(localized: "Unnamed token"))
    }

    @Test("grantsWrite reflects the health:write permission")
    func grantsWriteDetection() {
        #expect(!ApiTokenDTO(id: "r", permissions: ["health:read"]).grantsWrite)
        #expect(ApiTokenDTO(id: "w", permissions: ["health:read", "health:write"]).grantsWrite)
        #expect(!ApiTokenDTO(id: "n", permissions: []).grantsWrite)
    }
}

@Suite("MCP token mint — request body + show-once response")
struct McpTokenMintTests {
    @Test("Mint body encodes the closed scope enum as the server's wire values")
    func mintBodyEncodesScope() throws {
        let read = McpTokenMintBody(name: "Laptop", scope: .read)
        let readJSON = try #require(String(bytes: JSONEncoder.hlDefault.encode(read), encoding: .utf8))
        #expect(readJSON.contains("\"scope\":\"read\""))
        #expect(readJSON.contains("\"name\":\"Laptop\""))
        #expect(!readJSON.contains("read_write"))

        let write = McpTokenMintBody(name: "Desktop", scope: .readWrite)
        let writeJSON = try #require(String(bytes: JSONEncoder.hlDefault.encode(write), encoding: .utf8))
        #expect(writeJSON.contains("\"scope\":\"read_write\""))
    }

    @Test("The body never carries an expiry — the server owns that policy")
    func mintBodyOmitsExpiry() throws {
        let body = McpTokenMintBody(name: "X", scope: .read)
        let json = try #require(String(bytes: JSONEncoder.hlDefault.encode(body), encoding: .utf8))
        #expect(!json.contains("expiresInDays"), "the client must not invent an expiry policy")
    }

    @Test("Scope enum is closed to exactly the two server-accepted shapes")
    func scopeEnumIsClosed() {
        #expect(McpTokenScope.allCases.count == 2)
        #expect(McpTokenScope(rawValue: "read") == .read)
        #expect(McpTokenScope(rawValue: "read_write") == .readWrite)
        // A wildcard or any other grant is not representable.
        #expect(McpTokenScope(rawValue: "*") == nil)
        #expect(McpTokenScope(rawValue: "admin") == nil)
        #expect(McpTokenScope.read.expectedPermissions == ["health:read"])
        #expect(McpTokenScope.readWrite.expectedPermissions == ["health:read", "health:write"])
    }

    @Test("Mint response carries the raw secret once")
    func mintResponseDecodes() throws {
        let json = Data("""
        {"token":"hlk_abc123","name":"Laptop","expiresAt":"2026-10-01T00:00:00.000Z"}
        """.utf8)
        let minted = try JSONDecoder.hlDefault.decode(ApiTokenMintResponse.self, from: json)
        #expect(minted.token == "hlk_abc123")
        #expect(minted.name == "Laptop")
        #expect(minted.expiresAt != nil)
    }

    @Test("Mint response tolerates a missing name and expiry")
    func mintResponseMinimal() throws {
        let json = Data(#"{"token":"hlk_only"}"#.utf8)
        let minted = try JSONDecoder.hlDefault.decode(ApiTokenMintResponse.self, from: json)
        #expect(minted.token == "hlk_only")
        #expect(minted.expiresAt == nil)
    }

    @Test("A mint response without a token is a genuine failure")
    func mintResponseWithoutTokenThrows() {
        // Silently succeeding here would show the user an empty "copy this"
        // box and let them believe a credential exists.
        let json = Data(#"{"name":"Laptop"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder.hlDefault.decode(ApiTokenMintResponse.self, from: json)
        }
    }
}
