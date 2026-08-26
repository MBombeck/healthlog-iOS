import Foundation
@testable import HealthLog
import Testing

/// **Revocation behaviour of the MCP + API-token stores (Build 2 / 2.7 + 2.8).**
///
/// The invariants here are security invariants, not cosmetics: the user must be
/// able to see and cut live access even when parts of the surface are failing.
@Suite("MCP + API token stores — revocation invariants")
struct McpStoreRevocationTests {
    // MARK: - Stub

    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?
        var voidHandler: (@Sendable (APIRequest<EmptyPayload>) async throws -> Void)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch — got \(type(of: result)), expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            try await voidHandler?(request)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    /// Mutable, main-actor-isolated fixture the stub handlers read through.
    @MainActor
    private final class Capture {
        var connections: [McpConnectionDTO] = []
        var tokens: [ApiTokenDTO] = []
        var connectionsError: HLError?
        var tokensError: HLError?
        var voidError: HLError?
        var voidPaths: [String] = []

        func sendHandler() -> @Sendable (any Sendable) async throws -> any Sendable {
            { req in
                switch req {
                case is APIRequest<[McpConnectionDTO]>:
                    if let err = await self.connectionsError { throw err }
                    return await self.connections
                case is APIRequest<[ApiTokenDTO]>:
                    if let err = await self.tokensError { throw err }
                    return await self.tokens
                default:
                    throw HLError.unknown("unexpected shape: \(type(of: req))")
                }
            }
        }

        func voidHandler() -> @Sendable (APIRequest<EmptyPayload>) async throws -> Void {
            { req in
                await self.record(path: req.path)
                if let err = await self.voidError { throw err }
            }
        }

        func record(path: String) {
            voidPaths.append(path)
        }
    }

    @MainActor
    private func makeMcpStore(_ capture: Capture) -> McpStore {
        let api = StubAPIClient()
        api.sendHandler = capture.sendHandler()
        api.voidHandler = capture.voidHandler()
        return McpStore(repo: McpRepository(api: api))
    }

    // MARK: - The invariant that matters most

    @Test("A failing TOKEN list never blanks the CONNECTION list")
    @MainActor
    func tokenFailureDoesNotHideConnections() async {
        // A blank connection list reads as "nobody has access" — the most
        // dangerous lie this screen could tell. An unrelated token-endpoint
        // failure must not produce it.
        let capture = Capture()
        capture.connections = [McpConnectionDTO(id: "c1", clientName: "Desktop dashboard", scope: "health:read")]
        capture.tokensError = .server(status: 500, code: nil, message: "boom")

        let store = makeMcpStore(capture)
        await store.load()

        #expect(store.connections.count == 1, "connections must survive a token-endpoint failure")
        #expect(store.connections.first?.displayName == "Desktop dashboard")
        #expect(store.tokens.isEmpty)
        #expect(store.error != nil, "the failure is still reported honestly")
    }

    @Test("A failing CONNECTION list still surfaces the tokens it could load")
    @MainActor
    func connectionFailureDoesNotHideTokens() async {
        let capture = Capture()
        capture.connectionsError = .server(status: 500, code: nil, message: "boom")
        capture.tokens = [ApiTokenDTO(id: "t1", name: "Laptop", permissions: ["health:read"])]

        let store = makeMcpStore(capture)
        await store.load()

        #expect(store.tokens.count == 1)
        #expect(store.connections.isEmpty)
        #expect(store.error != nil)
    }

    @Test("Revoking a connection DELETEs the right path and drops the row")
    @MainActor
    func revokeConnectionHitsCorrectPath() async {
        let capture = Capture()
        capture.connections = [
            McpConnectionDTO(id: "c1", clientName: "Desktop dashboard"),
            McpConnectionDTO(id: "c2", clientName: "Research client")
        ]
        let store = makeMcpStore(capture)
        await store.load()
        #expect(store.connections.count == 2)

        await store.revokeConnection(id: "c1")

        #expect(capture.voidPaths == ["/api/mcp/connections/c1"])
        #expect(store.connections.map(\.id) == ["c2"], "the revoked assistant disappears immediately")
        #expect(store.error == nil)
    }

    @Test("A failed connection revoke restores the row rather than faking success")
    @MainActor
    func failedRevokeRestoresRow() async {
        // Optimistically hiding a connection we did NOT actually cut would tell
        // the user they are safe when they are not.
        let capture = Capture()
        capture.connections = [McpConnectionDTO(id: "c1", clientName: "Desktop dashboard")]
        capture.voidError = .server(status: 500, code: nil, message: "boom")

        let store = makeMcpStore(capture)
        await store.load()
        await store.revokeConnection(id: "c1")

        #expect(store.connections.count == 1, "a failed revoke must put the connection back")
        #expect(store.error != nil, "and say so")
    }

    @Test("A 404 on revoke counts as success — it is already gone")
    @MainActor
    func revoke404IsSuccess() async {
        let capture = Capture()
        capture.connections = [McpConnectionDTO(id: "c1", clientName: "Desktop dashboard")]
        capture.voidError = .server(status: 404, code: nil, message: "Connection not found")

        let store = makeMcpStore(capture)
        await store.load()
        await store.revokeConnection(id: "c1")

        #expect(store.connections.isEmpty)
        #expect(store.error == nil, "already-revoked is the state the user asked for")
    }

    @Test("Revoking a token DELETEs the MCP token path")
    @MainActor
    func revokeTokenHitsCorrectPath() async {
        let capture = Capture()
        capture.tokens = [ApiTokenDTO(id: "t1", name: "Laptop")]
        let store = makeMcpStore(capture)
        await store.load()

        await store.revokeToken(id: "t1")
        #expect(capture.voidPaths == ["/api/mcp/tokens/t1"])
    }

    // MARK: - Minting

    @Test("Minting rejects an empty or whitespace-only name without a network hop")
    @MainActor
    func mintRejectsBlankName() async {
        let capture = Capture()
        let store = makeMcpStore(capture)

        let emptyResult = await store.mintToken(name: "", scope: .read)
        let blankResult = await store.mintToken(name: "   ", scope: .read)
        #expect(emptyResult == false)
        #expect(blankResult == false)
        #expect(store.freshToken == nil)
    }

    @Test("The fresh secret clears on dismissal and on logout")
    @MainActor
    func freshTokenClears() async {
        let capture = Capture()
        capture.connections = [McpConnectionDTO(id: "c1")]
        let store = makeMcpStore(capture)
        await store.load()

        store.clearFreshToken()
        #expect(store.freshToken == nil)

        store.clearOnLogout()
        #expect(store.connections.isEmpty, "no connection list may outlive the session")
        #expect(store.tokens.isEmpty)
        #expect(store.freshToken == nil)
    }

    // MARK: - Active / inactive split

    @Test("Only live tokens land in the active list")
    @MainActor
    func activeSplitExcludesRevokedAndExpired() async {
        let past = Date(timeIntervalSinceNow: -3600)
        let future = Date(timeIntervalSinceNow: 3600)
        let capture = Capture()
        capture.tokens = [
            ApiTokenDTO(id: "live", name: "Live", expiresAt: future, revoked: false),
            ApiTokenDTO(id: "revoked", name: "Revoked", expiresAt: future, revoked: true),
            ApiTokenDTO(id: "expired", name: "Expired", expiresAt: past, revoked: false)
        ]
        let store = makeMcpStore(capture)
        await store.load()

        #expect(store.activeTokens.map(\.id) == ["live"])
        #expect(Set(store.inactiveTokens.map(\.id)) == ["revoked", "expired"])
    }
}

@Suite("ApiTokenStore — list + revoke")
struct ApiTokenStoreTests {
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?
        var voidHandler: (@Sendable (APIRequest<EmptyPayload>) async throws -> Void)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch — got \(type(of: result)), expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            try await voidHandler?(request)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    @MainActor
    private final class Capture {
        var tokens: [ApiTokenDTO] = []
        var voidPaths: [String] = []

        func sendHandler() -> @Sendable (any Sendable) async throws -> any Sendable {
            { _ in await self.tokens }
        }

        func voidHandler() -> @Sendable (APIRequest<EmptyPayload>) async throws -> Void {
            { req in await self.record(path: req.path) }
        }

        func record(path: String) {
            voidPaths.append(path)
        }
    }

    @Test("Revoking hits /api/tokens/:id and refreshes the list")
    @MainActor
    func revokeHitsGenericTokenPath() async {
        let capture = Capture()
        capture.tokens = [ApiTokenDTO(id: "t1", name: "Leaked")]
        let api = StubAPIClient()
        api.sendHandler = capture.sendHandler()
        api.voidHandler = capture.voidHandler()
        let store = ApiTokenStore(repo: ApiTokenRepository(api: api))

        await store.load()
        #expect(store.activeTokens.count == 1)

        // Simulate the server marking it revoked, as the reload would observe.
        capture.tokens = [ApiTokenDTO(id: "t1", name: "Leaked", revoked: true)]
        await store.revoke(id: "t1")

        #expect(capture.voidPaths == ["/api/tokens/t1"])
        #expect(store.activeTokens.isEmpty, "the revoked token leaves the active list")
        #expect(store.inactiveTokens.count == 1, "but stays visible as revoked")
        #expect(store.error == nil)
    }
}
