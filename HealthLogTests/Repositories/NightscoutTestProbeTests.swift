import Foundation
@testable import HealthLog
import Testing

/// 7.10 — the Nightscout live connection probe (`POST /api/nightscout/test`).
/// Pins the repo path + the store wiring that publishes the result on
/// `lastTestResult` so the Settings surface can show "connection OK".
@MainActor
@Suite("NightscoutTestProbe")
struct NightscoutTestProbeTests {
    /// Records send/void requests and returns canned decodes keyed on path.
    private final class NightscoutStub: APIClientProtocol, @unchecked Sendable {
        var sendPaths: [String] = []
        let statusValue: NightscoutStatus
        let testValue = ConnectionTestResult(ok: true, latencyMs: 17)

        init(status: NightscoutStatus) {
            statusValue = status
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            sendPaths.append(request.path)
            let value: any Sendable = request.path.hasSuffix("/test") ? testValue : statusValue
            guard let typed = value as? T else {
                throw HLError.decoding("type mismatch")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    @Test("Repository test() hits POST /api/nightscout/test and decodes the probe")
    func repoTestPath() async throws {
        let stub = NightscoutStub(status: NightscoutStatus(connected: true, configured: true))
        let repo = NightscoutRepository(api: stub)
        let result = try await repo.test()
        #expect(stub.sendPaths.contains("/api/nightscout/test"))
        #expect(result.ok)
        #expect(result.latencyMs == 17)
    }

    @Test("Store testConnection publishes lastTestResult")
    func storePublishesResult() async {
        let stub = NightscoutStub(status: NightscoutStatus(connected: true, configured: true))
        let store = NightscoutIntegrationStore(repo: NightscoutRepository(api: stub))
        await store.testConnection()
        #expect(store.lastTestResult?.ok == true)
        #expect(store.lastTestResult?.latencyMs == 17)
    }
}
