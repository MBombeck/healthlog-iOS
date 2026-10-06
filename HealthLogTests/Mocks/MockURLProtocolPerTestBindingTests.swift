import Foundation
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif
import Testing

// swiftlint:disable force_unwrapping

/// `.mockURLSession`, `.mock()` and `MockURLProtocol.install` — the three names
/// every migrated suite writes (C2, issue #82). The session contract itself is
/// pinned in `MockURLProtocolIsolationTests`; this suite pins the binding that
/// hands one session to each test case.
@Suite("MockURLProtocol per-test binding", .mockURLSession)
struct MockURLProtocolPerTestBindingTests {
    /// Releases exactly `party` waiters together.
    private actor Barrier {
        private let party: Int
        private var arrived = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(party: Int) {
            self.party = party
        }

        func arrive() async {
            arrived += 1
            if arrived >= party {
                let released = waiters
                waiters = []
                arrived = 0
                for waiter in released {
                    waiter.resume()
                }
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Captured in `init`, because several suites install their handler there:
    /// the scope must already be open when the suite is built.
    private let boundAtInit = MockURLProtocolSession.current

    private static func answer(_ marker: String) -> MockURLProtocol.Handler {
        { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(marker.utf8))
        }
    }

    private static func client(_ configuration: URLSessionConfiguration) -> APIClient {
        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "0.0.0",
            buildNumber: "1"
        )
        return APIClient(environment: environment, keychain: InMemoryKeychain(), sessionConfiguration: configuration)
    }

    private static func get(_ api: APIClient, _ path: String) async -> String {
        do {
            let (data, _) = try await api.download(APIRequest<Data>(method: .get, path: path, maxRetries: 0))
            return String(bytes: data, encoding: .utf8) ?? "<undecodable>"
        } catch {
            return "<threw \(error)>"
        }
    }

    @Test("the scope is open in the suite's init and in the test body")
    func theScopeIsOpenInInitAndBody() throws {
        let current = try #require(MockURLProtocolSession.current)
        #expect(boundAtInit === current)
    }

    @Test("mock() and install bind a real APIClient to this test's session")
    func mockAndInstallBindARealClient() async throws {
        let current = try #require(MockURLProtocolSession.current)
        MockURLProtocol.install(Self.answer("CURRENT"))
        let configuration = URLSessionConfiguration.mock()
        let classes = try #require(configuration.protocolClasses)
        #expect(classes.contains { ObjectIdentifier($0) == ObjectIdentifier(current.protocolClass) })
        #expect(await Self.get(Self.client(configuration), "/api/bound") == "CURRENT")
    }

    /// Two task scopes, two sessions, one fixed install order, and the two
    /// requests released together — the same deterministic shape as the session
    /// contract, now through `.mock()` and `install`, which resolve the binding
    /// at the call.
    @Test("two concurrent scopes keep distinct handlers through mock() and install")
    func twoConcurrentScopesKeepDistinctHandlers() async {
        var wrong = 0
        for _ in 0 ..< 50 {
            let sessionA = MockURLProtocolSession()
            let sessionB = MockURLProtocolSession()
            defer {
                sessionA.invalidate()
                sessionB.invalidate()
            }
            let apiA = MockURLProtocolSession.$current.withValue(sessionA) {
                MockURLProtocol.install(Self.answer("A"))
                return Self.client(.mock())
            }
            let apiB = MockURLProtocolSession.$current.withValue(sessionB) {
                MockURLProtocol.install(Self.answer("B"))
                return Self.client(.mock())
            }
            let barrier = Barrier(party: 2)
            async let answerA: String = {
                await barrier.arrive()
                return await Self.get(apiA, "/a")
            }()
            async let answerB: String = {
                await barrier.arrive()
                return await Self.get(apiB, "/b")
            }()
            let (a, b) = await (answerA, answerB)
            if a != "A" { wrong += 1 }
            if b != "B" { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    /// A request that reaches a live session with nothing installed is refused
    /// *and remembered*, so the trait can name it at the end of the test instead
    /// of the test passing on an error it never meant to see.
    @Test("a request with no handler installed is refused and remembered")
    func aRequestWithoutAHandlerIsRemembered() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let observed = await Self.get(Self.client(session.configuration), "/api/unhandled")
        #expect(observed.hasPrefix("<threw"))
        #expect(session.unhandledRequests == ["GET /api/unhandled"])
    }
}

// swiftlint:enable force_unwrapping
