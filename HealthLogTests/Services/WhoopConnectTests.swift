import Foundation
@testable import HealthLog
import Testing

/// Locks for the WHOOP **connect-in-app** delta (FW5-B):
/// 1. `WhoopConnectOutcome` parses the server's web-redirect query
///    (`whoop=connected` / `whoop=error&reason=…`) and stays silent on cancel.
/// 2. `SaveCredentialsBody` encodes the BYO-key body verbatim AND the
///    `clientSecret` never leaks through a log path (`LogSanitizer` + no
///    `description` conformance) — the ntfy/Telegram botToken doctrine.
/// 3. `WhoopIntegrationStore.connect()` walks the state machine: a `connected`
///    redirect + a status re-read advances to `.connected`; an `error` redirect
///    surfaces the mapped reason; cancel stays quiet and re-reads status.
@MainActor
@Suite("WhoopConnect")
struct WhoopConnectTests {
    // MARK: - 1. Redirect query parsing

    @Test("parses whoop=connected as .connected")
    func parsesConnected() throws {
        let url = try #require(URL(string: "https://healthlog.example/settings/integrations?whoop=connected"))
        #expect(WhoopConnectOutcome.from(callbackURL: url) == .connected)
    }

    @Test("parses whoop=error&reason=… as .failed(reason)")
    func parsesErrorReason() throws {
        let url = try #require(URL(string: "https://healthlog.example/settings/integrations?whoop=error&reason=rate_limited"))
        #expect(WhoopConnectOutcome.from(callbackURL: url) == .failed(reason: "rate_limited"))
    }

    @Test("parses whoop=error with no reason as .failed(reason: \"\")")
    func parsesErrorNoReason() throws {
        let url = try #require(URL(string: "https://healthlog.example/settings/integrations?whoop=error"))
        #expect(WhoopConnectOutcome.from(callbackURL: url) == .failed(reason: ""))
    }

    @Test("a URL with no whoop query item is inconclusive (nil)")
    func parsesInconclusive() throws {
        let url = try #require(URL(string: "https://healthlog.example/settings/integrations"))
        #expect(WhoopConnectOutcome.from(callbackURL: url) == nil)
        let other = try #require(URL(string: "https://healthlog.example/settings/integrations?foo=bar"))
        #expect(WhoopConnectOutcome.from(callbackURL: other) == nil)
    }

    @Test("an unknown whoop value is inconclusive (nil), not a false success")
    func parsesUnknownValue() throws {
        let url = try #require(URL(string: "https://healthlog.example/settings/integrations?whoop=maybe"))
        #expect(WhoopConnectOutcome.from(callbackURL: url) == nil)
    }

    @Test("rate_limited reason maps to a friendly retry message; unknown falls back")
    func mapsErrorMessages() {
        #expect(WhoopConnectOutcome.failed(reason: "rate_limited").userFacingMessage != nil)
        #expect(WhoopConnectOutcome.failed(reason: "totally_unknown").userFacingMessage != nil)
        // Success + cancel carry no surfaced message.
        #expect(WhoopConnectOutcome.connected.userFacingMessage == nil)
        #expect(WhoopConnectOutcome.canceled.userFacingMessage == nil)
    }

    // MARK: - 2. Credentials DTO encode + secret-not-logged guard

    @Test("SaveCredentialsBody encodes both fields verbatim")
    func credentialsBodyEncodes() throws {
        let body = WhoopRepository.SaveCredentialsBody(
            clientId: "cid-abc",
            clientSecret: "whoop_secret_value_xyz"
        )
        let data = try JSONEncoder().encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["clientId"] as? String == "cid-abc")
        #expect(json["clientSecret"] as? String == "whoop_secret_value_xyz")
        #expect(json.keys.count == 2, "body carries exactly clientId + clientSecret")
    }

    @Test("a realistic WHOOP client secret is redacted by LogSanitizer")
    func clientSecretRedacted() {
        // WHOOP developer secrets are long opaque tokens (≥32 hex/base64 chars) —
        // above the LogSanitizer token floor, so an accidental log emission is
        // scrubbed as defence-in-depth (same doctrine as the ntfy/Telegram
        // botToken + LLM-key guards).
        let secret = "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0"
        let line = LogSanitizer.redact("PUT /api/whoop/credentials secret=\(secret)")
        #expect(!line.contains(secret), "client secret must not survive redaction")
        #expect(line.contains("[redacted-token]"))
    }

    @Test("even an accidentally-interpolated credentials body is scrubbed by the redactor")
    func credentialsBodyInterpolationIsScrubbed() {
        // Contract: no log path interpolates `SaveCredentialsBody` — but as
        // defence-in-depth, IF some future path did, the redactor must neutralize
        // a realistic (long, opaque) secret. We prove the redactor catches the
        // secret inside the default struct interpolation.
        let secret = "wh00psecret_aaaaaaaaaaaaaaaaaaaaaaaaaaaa_bbbb"
        let body = WhoopRepository.SaveCredentialsBody(clientId: "cid-abc", clientSecret: secret)
        let redacted = LogSanitizer.redact("\(body)")
        #expect(!redacted.contains(secret), "an interpolated long client secret must not survive redaction")
    }

    // MARK: - 3. Store connect() state machine

    /// Minimal status-only stub: every `status()` read returns the head of a
    /// scriptable queue; void POSTs are accepted no-op.
    private final class StatusStub: APIClientProtocol, @unchecked Sendable {
        let queue: StatusQueue
        init(queue: StatusQueue) {
            self.queue = queue
        }

        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            let next = await queue.next()
            guard let typed = next as? T else {
                throw HLError.decoding("type mismatch — expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    /// MainActor box for the scripted status responses.
    @MainActor
    private final class StatusQueue {
        private var statuses: [WhoopStatus]
        init(_ statuses: [WhoopStatus]) {
            self.statuses = statuses
        }

        func next() -> WhoopStatus {
            if statuses.count > 1 { return statuses.removeFirst() }
            return statuses[0]
        }

        func set(_ statuses: [WhoopStatus]) {
            self.statuses = statuses
        }
    }

    @MainActor
    private final class StubConnector: WhoopConnecting {
        let outcome: WhoopConnectOutcome
        private(set) var capturedURL: URL?
        init(outcome: WhoopConnectOutcome) {
            self.outcome = outcome
        }

        func connect(connectURL: URL) async -> WhoopConnectOutcome {
            capturedURL = connectURL
            return outcome
        }
    }

    private func notConnected(configured: Bool) -> WhoopStatus {
        WhoopStatus(
            connected: false, configured: configured, lastSyncedAt: nil,
            connectedAt: nil, tokenExpired: nil, tokenExpiresAt: nil,
            backfillCompleted: nil, scope: nil
        )
    }

    private func connectedStatus() -> WhoopStatus {
        WhoopStatus(
            connected: true, configured: true, lastSyncedAt: nil,
            connectedAt: nil, tokenExpired: nil, tokenExpiresAt: nil,
            backfillCompleted: nil, scope: "read:sleep"
        )
    }

    private func makeStore(
        queue: StatusQueue,
        outcome: WhoopConnectOutcome,
        baseURL: URL? = URL(string: "https://healthlog.example")
    ) -> (WhoopIntegrationStore, StubConnector) {
        let repo = WhoopRepository(api: StatusStub(queue: queue))
        let connector = StubConnector(outcome: outcome)
        let store = WhoopIntegrationStore(repo: repo, connector: connector, baseURLProvider: { baseURL })
        return (store, connector)
    }

    @Test("connect opens /api/whoop/connect itself as the session start URL")
    func connectOpensConnectEndpoint() async {
        let queue = StatusQueue([notConnected(configured: true)])
        let (store, connector) = makeStore(queue: queue, outcome: .canceled)
        await store.loadStatus()
        await store.connect()
        #expect(connector.capturedURL?.absoluteString == "https://healthlog.example/api/whoop/connect")
    }

    @Test("connect → .connected + status re-read advances to .connected")
    func connectSuccessAdvancesStage() async {
        let queue = StatusQueue([notConnected(configured: true)])
        let (store, _) = makeStore(queue: queue, outcome: .connected)
        await store.loadStatus()
        #expect(store.stage == .needsConnect)
        queue.set([connectedStatus()])
        await store.connect()
        #expect(store.stage == .connected)
        #expect(store.error == nil)
    }

    @Test("connect → error surfaces the mapped reason, stays not-connected")
    func connectErrorSurfacesReason() async {
        let queue = StatusQueue([notConnected(configured: true)])
        let (store, _) = makeStore(queue: queue, outcome: .failed(reason: "rate_limited"))
        await store.loadStatus()
        await store.connect()
        #expect(store.stage == .needsConnect)
        if case let .server(_, code, _) = store.error {
            #expect(code == "rate_limited")
        } else {
            Issue.record("Expected a .server error carrying the connect reason, got \(String(describing: store.error))")
        }
    }

    @Test("connect → cancel stays quiet and re-reads status")
    func connectCancelIsQuiet() async {
        let queue = StatusQueue([notConnected(configured: true)])
        let (store, _) = makeStore(queue: queue, outcome: .canceled)
        await store.loadStatus()
        await store.connect()
        #expect(store.error == nil)
        #expect(store.stage == .needsConnect)
    }

    @Test("connect no-ops without a resolvable base URL")
    func connectNoOpsWithoutBaseURL() async {
        let queue = StatusQueue([notConnected(configured: true)])
        let (store, connector) = makeStore(queue: queue, outcome: .connected, baseURL: nil)
        await store.loadStatus()
        await store.connect()
        #expect(connector.capturedURL == nil, "no connect attempt without a base URL")
    }
}
