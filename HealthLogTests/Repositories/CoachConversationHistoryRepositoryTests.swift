// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **b182 (AUDIT-COACH-PARITY §B) — coach conversation-history READ contract**
/// (`GET /api/insights/chat`, `GET /api/insights/chat/{id}`).
///
/// Pins the wire shapes against the *real* `APIClient` with a stubbed
/// `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md):
///   - list decode (`data.{ conversations[], nextCursor }`, metadata only),
///   - list cursor forwarding (query param),
///   - detail decode (`data.{ …, messages[], summary }`, oldest-first + roles),
///   - disabled-Coach 403 maps to the typed `HLError.assistantDisabled`.
@Suite("CoachConversationHistoryRepository", .serialized)
struct CoachConversationHistoryRepositoryTests {
    private func makeRepo() -> CoachConversationHistoryRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return CoachConversationHistoryRepository(api: api)
    }

    @Test("list decodes the rail page (conversations + nextCursor)")
    func listDecodes() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = """
            {"data":{"conversations":[\
            {"id":"c1","title":"Sleep","createdAt":"2026-06-10T08:00:00.000Z",\
            "updatedAt":"2026-06-12T08:00:00.000Z","messageCount":4},\
            {"id":"c2","title":"Blood pressure","createdAt":"2026-06-09T08:00:00.000Z",\
            "updatedAt":"2026-06-11T08:00:00.000Z","messageCount":2}\
            ],"nextCursor":"c2"},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let page = try await repo.list()

        #expect(capturedPath == "/api/insights/chat")
        #expect(capturedMethod == "GET")
        #expect(page.conversations.count == 2)
        #expect(page.conversations.first?.id == "c1")
        #expect(page.conversations.first?.title == "Sleep")
        #expect(page.conversations.first?.messageCount == 4)
        #expect(page.nextCursor == "c2")
    }

    @Test("list forwards the cursor as a query param and tolerates an empty page")
    func listCursorAndEmpty() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedQuery: String?
        MockURLProtocol.handler = { req in
            capturedQuery = req.url?.query
            let payload = """
            {"data":{"conversations":[],"nextCursor":null},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let page = try await repo.list(cursor: "c9", limit: 10)

        #expect(capturedQuery?.contains("cursor=c9") == true)
        #expect(capturedQuery?.contains("limit=10") == true)
        #expect(page.conversations.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("detail decodes messages oldest-first with roles + the rolling summary")
    func detailDecodes() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let payload = """
            {"data":{"id":"c1","title":"Sleep","createdAt":"2026-06-10T08:00:00.000Z",\
            "updatedAt":"2026-06-12T08:00:00.000Z","messageCount":3,\
            "summary":"We discussed sleep duration.",\
            "messages":[\
            {"id":"m1","role":"user","content":"How is my sleep?","createdAt":"2026-06-10T08:00:00.000Z",\
            "metricSource":null,"providerType":null,"promptVersion":null},\
            {"id":"m2","role":"assistant","content":"Your sleep looks steady.","createdAt":"2026-06-10T08:00:05.000Z",\
            "metricSource":null,"providerType":"anthropic","promptVersion":"v3"},\
            {"id":"m3","role":"weird","content":"folds to assistant","createdAt":"2026-06-10T08:00:06.000Z",\
            "metricSource":null,"providerType":null,"promptVersion":null}\
            ]},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let detail = try await repo.detail(id: "c1")

        #expect(capturedPath == "/api/insights/chat/c1")
        #expect(detail.id == "c1")
        #expect(detail.summary == "We discussed sleep duration.")
        #expect(detail.messages.count == 3)
        #expect(detail.messages[0].role == .user)
        #expect(detail.messages[0].content == "How is my sleep?")
        #expect(detail.messages[1].role == .assistant)
        // Unknown role folds to .assistant (schema-forward) — never crashes decode.
        #expect(detail.messages[2].role == .assistant)
    }

    @Test("deleteConversation issues DELETE on /api/insights/chat/{id} and accepts an empty 2xx body")
    func deleteHitsCorrectPathAndMethod() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            // Server replies 200 + `{}` — the canonical EmptyResponse path (a
            // truly empty `Data()` is not valid JSON and would fail decode).
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data("{}".utf8))
        }
        try await repo.deleteConversation(id: "c1")

        #expect(capturedPath == "/api/insights/chat/c1")
        #expect(capturedMethod == "DELETE")
    }

    @Test("deleteConversation surfaces a 404 (foreign id / route not deployed) as a typed HLError")
    func deleteNotFoundThrowsServerError() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":null,"error":"Not found"}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await #expect(throws: HLError.self) {
            try await repo.deleteConversation(id: "missing")
        }
    }

    @Test("deleteConversation maps a disabled Coach surface to the typed assistantDisabled error")
    func deleteDisabledCoachThrowsTyped() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":null,"error":"Coach disabled","errorCode":"assistant.disabled.coach"}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await #expect(throws: HLError.assistantDisabled(.assistantCoach)) {
            try await repo.deleteConversation(id: "c1")
        }
    }

    @Test("disabled Coach surface maps to the typed assistantDisabled error")
    func disabledCoachThrowsTyped() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":null,"error":"Coach disabled","errorCode":"assistant.disabled.coach"}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await #expect(throws: HLError.assistantDisabled(.assistantCoach)) {
            _ = try await repo.list()
        }
    }
}
