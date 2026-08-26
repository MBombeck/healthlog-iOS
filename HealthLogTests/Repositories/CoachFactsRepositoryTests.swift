import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.2 FW5-C — coach-memory ("what the assistant knows") contract (server B4).**
///
/// Pins the list / forget-one / forget-all wire shapes against the *real* `APIClient`
/// with a stubbed `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md)
/// — so schema drift surfaces. Covers:
///   - facts decode (`data.facts[]`, ordered as the server sends),
///   - idempotent single-delete mapping (`{ deleted: true/false }`, no 404),
///   - forget-all (`{ cleared: N }`),
///   - the disabled-surface mapping (403 + `assistant.disabled.coach`
///     → `HLError.assistantDisabled(.assistantCoach)`).
@Suite("CoachFactsRepository", .serialized)
struct CoachFactsRepositoryTests {
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

    // MARK: - List decode

    @Test("list decodes data.facts[] preserving server order + GETs the facts path")
    func listDecodes() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = """
            {"data":{"facts":[\
            {"id":"f1","category":"preferences","text":"Prefers metric units","confidence":0.92,"createdAt":"2026-06-04T10:00:00Z"},\
            {"id":"f2","category":"routine","text":"Trains in the morning","confidence":0.71,"createdAt":"2026-06-03T08:00:00Z"}\
            ]},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = CoachFactsRepository(api: api)
        let facts = try await repo.list()

        #expect(capturedPath == "/api/insights/coach/facts")
        #expect(capturedMethod == "GET")
        #expect(facts.count == 2)
        // Server order preserved (confidence desc already).
        #expect(facts[0].id == "f1")
        #expect(facts[0].confidence == 0.92)
        #expect(facts[1].category == "routine")
    }

    @Test("list tolerates an empty facts array")
    func listEmpty() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":{"facts":[]},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = CoachFactsRepository(api: api)
        let facts = try await repo.list()
        #expect(facts.isEmpty)
    }

    // MARK: - Idempotent single delete

    @Test("forget(id:) returns deleted=true on a real delete + DELETEs the id path")
    func forgetTrue() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = #"{"data":{"deleted":true},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = CoachFactsRepository(api: api)
        let deleted = try await repo.forget(id: "f1")
        #expect(capturedPath == "/api/insights/coach/facts/f1")
        #expect(capturedMethod == "DELETE")
        #expect(deleted == true)
    }

    @Test("forget(id:) maps an unknown/already-deleted id to deleted=false (no 404, idempotent)")
    func forgetFalseIdempotent() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            // B4: the existence channel never leaks — unknown id is still 200.
            let payload = #"{"data":{"deleted":false},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = CoachFactsRepository(api: api)
        let deleted = try await repo.forget(id: "gone")
        #expect(deleted == false)
    }

    // MARK: - Forget all

    @Test("forgetAll() decodes the cleared count")
    func forgetAll() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let payload = #"{"data":{"cleared":3},"error":null}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = CoachFactsRepository(api: api)
        let cleared = try await repo.forgetAll()
        #expect(capturedPath == "/api/insights/coach/facts")
        #expect(cleared == 3)
    }

    // MARK: - Disabled-surface mapping (coach kill-switch)

    @Test("a disabled Coach surface (403 assistant.disabled.coach) maps to HLError.assistantDisabled(.assistantCoach)")
    func disabledSurface() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"Coach is disabled","errorCode":"assistant.disabled.coach"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = CoachFactsRepository(api: api)
        await #expect(throws: HLError.assistantDisabled(.assistantCoach)) {
            _ = try await repo.list()
        }
    }
}
