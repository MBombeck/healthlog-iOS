import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.10.0 Walkthrough-1 B8 — the mood edit save / add-entry HTTP-405 fix.
///
/// The server item route `/api/mood-entries/[id]` exports GET/PUT/DELETE only —
/// a PATCH returns **405 Method Not Allowed** (the operator's symptom when
/// editing a day's mood). These tests pin that both the live update path and the
/// outbox-replay path issue **PUT** against the item route, through the real
/// `MoodRepository` + real `APIClient` (`MockURLProtocol` driving HTTP).
@Suite("Mood update uses PUT (B8 405 fix)", .serialized)
struct MoodUpdatePutMethodTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.10.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static let moodResp = """
    {"id":"srv-mood-1","mood":"GUT","tags":["walk"],\
    "moodLoggedAt":"2026-05-31T08:00:00.000Z","source":"MANUAL","note":"better"}
    """

    private func okResponse(_ req: URLRequest) -> (HTTPURLResponse, Data) {
        let body = #"{"data":\#(Self.moodResp)}"#
        return (
            HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    @Test("update() issues PUT /api/mood-entries/[id] (not PATCH → would 405)")
    func updateUsesPut() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let captured = MoodMethodRecorder()
        MockURLProtocol.handler = { req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return okResponse(req)
        }

        _ = try await repo.update(id: "srv-mood-1", patch: .init(score: 4, tags: ["walk"], note: "better"))

        #expect(captured.contains(method: "PUT", path: "/api/mood-entries/srv-mood-1"))
        #expect(!captured.contains(method: "PATCH", path: "/api/mood-entries/srv-mood-1"))
        #expect(await (outbox.snapshot).isEmpty, "Happy path must not enqueue an outbox row")
    }

    @Test("replayUpdate() (outbox drain) also issues PUT, not PATCH")
    func replayUpdateUsesPut() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let captured = MoodMethodRecorder()
        MockURLProtocol.handler = { req in
            captured.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return okResponse(req)
        }

        _ = try await repo.replayUpdate(
            id: "srv-mood-1",
            patch: .init(score: 4, tags: ["walk"], note: "better"),
            idempotencyKey: "fixed-key-123"
        )

        #expect(captured.contains(method: "PUT", path: "/api/mood-entries/srv-mood-1"))
        #expect(!captured.contains(method: "PATCH", path: "/api/mood-entries/srv-mood-1"))
    }
}

/// Actor-safe HTTP method+path recorder (runs inside the URLSession queue).
private final class MoodMethodRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(method: String, path: String)] = []

    func record(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((method, path))
    }

    func contains(method: String, path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls.contains { $0.method == method && $0.path == path }
    }
}

// swiftlint:enable force_unwrapping
