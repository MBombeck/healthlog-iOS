import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v1.18.6 — pins the `DiabetesRepository` wire contract against the live
/// `/api/auth/me/diabetes` routes: GET reads the flag, PATCH sends
/// `{ hasDiabetes }` and unwraps the resolved next-state from the
/// `{ data, error, meta }` envelope. Uses the real `APIClient` over a
/// `MockURLProtocol` session (PROJECT_GUIDE.md doctrine — never a hand-rolled mock
/// server) so envelope-shape drift is caught.
@Suite("DiabetesRepository", .serialized)
struct DiabetesRepositoryTests {
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

    /// Reads a request body from the `httpBodyStream` (URLProtocol strips
    /// `httpBody` but preserves the stream).
    private static func bodyFromStream(_ req: URLRequest) -> Data? {
        guard let stream = req.httpBodyStream else { return req.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    private func makeRepo() -> DiabetesRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return DiabetesRepository(api: api)
    }

    @Test("fetch GETs /api/auth/me/diabetes and unwraps the flag")
    func fetchRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path, body: Self.bodyFromStream(req))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"hasDiabetes":true}}"#.utf8)
            )
        }

        let dto = try await repo.fetch()

        #expect(dto.hasDiabetes == true)
        let call = try #require(log.snapshot.first)
        #expect(call.method == "GET")
        #expect(call.path == "/api/auth/me/diabetes")
    }

    @Test("update PATCHes the flag and unwraps the resolved next-state")
    func updateRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path, body: Self.bodyFromStream(req))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"hasDiabetes":true}}"#.utf8)
            )
        }

        let dto = try await repo.update(hasDiabetes: true)

        #expect(dto.hasDiabetes == true)
        let call = try #require(log.snapshot.first)
        #expect(call.method == "PATCH")
        #expect(call.path == "/api/auth/me/diabetes")
        // The PATCH body carries the flag.
        let body = try #require(call.body)
        let sent = try JSONDecoder().decode(DiabetesFlagDTO.self, from: body)
        #expect(sent.hasDiabetes == true)
    }

    @Test("update can clear the flag (false echoed back)")
    func updateClears() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"hasDiabetes":false}}"#.utf8)
            )
        }
        let dto = try await repo.update(hasDiabetes: false)
        #expect(dto.hasDiabetes == false)
    }
}

// swiftlint:enable force_unwrapping
