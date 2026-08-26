import Foundation
@testable import HealthLog
import Testing

/// Decode + state locks for the v1.18.7 web-parity (❌-7) integration
/// connect-cards: Oura / Polar / Fitbit (server-OAuth via
/// ``OAuthIntegrationRepository`` / ``OAuthIntegrationCore``) and Nightscout
/// (URL+token via ``NightscoutRepository`` / ``NightscoutIntegrationStore``).
///
/// Pins:
/// 1. The status DTOs decode the verbatim server shapes (`connected`,
///    `configured`, ledger `state`, the timestamps) — a schema drift surfaces
///    here, not as a silent "Not connected" in Settings.
/// 2. The store wires connect/disconnect/sync onto the right `POST` paths and
///    re-reads status, mirroring the Withings/WHOOP pattern.
@MainActor
@Suite("IntegrationConnectCards")
struct IntegrationConnectCardTests {
    // MARK: - Stub APIClient

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
        var oauthStatusQueue: [OAuthIntegrationStatus]
        var nightscoutStatusQueue: [NightscoutStatus]
        var voidPaths: [String] = []
        var voidBodies: [Data] = []

        init(oauth: [OAuthIntegrationStatus] = [], nightscout: [NightscoutStatus] = []) {
            oauthStatusQueue = oauth
            nightscoutStatusQueue = nightscout
        }

        func sendHandler() -> @Sendable (any Sendable) async throws -> any Sendable {
            { req in
                if req is APIRequest<OAuthIntegrationStatus> {
                    return await self.nextOAuth()
                }
                if req is APIRequest<NightscoutStatus> {
                    return await self.nextNightscout()
                }
                throw HLError.unknown("unexpected GET shape: \(type(of: req))")
            }
        }

        func voidHandler() -> @Sendable (APIRequest<EmptyPayload>) async throws -> Void {
            { req in await self.recordVoid(path: req.path, body: req.body) }
        }

        func nextOAuth() -> OAuthIntegrationStatus {
            if oauthStatusQueue.count > 1 { return oauthStatusQueue.removeFirst() }
            return oauthStatusQueue[0]
        }

        func nextNightscout() -> NightscoutStatus {
            if nightscoutStatusQueue.count > 1 { return nightscoutStatusQueue.removeFirst() }
            return nightscoutStatusQueue[0]
        }

        func recordVoid(path: String, body: Data?) {
            voidPaths.append(path)
            if let body { voidBodies.append(body) }
        }
    }

    // MARK: - DTO decode

    @Test("OAuthIntegrationStatus decodes the connected Oura/Polar ledger shape")
    func oauthStatusDecodeConnected() throws {
        let json = Data(#"""
        {
            "connected": true,
            "configured": true,
            "state": "ok",
            "lastSuccessAt": "2026-06-19T08:30:00.000Z",
            "lastAttemptAt": "2026-06-19T08:30:00.000Z",
            "lastError": null
        }
        """#.utf8)
        let status = try JSONDecoder.hlDefault.decode(OAuthIntegrationStatus.self, from: json)
        #expect(status.connected)
        #expect(status.configured == true)
        #expect(status.state == "ok")
        #expect(status.isParkedOrError == false)
        #expect(status.lastSync != nil) // falls back to lastSuccessAt
    }

    @Test("OAuthIntegrationStatus decodes the not-connected shape + flags parked state")
    func oauthStatusDecodeDisconnectedAndParked() throws {
        let disconnected = try JSONDecoder.hlDefault.decode(
            OAuthIntegrationStatus.self,
            from: Data(#"{ "connected": false, "configured": false }"#.utf8)
        )
        #expect(disconnected.connected == false)
        #expect(disconnected.lastSync == nil)

        let parked = try JSONDecoder.hlDefault.decode(
            OAuthIntegrationStatus.self,
            from: Data(#"{ "connected": true, "configured": true, "state": "parked" }"#.utf8)
        )
        #expect(parked.isParkedOrError)
    }

    @Test("Fitbit status decodes lastSyncedAt + connectedAt")
    func fitbitStatusDecode() throws {
        let json = Data(#"""
        {
            "connected": true,
            "configured": true,
            "lastSyncedAt": "2026-06-19T07:00:00.000Z",
            "connectedAt": "2026-06-01T00:00:00.000Z",
            "scope": "activity heartrate sleep"
        }
        """#.utf8)
        let status = try JSONDecoder.hlDefault.decode(OAuthIntegrationStatus.self, from: json)
        #expect(status.lastSyncedAt != nil)
        #expect(status.lastSync == status.lastSyncedAt) // explicit field wins
        #expect(status.scope == "activity heartrate sleep")
    }

    @Test("NightscoutStatus decodes the connected + token shape")
    func nightscoutStatusDecode() throws {
        let json = Data(#"""
        {
            "connected": true,
            "configured": true,
            "hasToken": true,
            "allowPrivateHost": false,
            "state": "ok"
        }
        """#.utf8)
        let status = try JSONDecoder.hlDefault.decode(NightscoutStatus.self, from: json)
        #expect(status.connected)
        #expect(status.hasToken == true)
        #expect(status.isParkedOrError == false)
    }

    // MARK: - OAuthIntegrationCore wiring

    /// **CU-35 (1) — the sync gate opened.** This used to assert that Oura had
    /// no manual sync and that `syncNow()` was a silent no-op there. Both were
    /// true only until server v1.32.28 gave Oura / Polar / Strava the same
    /// `POST /api/<provider>/sync` route Fitbit already had. The store-level
    /// behaviour of the three answers (200 / 429 / 502) is pinned in
    /// ``ManualSyncTriggerTests`` against the real `APIClient`.
    @Test("loadStatus surfaces connected; every OAuth provider now supports manual sync")
    func oauthCoreLoadAndSyncGate() async {
        let stub = StubAPIClient()
        let capture = Capture(oauth: [.init(connected: true, configured: true, state: "ok")])
        stub.sendHandler = capture.sendHandler()
        stub.voidHandler = capture.voidHandler()

        let ouraCore = OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: stub, provider: .oura), provider: .oura)
        await ouraCore.loadStatus()
        #expect(ouraCore.isConnected == true)
        #expect(ouraCore.supportsManualSync)

        let fitbitCore = OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: stub, provider: .fitbit), provider: .fitbit)
        #expect(fitbitCore.supportsManualSync)
    }

    @Test("disconnect POSTs to /api/<provider>/disconnect then re-reads status")
    func oauthCoreDisconnect() async {
        let stub = StubAPIClient()
        let capture = Capture(oauth: [
            .init(connected: true, configured: true, state: "ok"),
            .init(connected: false, configured: true, state: "ok")
        ])
        stub.sendHandler = capture.sendHandler()
        stub.voidHandler = capture.voidHandler()

        let core = OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: stub, provider: .polar), provider: .polar)
        await core.loadStatus()
        #expect(core.isConnected == true)
        await core.disconnect()
        #expect(capture.voidPaths.contains("/api/polar/disconnect"))
        #expect(core.isConnected == false) // re-read reflects server truth
    }

    // MARK: - Nightscout store wiring

    @Test("Nightscout connect POSTs url+token+allowPrivateHost, then re-reads")
    func nightscoutConnect() async throws {
        let stub = StubAPIClient()
        let capture = Capture(nightscout: [
            .init(connected: false, configured: false),
            .init(connected: true, configured: true, hasToken: true, state: "ok")
        ])
        stub.sendHandler = capture.sendHandler()
        stub.voidHandler = capture.voidHandler()

        let store = NightscoutIntegrationStore(repo: NightscoutRepository(api: stub))
        await store.loadStatus()
        #expect(store.isConnected == false)

        let ok = await store.connect(
            url: "https://ns.example.com",
            token: "abc123",
            allowPrivateHost: true
        )
        #expect(ok)
        #expect(capture.voidPaths.contains("/api/nightscout/connect"))
        #expect(store.isConnected == true)

        // The wire body carries the pasted credentials verbatim.
        let body = try #require(capture.voidBodies.first)
        let decoded = try JSONDecoder().decode(NightscoutRepository.ConnectBody.self, from: body)
        #expect(decoded.url == "https://ns.example.com")
        #expect(decoded.token == "abc123")
        #expect(decoded.allowPrivateHost)
    }

    @Test("Nightscout disconnect POSTs to /api/nightscout/disconnect")
    func nightscoutDisconnect() async {
        let stub = StubAPIClient()
        let capture = Capture(nightscout: [
            .init(connected: true, configured: true),
            .init(connected: false, configured: false)
        ])
        stub.sendHandler = capture.sendHandler()
        stub.voidHandler = capture.voidHandler()

        let store = NightscoutIntegrationStore(repo: NightscoutRepository(api: stub))
        await store.loadStatus()
        await store.disconnect()
        #expect(capture.voidPaths.contains("/api/nightscout/disconnect"))
        #expect(store.isConnected == false)
    }
}
