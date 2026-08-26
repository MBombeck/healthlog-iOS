import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **Phase 09 / plan 09-02 — the centralized one-shot from-file transport.**
///
/// These cases drive the **real** ``APIClient`` over a session-owned
/// `URLProtocol` stub (Plan 09-11's recipe: both halves from the session, the
/// address being the load-bearing one), so route, headers, status handling and
/// envelope decoding are the production ones rather than a re-implementation.
///
/// Three properties are asserted here and nowhere else, because they are the
/// three ways a large body gets sent twice without anybody noticing:
///
/// * a 401 does not go through the refresh-and-replay bridge,
/// * a 5xx and a transport failure do not go through the retry loop,
/// * a redirect does not go through Foundation's body-replaying follow.
///
/// Each is asserted with a **positive** request count on this test's own
/// session, not only with the thrown error. A served 500 and a request that
/// never arrived produce the same `catch`.
@Suite("APIClient file upload", .serialized)
struct APIClientFileUploadTests {
    static let uploadPath = "/api/import/apple-health-export"

    private func makeClient(
        session: MockURLProtocolSession,
        keychain: KeychainStoring = InMemoryKeychain(),
        refreshHandler: (@Sendable () async -> RefreshOutcome)? = nil
    ) -> APIClient {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: session.configuration,
            refreshHandler: refreshHandler
        )
    }

    /// A small on-disk body. The transport does not care what is in it; the
    /// point is that the bytes are in a file and not in this process.
    private func makeBodyFile(_ scratch: Phase09Scratch, bytes: Int = 4096) throws -> (URL, Int) {
        let url = scratch.url.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        let payload = Data(repeating: 0x41, count: bytes)
        try payload.write(to: url)
        return (url, payload.count)
    }

    private func makeRequest(
        file: URL,
        byteCount: Int
    ) -> APIFileUploadRequest<AppleHealthImportKickoffDTO> {
        APIFileUploadRequest(
            method: .post,
            path: Self.uploadPath,
            bodyFileURL: file,
            byteCount: byteCount,
            contentType: "multipart/form-data; boundary=BOUND-09-02"
        )
    }

    // MARK: - The request that is built

    @Test("the built request states a known length, carries the caller's content type, and has no in-memory body")
    func builtRequestHasKnownLengthAndNoInMemoryBody() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try keychain.setString("bearer-09-02", forKey: KeychainKey.authToken)
        let api = makeClient(session: session, keychain: keychain)

        let scratch = try Phase09Scratch("09-02-request")
        let (file, bytes) = try makeBodyFile(scratch, bytes: 12345)
        let built = try await api.fileUploadURLRequest(for: makeRequest(file: file, byteCount: bytes))

        #expect(built.httpMethod == "POST")
        #expect(built.url?.path == Self.uploadPath)
        #expect(built.value(forHTTPHeaderField: "Content-Length") == "12345")
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND-09-02")
        #expect(built.value(forHTTPHeaderField: "Authorization") == "Bearer bearer-09-02")
        // The POST still asserts the route's idempotency contract.
        #expect(built.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
        // The whole point: the request object holds no bytes.
        #expect(built.httpBody == nil)
        #expect(built.httpBodyStream == nil)
    }

    // MARK: - The happy path

    @Test("a 202 kickoff decodes through the client's own envelope handling, in exactly one request")
    func kickoffDecodesInExactlyOneRequest() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        let calls = UploadCallLedger()
        session.install { req in
            guard req.targets(APIClientFileUploadTests.uploadPath, method: "POST") else {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            calls.record(req)
            let body = #"{"data":{"jobId":"ij-file","status":"queued"}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let scratch = try Phase09Scratch("09-02-happy")
        let (file, bytes) = try makeBodyFile(scratch)
        let kickoff = try await api.uploadFile(makeRequest(file: file, byteCount: bytes))

        #expect(kickoff.jobId == "ij-file")
        #expect(calls.count == 1)
        #expect(calls.contentTypes == ["multipart/form-data; boundary=BOUND-09-02"])
        // The request that reached the transport carries no in-memory body
        // either: `URLSession` streams the file, it does not inline it.
        #expect(calls.inMemoryBodyByteCounts == [nil])
    }

    // MARK: - One request, whatever the answer

    @Test("a 401 surfaces without the refresh-and-replay bridge, in exactly one request")
    func unauthorizedIsNotRecoveredAndNotReplayed() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let refreshes = Counter()
        let api = makeClient(session: session, refreshHandler: {
            refreshes.bump()
            return .refreshed
        })
        let calls = UploadCallLedger()
        session.install { req in
            calls.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        let scratch = try Phase09Scratch("09-02-401")
        let (file, bytes) = try makeBodyFile(scratch)
        await #expect(throws: HLError.unauthorized) {
            _ = try await api.uploadFile(self.makeRequest(file: file, byteCount: bytes))
        }
        #expect(calls.count == 1)
        // A refresh that fired would have replayed the body — the whole reason
        // this route opts out of authentication recovery.
        #expect(refreshes.value == 0)
    }

    @Test("a 500 is not retried, in exactly one request")
    func serverErrorIsNotRetried() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        let calls = UploadCallLedger()
        session.install { req in
            calls.record(req)
            let body = #"{"data":null,"error":"upstream exploded"}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let scratch = try Phase09Scratch("09-02-500")
        let (file, bytes) = try makeBodyFile(scratch)
        await #expect(throws: (any Error).self) {
            _ = try await api.uploadFile(self.makeRequest(file: file, byteCount: bytes))
        }
        #expect(calls.count == 1)
    }

    @Test("a network failure is not retried, in exactly one request")
    func networkFailureIsNotRetried() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeClient(session: session)
        let calls = UploadCallLedger()
        session.install { req in
            calls.record(req)
            throw URLError(.networkConnectionLost)
        }

        let scratch = try Phase09Scratch("09-02-net")
        let (file, bytes) = try makeBodyFile(scratch)
        await #expect(throws: HLError.offline) {
            _ = try await api.uploadFile(self.makeRequest(file: file, byteCount: bytes))
        }
        #expect(calls.count == 1)
    }

    // MARK: - Redirects

    @Test("the one-shot delegate refuses 301, 302, 303, 307 and 308")
    func theDelegateRefusesEveryRedirectStatus() throws {
        let delegate = OneShotFileUploadDelegate(pinner: CertificatePinner())
        let url = try #require(URL(string: "https://example.invalid/api/import/apple-health-export"))
        var decisions: [Int: URLRequest?] = [:]
        for status in [301, 302, 303, 307, 308] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            // The pure decision, and the delegate hop that consumes it. Both,
            // because a pure function that always answers `nil` proves nothing
            // if the delegate ignores it.
            #expect(OneShotFileUploadDelegate.redirectRequest(for: response) == nil)
            let box = RedirectDecisionBox()
            try delegate.urlSession(
                URLSession.shared,
                task: URLSession.shared.dataTask(with: url),
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: #require(URL(string: "https://elsewhere.invalid/somewhere"))),
                completionHandler: { box.record($0) }
            )
            decisions[status] = box.value
        }
        #expect(decisions.count == 5)
        #expect(decisions.values.allSatisfy { $0 == nil })
    }

    @Test("every redirect status surfaces as a server error without a second wire request")
    func redirectsNeverProduceASecondWireRequest() async throws {
        for status in [301, 302, 303, 307, 308] {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let api = makeClient(session: session)
            let calls = UploadCallLedger()
            session.install { req in
                calls.record(req)
                let headers = ["Location": "https://elsewhere.invalid/replayed"]
                return (
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
                    Data("{}".utf8)
                )
            }

            let scratch = try Phase09Scratch("09-02-redirect-\(status)")
            let (file, bytes) = try makeBodyFile(scratch)
            await #expect(throws: (any Error).self) {
                _ = try await api.uploadFile(self.makeRequest(file: file, byteCount: bytes))
            }
            // One request, and it went to *our* host. A followed redirect would
            // show as a second recorded call or as none at all.
            #expect(calls.count == 1)
            #expect(calls.hosts == [session.host])
        }
    }

    // MARK: - Authentication generation

    @Test("a kickoff answered under a changed authentication generation is refused, not published")
    func aChangedAuthGenerationRefusesPublication() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try keychain.setString("generation-one", forKey: KeychainKey.authToken)
        let api = makeClient(session: session, keychain: keychain)
        let calls = UploadCallLedger()
        session.install { req in
            calls.record(req)
            // The session changes underneath the upload — a logout, an account
            // switch, a refresh — while the body is on the wire.
            try? keychain.setString("generation-two", forKey: KeychainKey.authToken)
            let body = #"{"data":{"jobId":"ij-other-session","status":"queued"}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let scratch = try Phase09Scratch("09-02-generation")
        let (file, bytes) = try makeBodyFile(scratch)
        await #expect(throws: HLError.unauthorized) {
            _ = try await api.uploadFile(self.makeRequest(file: file, byteCount: bytes))
        }
        // The request happened exactly once — this is a refusal to publish the
        // answer, not a failure to ask.
        #expect(calls.count == 1)
    }

    // MARK: - No conformer buffers by accident

    @Test("the protocol's default implementation refuses rather than buffering")
    func theDefaultImplementationRefuses() async throws {
        let scratch = try Phase09Scratch("09-02-default")
        let (file, bytes) = try makeBodyFile(scratch)
        let stub: any APIClientProtocol = NonUploadingClient()
        await #expect(throws: (any Error).self) {
            _ = try await stub.uploadFile(APIFileUploadRequest<AppleHealthImportKickoffDTO>(
                method: .post,
                path: APIClientFileUploadTests.uploadPath,
                bodyFileURL: file,
                byteCount: bytes,
                contentType: "multipart/form-data; boundary=B"
            ))
        }
    }
}

// MARK: - Handler-side ledgers (Plan 09-11: `Mutex`, never an unchecked promise)

/// Endpoint-agnostic on purpose here: every case above installs its handler on
/// its **own** session, so a request that reaches this ledger is by
/// construction one of this test's. The counts are still positive assertions —
/// a `0` would mean the transport never arrived.
private final class UploadCallLedger: Sendable {
    private struct Recorded {
        var contentTypes: [String] = []
        var hosts: [String] = []
        var inMemoryBodyByteCounts: [Int?] = []
    }

    private let state = Mutex(Recorded())

    func record(_ request: URLRequest) {
        state.withLock {
            $0.contentTypes.append(request.value(forHTTPHeaderField: "Content-Type") ?? "")
            $0.hosts.append(request.url?.host ?? "")
            $0.inMemoryBodyByteCounts.append(request.httpBody?.count)
        }
    }

    var count: Int {
        state.withLock { $0.hosts.count }
    }

    var contentTypes: [String] {
        state.withLock { $0.contentTypes }
    }

    var hosts: [String] {
        state.withLock { $0.hosts }
    }

    var inMemoryBodyByteCounts: [Int?] {
        state.withLock { $0.inMemoryBodyByteCounts }
    }
}

private final class Counter: Sendable {
    private let stored = Mutex(0)
    func bump() {
        stored.withLock { $0 += 1 }
    }

    var value: Int {
        stored.withLock { $0 }
    }
}

private final class RedirectDecisionBox: Sendable {
    private let stored = Mutex<URLRequest?>(nil)
    func record(_ request: URLRequest?) {
        stored.withLock { $0 = request }
    }

    var value: URLRequest? {
        stored.withLock { $0 }
    }
}

/// A conformer that implements nothing beyond the protocol's requirements, so
/// the throwing default is what answers.
private struct NonUploadingClient: APIClientProtocol {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.unknown("unused")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("unused")
    }
}

// swiftlint:enable force_unwrapping
