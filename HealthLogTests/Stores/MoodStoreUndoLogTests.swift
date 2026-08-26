import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// MEDS-QUICK-MARK-UNDO sibling (v0.11 W26) — quick mood-log undo.
///
/// Real APIClient over `MockURLProtocol` so the log POST + the undo DELETE
/// exercise the real wire serialization (PROJECT_GUIDE.md: never a mock server on
/// the outbox-replay path). `logUndoable` must insert the entry, enqueue a
/// `Rückgängig` action on the coordinator, and the action must remove the
/// just-logged entry on undo.
@MainActor
@Suite("MoodStore — quick-log undo", .serialized)
struct MoodStoreUndoLogTests {
    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
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

    @Test("logUndoable inserts an entry and enqueues a Rückgängig action")
    func logUndoableInsertsAndEnqueues() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let body = """
            {"data":{"id":"mood-1","mood":"GUT","tags":[],\
            "moodLoggedAt":"2026-05-01T09:00:00Z","source":null,"note":null}}
            """
            return (Self.response(200, request: req), Data(body.utf8))
        }
        let repo = MoodRepository(api: api, outbox: outbox)
        let undo = UndoCoordinator()
        let store = MoodStore(repo: repo, undoCoordinator: undo)

        let saved = await store.logUndoable(score: 4)

        let entry = try #require(saved, "A landed log must return the saved entry")
        #expect(entry.id == "mood-1")
        #expect(store.entries.contains { $0.id == "mood-1" })
        #expect(undo.current != nil, "logUndoable must enqueue a Rückgängig action")
    }

    @Test("Undo of a quick log removes the entry locally")
    func undoRemovesLoggedEntry() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            // POST → 200 with the entry; DELETE → 204 No Content.
            if req.httpMethod == "DELETE" {
                // 200 + `{}` so `EmptyResponse` decodes (empty Data() is not
                // valid JSON and would surface as a decoding error).
                return (Self.response(200, request: req), Data("{}".utf8))
            }
            let body = """
            {"data":{"id":"mood-1","mood":"GUT","tags":[],\
            "moodLoggedAt":"2026-05-01T09:00:00Z","source":null,"note":null}}
            """
            return (Self.response(200, request: req), Data(body.utf8))
        }
        let repo = MoodRepository(api: api, outbox: outbox)
        let undo = UndoCoordinator()
        let store = MoodStore(repo: repo, undoCoordinator: undo)

        _ = await store.logUndoable(score: 4)
        #expect(store.entries.contains { $0.id == "mood-1" })

        // Fire the undo closure the toast would call.
        await undo.performUndo()

        #expect(
            !store.entries.contains { $0.id == "mood-1" },
            "Undo of a quick log must remove the just-logged entry"
        )
        #expect(undo.current == nil)
    }
}

// swiftlint:enable force_unwrapping
