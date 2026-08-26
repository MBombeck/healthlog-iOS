import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract for `GET /api/sync/state` (server v1.4.30).
///
/// Covers:
/// - happy-path envelope decoding
/// - null `lastSyncedAt` decodes cleanly (first-ever handshake)
/// - clock-skew helper math
/// - server-error surfaces as `HLError`
@Suite("SyncStateRepository — wire contract", .serialized)
struct SyncStateRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo() -> SyncStateRepository {
        SyncStateRepository(api: makeAPI())
    }

    @Test("handshake — decodes the full envelope")
    func handshakeDecodesEnvelope() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "userId":"usr_abc","timezone":"Europe/Berlin",
              "lastSyncedAt":"2026-05-15T14:22:00Z",
              "serverNow":"2026-05-17T12:34:56Z",
              "measurements":{
                "lastUpdatedAt":"2026-05-15T14:22:00Z",
                "liveCount":1234,"tombstonedCount":7
              }
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let state = try await repo.handshake()
        #expect(state.userId == "usr_abc")
        #expect(state.timezone == "Europe/Berlin")
        #expect(state.measurements.liveCount == 1234)
        #expect(state.measurements.tombstonedCount == 7)
        #expect(state.lastSyncedAt != nil)
    }

    @Test("handshake — null lastSyncedAt decodes (first-ever handshake)")
    func handshakeNullLastSyncedAtDecodes() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "userId":"usr_x","timezone":"Europe/Berlin",
              "lastSyncedAt":null,"serverNow":"2026-05-17T12:34:56Z",
              "measurements":{"lastUpdatedAt":null,"liveCount":0,"tombstonedCount":0}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let state = try await repo.handshake()
        #expect(state.lastSyncedAt == nil)
        #expect(state.measurements.lastUpdatedAt == nil)
        #expect(state.measurements.liveCount == 0)
    }

    @Test("clockSkewSeconds — positive when device is ahead of server")
    func clockSkewMath() throws {
        // Use `.plain` (no fractional seconds) — the `.fractional` formatter
        // rejects ISO strings without milliseconds.
        let server = try #require(ISO8601DateFormatter.plain.date(from: "2026-05-17T12:00:00Z"))
        let dto = ServerSyncStateDTO(
            userId: "usr",
            timezone: "Europe/Berlin",
            lastSyncedAt: nil,
            serverNow: server,
            measurements: .init(lastUpdatedAt: nil, liveCount: 0, tombstonedCount: 0)
        )
        // Device clock is 90s ahead of server.
        let now = server.addingTimeInterval(90)
        #expect(abs(dto.clockSkewSeconds(now: now) - 90.0) < 0.01)
    }

    @Test("handshake — server 500 surfaces as HLError")
    func handshakeFailsOn500() async {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await repo.handshake()
            Issue.record("expected throw")
        } catch let err as HLError {
            if case .server = err {
                // pass
            } else {
                Issue.record("expected HLError.server, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test("SyncStateStore — handshake mirrors DTO into observable state")
    func storeHandshakeMirrors() async {
        let store = SyncStateStore(repo: SyncStateRepository(api: makeAPI()))
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "userId":"usr","timezone":"Europe/Berlin",
              "lastSyncedAt":null,"serverNow":"2026-05-17T12:00:00Z",
              "measurements":{"lastUpdatedAt":null,"liveCount":42,"tombstonedCount":3}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.handshake()
        #expect(store.liveMeasurementCount == 42)
        #expect(store.tombstonedMeasurementCount == 3)
        #expect(store.previousCheckpoint == nil)
        #expect(store.lastHandshakeAt != nil)
    }
}

// swiftlint:enable force_unwrapping
