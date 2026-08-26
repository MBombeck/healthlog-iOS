import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **WW/F1,F2 — honest watch-ack mapping.**
///
/// The phone funnels a watch action into the live store, then acks the watch
/// with the HONEST outcome (`saved` / `queued` / `failed`). These guard:
///   - the store-outcome → `WatchAckOutcome` bridge the coordinator uses, and
///   - the F1 store-level fix: a token-expiry 401 during a mood write keeps the
///     optimistic row + reports `.queued` (durably in the Outbox), instead of
///     the old `.failed`/drop that made the wrist-logged mood vanish.
@MainActor
@Suite("Watch ack mapping (WW/F1,F2)", .serialized)
struct WatchAckMappingTests {
    // MARK: - Outcome bridge

    @Test("WriteOutcome bridges to the watch ack outcome")
    func outcomeBridge() {
        #expect(MedicationsStore.WriteOutcome.success.watchAckOutcome == .saved)
        #expect(MedicationsStore.WriteOutcome.queued.watchAckOutcome == .queued)
        #expect(MedicationsStore.WriteOutcome.failed(.unauthorized).watchAckOutcome == .failed)
        #expect(MedicationsStore.WriteOutcome.failed(.offline).watchAckOutcome == .failed)
    }

    // MARK: - F1: mood log under a transient-refresh 401 → queued, row kept

    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.13.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock(),
            refreshHandler: { .transient } // a 401 mid-write yields .unauthorized, NO logout
        )
    }

    private nonisolated static func response(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    @Test("A 401-during-write mood log reports .queued and keeps the optimistic row")
    func moodLogQueuedOnUnauthorized() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (Self.response(401, request: req), Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let repo = MoodRepository(api: api, outbox: outbox)
        let store = MoodStore(repo: repo)

        let result = await store.logReturningOutcome(score: 4, tags: [], note: nil)

        #expect(result.outcome == .queued, "A token-expiry 401 must be durably queued, not dropped")
        #expect(result.entry != nil, "The optimistic entry must survive so the watch shows it")
        #expect(
            store.entries.contains { $0.score == 4 },
            "The optimistic mood must remain in the store (the F1 watch-mood-vanishes fix)"
        )
        let snap = await outbox.snapshot
        #expect(snap.count == 1, "The mood write must be enqueued for replay after re-auth")
    }

    @Test("A landed mood log reports .saved")
    func moodLogSaved() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let body = """
            {"data":{"id":"mood-9","mood":"GUT","tags":[],\
            "moodLoggedAt":"2026-06-01T09:00:00Z","source":null,"note":null}}
            """
            return (Self.response(200, request: req), Data(body.utf8))
        }
        let repo = MoodRepository(api: api, outbox: outbox)
        let store = MoodStore(repo: repo)

        let result = await store.logReturningOutcome(score: 4, tags: [], note: nil)
        #expect(result.outcome == .success)
        #expect(result.outcome.watchAckOutcome == .saved)
        #expect(result.entry?.id == "mood-9")
    }
}
