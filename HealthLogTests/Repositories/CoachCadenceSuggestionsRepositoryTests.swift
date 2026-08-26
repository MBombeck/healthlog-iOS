import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-COACH-CADENCE (#30) — pins the `CoachCadenceSuggestionsRepository` wire
/// contract against the proactive coach **action** route: the POST hits the right
/// path with only `{ cadenceId, action }` (the client never widens a cadence).
///
/// There is no `GET /api/coach/reminder-suggestions` — the route exports only the
/// action POST; the suggestion itself reaches the client inline during a coach
/// turn (covered in `CoachServerFallbackTests`). Real `APIClient` over a
/// `MockURLProtocol` session (PROJECT_GUIDE.md doctrine — never a hand-rolled mock
/// server) so envelope-shape drift is caught.
@Suite("CoachCadenceSuggestionsRepository", .serialized)
struct CoachCadenceSuggestionsRepositoryTests {
    private struct RecordedCall {
        let method: String
        let path: String
        let body: Data?
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [RecordedCall] = []
        func record(method: String, path: String, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(RecordedCall(method: method, path: path, body: body))
        }

        var snapshot: [RecordedCall] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func makeRepo() -> CoachCadenceSuggestionsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return CoachCadenceSuggestionsRepository(api: api)
    }

    @Test("act POSTs only { cadenceId, action } to the suggestions route")
    func actRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            // MockURLProtocol surfaces the request body via httpBodyStream on some
            // paths; read the raw body the client encoded.
            let body = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            log.record(method: req.httpMethod ?? "?", path: req.url!.path, body: body)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"data\":{}}".utf8))
        }

        try await repo.act(cadenceId: "bp_7_2_2", action: .accept)

        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/coach/reminder-suggestions")
        let body = try #require(call.body)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["cadenceId"] as? String == "bp_7_2_2")
        #expect(decoded?["action"] as? String == "accept")
        // The client NEVER sends cadence parameters — only the id + action.
        #expect(decoded?.count == 2)
    }

    @Test("act surfaces a 404 (route not live) as a typed server error")
    func actNotLive() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data("{\"error\":{\"message\":\"not found\"}}".utf8)
            )
        }

        await #expect(throws: HLError.self) {
            try await repo.act(cadenceId: "bp_7_2_2", action: .dismiss)
        }
    }
}

// swiftlint:enable force_unwrapping
