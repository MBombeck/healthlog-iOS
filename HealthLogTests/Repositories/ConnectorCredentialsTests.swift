import Foundation
@testable import HealthLog
import Testing

/// 7.10 — BYO OAuth credentials + the live connection probe on the shared
/// ``OAuthIntegrationRepository`` (Oura / Polar / Fitbit / Strava). Pins the
/// credential wire body (`{ clientId, clientSecret }`), the per-provider
/// `/api/<provider>/credentials` + `/test` paths, the verbs (PUT save / DELETE
/// forget), and the `{ hasCredentials }` + `{ ok, latencyMs }` decodes. A drift
/// here means a self-hoster can't register their own app keys.
@Suite("ConnectorCredentials")
struct ConnectorCredentialsTests {
    /// Records the send/void requests and returns canned decodes keyed on path.
    /// `@unchecked Sendable` — actor-driven, serial.
    private final class ConnectorStub: APIClientProtocol, @unchecked Sendable {
        var sendPaths: [String] = []
        var voidPaths: [String] = []
        var voidMethods: [HTTPMethod] = []
        var voidBodies: [Data] = []
        let credentialsStatus = BYOCredentialsStatus(hasCredentials: true)
        let testResult = ConnectionTestResult(ok: true, latencyMs: 42)

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            sendPaths.append(request.path)
            let value: any Sendable = request.path.hasSuffix("/test") ? testResult : credentialsStatus
            guard let typed = value as? T else {
                throw HLError.decoding("type mismatch")
            }
            return typed
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            voidPaths.append(request.path)
            voidMethods.append(request.method)
            if let body = request.body {
                voidBodies.append(body)
            }
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    // MARK: - BYO credentials

    @Test("credentialsStatus GETs /api/strava/credentials and decodes hasCredentials")
    func credentialsStatusPath() async throws {
        let stub = ConnectorStub()
        let repo = OAuthIntegrationRepository(api: stub, provider: .strava)
        let status = try await repo.credentialsStatus()
        #expect(stub.sendPaths.contains("/api/strava/credentials"))
        #expect(status.hasCredentials)
    }

    @Test("saveCredentials PUTs the clientId/clientSecret body")
    func saveCredentialsBody() async throws {
        let stub = ConnectorStub()
        let repo = OAuthIntegrationRepository(api: stub, provider: .oura)
        try await repo.saveCredentials(clientId: "client-abc", clientSecret: "secret-xyz")

        #expect(stub.voidPaths.contains("/api/oura/credentials"))
        #expect(stub.voidMethods.contains(.put))
        let body = try #require(stub.voidBodies.first)
        let decoded = try JSONDecoder().decode(BYOCredentialsBody.self, from: body)
        #expect(decoded.clientId == "client-abc")
        #expect(decoded.clientSecret == "secret-xyz")
    }

    @Test("deleteCredentials DELETEs the credentials path")
    func deleteCredentialsVerb() async throws {
        let stub = ConnectorStub()
        let repo = OAuthIntegrationRepository(api: stub, provider: .polar)
        try await repo.deleteCredentials()
        #expect(stub.voidPaths.contains("/api/polar/credentials"))
        #expect(stub.voidMethods.contains(.delete))
    }

    // MARK: - Connection test

    @Test("test POSTs /api/strava/test and decodes ok + latency")
    func connectionTest() async throws {
        let stub = ConnectorStub()
        let repo = OAuthIntegrationRepository(api: stub, provider: .strava)
        let result = try await repo.test()
        #expect(stub.sendPaths.contains("/api/strava/test"))
        #expect(result.ok)
        #expect(result.latencyMs == 42)
    }

    // MARK: - Provider capability flags

    @Test("Strava supports the connection test; Fitbit does not")
    func capabilityFlags() {
        #expect(OAuthIntegrationRepository.Provider.strava.supportsConnectionTest)
        #expect(OAuthIntegrationRepository.Provider.oura.supportsConnectionTest)
        #expect(OAuthIntegrationRepository.Provider.polar.supportsConnectionTest)
        #expect(OAuthIntegrationRepository.Provider.fitbit.supportsConnectionTest == false)
    }

    /// **CU-35 (1) — this expectation INVERTED, deliberately.**
    ///
    /// It used to read "Only Fitbit exposes manual sync", which was true when it
    /// was written: Fitbit was the one provider with a `/sync` route. Server
    /// v1.32.28 added the same route to Oura, Polar and Strava
    /// (`src/app/api/{oura,polar,strava}/sync/route.ts`), so the old assertion
    /// was pinning a fact that had stopped being one — and it was pinning it in
    /// the direction that HID the button from three providers. The
    /// per-provider proof that each path really answers lives in
    /// ``ManualSyncTriggerTests``.
    @Test("every server-OAuth provider exposes manual sync since v1.32.28")
    func manualSyncCapability() {
        #expect(OAuthIntegrationRepository.Provider.fitbit.supportsManualSync)
        #expect(OAuthIntegrationRepository.Provider.strava.supportsManualSync)
        #expect(OAuthIntegrationRepository.Provider.oura.supportsManualSync)
        #expect(OAuthIntegrationRepository.Provider.polar.supportsManualSync)
    }

    // MARK: - DTO decode tolerance

    @Test("BYOCredentialsStatus tolerates a missing field")
    func credentialsStatusTolerant() throws {
        let present = try JSONDecoder.hlDefault.decode(
            BYOCredentialsStatus.self,
            from: Data(#"{ "hasCredentials": true }"#.utf8)
        )
        #expect(present.hasCredentials)

        let missing = try JSONDecoder.hlDefault.decode(
            BYOCredentialsStatus.self,
            from: Data("{}".utf8)
        )
        #expect(missing.hasCredentials == false)
    }

    @Test("ConnectionTestResult decodes ok + optional latency")
    func connectionTestDecode() throws {
        let withLatency = try JSONDecoder.hlDefault.decode(
            ConnectionTestResult.self,
            from: Data(#"{ "ok": true, "latencyMs": 128 }"#.utf8)
        )
        #expect(withLatency.ok)
        #expect(withLatency.latencyMs == 128)

        let noLatency = try JSONDecoder.hlDefault.decode(
            ConnectionTestResult.self,
            from: Data(#"{ "ok": false }"#.utf8)
        )
        #expect(noLatency.ok == false)
        #expect(noLatency.latencyMs == nil)
    }
}
