import Foundation
@testable import HealthLog
import Testing

/// Decode + state-machine locks for the WHOOP integration surface
/// (`WhoopRepository` + `WhoopIntegrationStore`).
///
/// Two things this suite pins:
/// 1. `WhoopRepository` decodes the verbatim server shapes from the v1.11.0
///    contract (`status`, `credentials`, `test`) — a schema drift would surface
///    here, not as a silent "Not configured" in Settings.
/// 2. `WhoopIntegrationStore.stage` walks the BYO-key gate correctly:
///    `needsCredentials → needsConnect → connected`, driven off `configured`
///    (creds saved) AND `connected` (OAuth done), per the contract delta.
@MainActor
@Suite("WhoopIntegration")
struct WhoopIntegrationStoreTests {
    // MARK: - Stub APIClient

    /// Handler-based stub: each typed `send`/`sendVoid` invocation routes
    /// through one handler keyed by the request path, returning a decoded
    /// payload (or `()` for void) and capturing PUT/POST bodies.
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

    /// Captures the wire side: PUT/POST bodies + lets a test inject a per-call
    /// status / error. Strong-captured by the handler closures.
    @MainActor
    private final class Capture {
        var statusQueue: [WhoopStatus]
        var credentials = WhoopCredentialsStatus(hasCredentials: false)
        var testResult = WhoopTestResult(ok: true, lastSyncedAt: nil, latencyMs: 42)
        var putBodies: [Data] = []
        var voidPaths: [String] = []
        var errorOnNextSend: HLError?
        var errorOnNextVoid: HLError?

        init(initialStatus: WhoopStatus) {
            statusQueue = [initialStatus]
        }

        func sendHandler() -> @Sendable (any Sendable) async throws -> any Sendable {
            { req in
                if let err = await self.takeSendError() { throw err }
                if let r = req as? APIRequest<WhoopStatus> { _ = r
                    return await self.nextStatus()
                }
                if let r = req as? APIRequest<WhoopCredentialsStatus> { _ = r
                    return await self.credentials
                }
                if let r = req as? APIRequest<WhoopTestResult> { _ = r
                    return await self.testResult
                }
                if let r = req as? APIRequest<WhoopResumeResult> {
                    _ = r
                    return WhoopResumeResult(resumed: true, wasParked: false)
                }
                throw HLError.unknown("unexpected GET/POST shape: \(type(of: req))")
            }
        }

        func voidHandler() -> @Sendable (APIRequest<EmptyPayload>) async throws -> Void {
            { req in
                if let err = await self.takeVoidError() { throw err }
                await self.recordVoid(path: req.path, body: req.body)
            }
        }

        func nextStatus() -> WhoopStatus {
            if statusQueue.count > 1 { return statusQueue.removeFirst() }
            return statusQueue[0]
        }

        func recordVoid(path: String, body: Data?) {
            voidPaths.append(path)
            if let body { putBodies.append(body) }
        }

        func takeSendError() -> HLError? {
            defer { errorOnNextSend = nil }
            return errorOnNextSend
        }

        func takeVoidError() -> HLError? {
            defer { errorOnNextVoid = nil }
            return errorOnNextVoid
        }
    }

    @MainActor
    private final class ControlledConnector: WhoopConnecting {
        private(set) var didStart = false
        private var continuation: CheckedContinuation<WhoopConnectOutcome, Never>?

        func connect(connectURL _: URL) async -> WhoopConnectOutcome {
            didStart = true
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func complete(_ outcome: WhoopConnectOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private final class OwnerBox {
        var id: String?

        init(id: String?) {
            self.id = id
        }
    }

    private func makeStore(
        initialStatus: WhoopStatus,
        connector: WhoopConnecting? = nil,
        registry: AuthenticatedSessionLeaseRegistry? = nil,
        userIDProvider: @escaping @MainActor () -> String? = { nil }
    ) -> (WhoopIntegrationStore, Capture) {
        let stub = StubAPIClient()
        let capture = Capture(initialStatus: initialStatus)
        stub.sendHandler = capture.sendHandler()
        stub.voidHandler = capture.voidHandler()
        let repo = WhoopRepository(api: stub)
        let store = if let registry {
            WhoopIntegrationStore(
                repo: repo,
                connector: connector,
                baseURLProvider: { URL(string: "https://healthlog.example") },
                authenticatedSessionRegistry: registry,
                userIDProvider: userIDProvider
            )
        } else {
            WhoopIntegrationStore(
                repo: repo,
                connector: connector,
                baseURLProvider: { URL(string: "https://healthlog.example") }
            )
        }
        return (store, capture)
    }

    private func status(
        connected: Bool,
        configured: Bool? = nil,
        lastSyncedAt: Date? = nil,
        tokenExpired: Bool? = nil,
        scope: String? = nil
    ) -> WhoopStatus {
        WhoopStatus(
            connected: connected,
            configured: configured,
            lastSyncedAt: lastSyncedAt,
            connectedAt: nil,
            tokenExpired: tokenExpired,
            tokenExpiresAt: nil,
            backfillCompleted: nil,
            scope: scope
        )
    }

    // MARK: - Decode locks (verbatim server shapes)

    @Test("WhoopRepository decodes the not-connected status shape")
    func decodeNotConnected() throws {
        let json = Data(#"{ "connected": false, "configured": false }"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(WhoopStatus.self, from: json)
        #expect(decoded.connected == false)
        #expect(decoded.configured == false)
        #expect(decoded.lastSyncedAt == nil)
    }

    @Test("WhoopRepository decodes the full connected status shape")
    func decodeConnected() throws {
        let json = Data(#"""
        {
          "connected": true,
          "configured": true,
          "lastSyncedAt": "2026-06-04T08:30:00.000Z",
          "connectedAt": "2026-06-01T10:00:00.000Z",
          "tokenExpired": false,
          "tokenExpiresAt": "2026-06-10T10:00:00.000Z",
          "backfillCompleted": true,
          "scope": "read:recovery read:sleep read:cycles"
        }
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(WhoopStatus.self, from: json)
        #expect(decoded.connected == true)
        #expect(decoded.configured == true)
        #expect(decoded.backfillCompleted == true)
        #expect(decoded.scope == "read:recovery read:sleep read:cycles")
        #expect(decoded.lastSyncedAt != nil)
        #expect(decoded.tokenExpired == false)
    }

    @Test("WhoopRepository decodes credentials + test shapes")
    func decodeCredentialsAndTest() throws {
        let creds = try JSONDecoder.hlDefault.decode(
            WhoopCredentialsStatus.self,
            from: Data(#"{ "hasCredentials": true }"#.utf8)
        )
        #expect(creds.hasCredentials == true)

        let test = try JSONDecoder.hlDefault.decode(
            WhoopTestResult.self,
            from: Data(#"{ "ok": true, "lastSyncedAt": "2026-06-04T08:30:00.000Z", "latencyMs": 137 }"#.utf8)
        )
        #expect(test.ok == true)
        #expect(test.latencyMs == 137)
        #expect(test.lastSyncedAt != nil)
    }

    // MARK: - State machine

    @Test("stage is .loading before any status load")
    func stageLoadingInitially() {
        let (store, _) = makeStore(initialStatus: status(connected: false, configured: false))
        #expect(store.stage == .loading)
    }

    @Test("!configured → .needsCredentials")
    func stageNeedsCredentials() async {
        let (store, _) = makeStore(initialStatus: status(connected: false, configured: false))
        await store.loadStatus()
        #expect(store.stage == .needsCredentials)
    }

    @Test("configured && !connected → .needsConnect")
    func stageNeedsConnect() async {
        let (store, _) = makeStore(initialStatus: status(connected: false, configured: true))
        await store.loadStatus()
        #expect(store.stage == .needsConnect)
    }

    @Test("connected → .connected")
    func stageConnected() async {
        let (store, _) = makeStore(initialStatus: status(connected: true, configured: true, scope: "read:sleep"))
        await store.loadStatus()
        #expect(store.stage == .connected)
        #expect(store.status?.scope == "read:sleep")
    }

    @Test("connected + tokenExpired → .tokenExpired, not .connected")
    func stageTokenExpired() async {
        let (store, _) = makeStore(
            initialStatus: status(connected: true, configured: true, tokenExpired: true)
        )
        await store.loadStatus()
        // The status pill must NOT claim "Connected" while the OAuth token is
        // dead and nothing is flowing (A4 MEDIUM #1).
        #expect(store.stage == .tokenExpired)
    }

    @Test("rate_limited test result reveals the parked/resume affordance")
    func rateLimitedParkedAffordance() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        #expect(store.isRateLimitParked == false)
        capture.errorOnNextSend = .server(status: 429, code: "rate_limited", message: "slow down")
        await store.testConnection()
        #expect(store.isRateLimitParked, "rate_limited must arm the Resume affordance")
    }

    @Test("resume POSTs to the resume path, clears the parked signal, re-loads")
    func resumeUnparks() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        // Arm the parked signal first.
        capture.errorOnNextSend = .server(status: 429, code: "rate_limited_self", message: "self-limit")
        await store.testConnection()
        #expect(store.isRateLimitParked)
        // Resume un-parks; the healthy re-load clears the signal.
        await store.resume()
        #expect(
            capture.voidPaths.contains("/api/integrations/whoop/resume") == false,
            "resume is a typed POST, not a void POST"
        )
        #expect(store.isRateLimitParked == false)
        #expect(store.error == nil)
    }

    @Test("saveCredentials PUTs the body then advances the stage to .needsConnect")
    func saveCredentialsAdvancesStage() async throws {
        let (store, capture) = makeStore(initialStatus: status(connected: false, configured: false))
        await store.loadStatus()
        #expect(store.stage == .needsCredentials)

        // After save, the next status read reports configured.
        capture.statusQueue = [status(connected: false, configured: true)]
        await store.saveCredentials(clientId: "cid-123", clientSecret: "secret-xyz")

        #expect(store.stage == .needsConnect)
        let body = try #require(capture.putBodies.first)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["clientId"] as? String == "cid-123")
        #expect(decoded["clientSecret"] as? String == "secret-xyz")
    }

    @Test("removeCredentials DELETEs and falls back to .needsCredentials")
    func removeCredentialsResetsStage() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        #expect(store.stage == .connected)

        capture.statusQueue = [status(connected: false, configured: false)]
        await store.removeCredentials()
        #expect(store.stage == .needsCredentials)
        #expect(capture.voidPaths.contains("/api/whoop/credentials"))
    }

    @Test("testConnection stores the ok result")
    func connectionStoresResult() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        capture.testResult = WhoopTestResult(ok: true, lastSyncedAt: nil, latencyMs: 88)
        await store.testConnection()
        #expect(store.lastTestResult?.ok == true)
        #expect(store.lastTestResult?.latencyMs == 88)
        #expect(store.error == nil)
    }

    @Test("testConnection surfaces a mapped errorCode without clobbering status")
    func connectionSurfacesErrorCode() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        capture.errorOnNextSend = .server(status: 422, code: "not_configured", message: "no connection")
        await store.testConnection()
        #expect(store.lastTestResult == nil)
        if case let .server(_, code, _) = store.error {
            #expect(code == "not_configured")
        } else {
            Issue.record("Expected .server error with errorCode, got \(String(describing: store.error))")
        }
        // Status untouched.
        #expect(store.stage == .connected)
    }

    @Test("disconnect POSTs and re-loads status")
    func disconnectReloads() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        capture.statusQueue = [status(connected: false, configured: true)]
        await store.disconnect()
        #expect(store.stage == .needsConnect)
        #expect(capture.voidPaths.contains("/api/whoop/disconnect"))
    }

    @Test("syncNow POSTs to the sync path then re-loads")
    func syncNowPosts() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        await store.syncNow()
        #expect(capture.voidPaths.contains("/api/whoop/sync"))
        #expect(store.error == nil)
    }

    @Test("clearOnLogout wipes status, error and test result")
    func clearOnLogoutWipes() async {
        let (store, capture) = makeStore(initialStatus: status(connected: true, configured: true))
        await store.loadStatus()
        capture.testResult = WhoopTestResult(ok: true, lastSyncedAt: nil, latencyMs: 5)
        await store.testConnection()
        #expect(store.status != nil)
        store.clearOnLogout()
        #expect(store.status == nil)
        #expect(store.error == nil)
        #expect(store.lastTestResult == nil)
        #expect(store.stage == .loading)
    }

    @Test("late account A connect cannot publish into B")
    func lateAccountAConnectCannotPublishIntoB() async {
        let connector = ControlledConnector()
        let registry = AuthenticatedSessionLeaseRegistry()
        let owner = OwnerBox(id: "account-a")
        _ = registry.activate(ownerID: "account-a")
        let (store, _) = makeStore(
            initialStatus: status(connected: true, configured: true),
            connector: connector,
            registry: registry,
            userIDProvider: { owner.id }
        )

        let connect = Task { @MainActor in await store.connect() }
        while !connector.didStart {
            await Task.yield()
        }

        // Account A leaves while its web session is suspended. Its eventual
        // status reload must not repopulate the cleared/auth-replaced store.
        registry.invalidate()
        owner.id = "account-b"
        _ = registry.activate(ownerID: "account-b")
        store.clearOnLogout()
        connector.complete(.connected)
        await connect.value

        if store.status != nil || store.isWorking {
            Issue.record("EXPECTED_RED: late A WHOOP connect published into B")
        }
    }
}
