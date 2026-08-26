// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **Server-parity — coach message feedback** (`POST
/// /api/insights/chat/messages/{id}/feedback`, server v1.4.23 H7).
///
/// Pins the wire shape against the *real* `APIClient` with a stubbed
/// `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md):
///   - path + method + `{ rating }` body,
///   - 201 `{ data: { id, createdAt } }` acknowledgement decode,
///   - the 409 `already_rated` dedupe answer surfacing as
///     `HLError.server(status: 409, …)`,
/// plus the `CoachConversationStore.submitFeedback` state machine
/// (register → submit → locked; 409 → locked; transport error → retryable).
@Suite("Coach message feedback — wire shape + store state", .serialized)
struct CoachFeedbackTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// `URLProtocol` swaps `httpBody` for `httpBodyStream` — re-materialize.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    // MARK: - Wire shape

    @Test("submitFeedback POSTs {rating} to the message feedback path and accepts the 201 ack")
    func wireShape() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            let payload = #"{"data":{"id":"fb-1","createdAt":"2026-06-11T10:00:00.000Z"},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let service = CoachServerService(api: api)
        try await service.submitFeedback(messageID: "msg-9", rating: .helpful)

        #expect(capturedPath == "/api/insights/chat/messages/msg-9/feedback")
        #expect(capturedMethod == "POST")
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["rating"] as? String == "helpful")
        #expect(json.count == 1) // no stray fields — `reason` is deliberately not sent
    }

    @Test("a repeat submission (409 already_rated) surfaces as HLError.server(409)")
    func conflictSurfaces() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"already_rated"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let service = CoachServerService(api: api)
        do {
            try await service.submitFeedback(messageID: "msg-9", rating: .unhelpful)
            Issue.record("expected a 409 to throw")
        } catch {
            guard case let HLError.server(status, _, _) = error else {
                Issue.record("expected HLError.server, got \(error)")
                return
            }
            #expect(status == 409)
        }
    }

    // MARK: - Store state machine

    @MainActor
    @Test("submitFeedback locks the row on a 201 ack")
    func storeMarksRated() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":{"id":"fb-1","createdAt":"2026-06-11T10:00:00.000Z"},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let store = CoachConversationStore(
            service: LocalLLMService(),
            serverService: CoachServerService(api: api)
        )
        let entityID = UUID()
        store.feedback.register(messageID: "msg-9", forEntity: entityID)
        #expect(store.feedback.canRate(entityID: entityID))
        #expect(store.feedback.rating(forEntity: entityID) == nil)

        await store.submitFeedback(.helpful, forEntity: entityID)

        #expect(store.feedback.rating(forEntity: entityID) == .helpful)
        #expect(store.feedback.isSubmitting(entityID: entityID) == false)
    }

    @MainActor
    @Test("submitFeedback treats 409 already_rated as locked (no error surface)")
    func storeLocksOnConflict() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"already_rated"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let store = CoachConversationStore(
            service: LocalLLMService(),
            serverService: CoachServerService(api: api)
        )
        let entityID = UUID()
        store.feedback.register(messageID: "msg-9", forEntity: entityID)

        await store.submitFeedback(.unhelpful, forEntity: entityID)

        #expect(store.feedback.rating(forEntity: entityID) == .unhelpful)
    }

    @MainActor
    @Test("a non-409 failure leaves the row ratable (retry stays possible)")
    func storeKeepsRatableOnFailure() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            // 422 — non-retriable, non-409: the store must NOT lock the row.
            let payload = #"{"data":null,"error":"feedback.body.invalid"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let store = CoachConversationStore(
            service: LocalLLMService(),
            serverService: CoachServerService(api: api)
        )
        let entityID = UUID()
        store.feedback.register(messageID: "msg-9", forEntity: entityID)

        await store.submitFeedback(.helpful, forEntity: entityID)

        #expect(store.feedback.rating(forEntity: entityID) == nil)
        #expect(store.feedback.canRate(entityID: entityID))
    }

    @MainActor
    @Test("entities without a registered server id can never rate")
    func unregisteredEntityNoOps() async {
        let store = CoachConversationStore(service: LocalLLMService())
        let entityID = UUID()
        #expect(store.feedback.canRate(entityID: entityID) == false)
        await store.submitFeedback(.helpful, forEntity: entityID) // must no-op
        #expect(store.feedback.rating(forEntity: entityID) == nil)
    }

    @MainActor
    @Test("reset clears feedback state alongside the transcript")
    func resetClears() {
        let store = CoachConversationStore(service: LocalLLMService())
        let entityID = UUID()
        store.feedback.register(messageID: "msg-9", forEntity: entityID)
        store.feedback.markRated("msg-9", .helpful)
        store.reset()
        #expect(store.feedback.canRate(entityID: entityID) == false)
        #expect(store.feedback.rating(forEntity: entityID) == nil)
    }
}
