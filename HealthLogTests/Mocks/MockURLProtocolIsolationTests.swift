import Foundation
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// One type holds the whole transport contract on purpose. The 09-10 properties
// and the 09-13 routing properties share the same fixtures — the responder, the
// two-party barrier, the overlap round — and every
// case is asserted through both channels against the same session shape.
// Splitting them into two suites would duplicate that scaffolding and let the
// two halves drift, which is the failure this file exists to prevent.
// swiftlint:disable force_unwrapping type_body_length
import Testing

/// The isolation contract for ``MockURLProtocolSession`` (Plan 09-10, issue #82).
///
/// The property under test is that *my* request is answered by *my* handler,
/// even while another live session has installed a different one — and that
/// nothing answers a request no session owns. Since C2 there is no
/// process-global slot left to fall back to.
///
/// The failure is made deterministic rather than probabilistic. A schedule
/// race would produce a test that is red on this machine and green on the
/// next, which is not a proof of anything. Instead the install order is fixed
/// — A, then B — and only the two *requests* are made to overlap, behind a
/// barrier that releases them together. Under the old process-global slot the
/// second install won for both sessions on every one of the 100 rounds, so
/// the count of wrong answers was exactly 100, never 0, and never 37.
@Suite("MockURLProtocol session isolation", .serialized)
struct MockURLProtocolIsolationTests {
    /// Overlap rounds. Large enough that a lucky ordering cannot carry the
    /// suite, small enough to stay well inside the focused gate's budget.
    private static let rounds = 100

    /// Releases exactly `party` waiters together, so both requests are in
    /// flight before either can be answered.
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

    private func responder(_ marker: String) -> MockURLProtocol.Handler {
        { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(marker.utf8))
        }
    }

    /// Which routing channel carries a request. Naming them is the point: each
    /// has to carry a request **on its own**, so every isolation property below
    /// is asserted twice rather than once through whichever channel happens to
    /// be present.
    ///
    /// * `.configuration` — the shared `mock.invalid` host, reached through the
    ///   session's own configuration (its per-session protocol class). No URL
    ///   convention involved.
    /// * `.host` — the session's own opaque address, reached through a
    ///   configuration that carries only the bare `MockURLProtocol` and so
    ///   names no session at all.
    private enum Channel {
        case configuration
        case host
    }

    /// A configuration bound to no session: the bare base class.
    private func unboundConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    private func url(for session: MockURLProtocolSession, path: String, via channel: Channel) -> URL {
        switch channel {
        case .configuration: URL(string: "https://mock.invalid" + path)!
        case .host: URL(string: session.baseURL.absoluteString + path)!
        }
    }

    private func body(
        from session: MockURLProtocolSession,
        path: String,
        via channel: Channel = .configuration,
        after barrier: Barrier? = nil
    ) async throws -> String {
        let configuration: URLSessionConfiguration = switch channel {
        case .configuration: session.configuration
        case .host: unboundConfiguration()
        }
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.finishTasksAndInvalidate() }
        if let barrier { await barrier.arrive() }
        let (data, _) = try await urlSession.data(from: url(for: session, path: path, via: channel))
        return String(bytes: data, encoding: .utf8) ?? "<undecodable>"
    }

    /// One barrier-controlled round: install A, then B, then let both requests
    /// overlap. Returns what each session was actually answered with.
    private func overlapRound(
        _ sessionA: MockURLProtocolSession,
        _ sessionB: MockURLProtocolSession,
        via channel: Channel
    ) async throws -> (a: String, b: String) {
        sessionA.install(responder("A"))
        sessionB.install(responder("B"))

        let barrier = Barrier(party: 2)
        var answers: [String: String] = [:]
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            group.addTask {
                let answer = try await body(from: sessionA, path: "/a", via: channel, after: barrier)
                return ("a", answer)
            }
            group.addTask {
                let answer = try await body(from: sessionB, path: "/b", via: channel, after: barrier)
                return ("b", answer)
            }
            for try await (key, value) in group {
                answers[key] = value
            }
        }
        return (answers["a"] ?? "<missing>", answers["b"] ?? "<missing>")
    }

    @Test("two concurrent sessions keep distinct handlers")
    func twoConcurrentSessionsKeepDistinctHandlers() async throws {
        let sessionA = MockURLProtocolSession()
        let sessionB = MockURLProtocolSession()
        defer {
            sessionA.invalidate()
            sessionB.invalidate()
        }

        var wrongForA = 0
        var wrongForB = 0
        var firstAnswerToA = ""
        for round in 0 ..< Self.rounds {
            let answers = try await overlapRound(sessionA, sessionB, via: .configuration)
            if round == 0 { firstAnswerToA = answers.a }
            if answers.a != "A" { wrongForA += 1 }
            if answers.b != "B" { wrongForB += 1 }
        }

        // One assertion, after all rounds. Asserting inside the loop would
        // print the marker up to 100 times, and the RED gate requires the
        // expected reason to appear exactly once.
        #expect(
            wrongForA == 0,
            "EXPECTED_RED: MockURLProtocol handler is still process-global"
        )
        #expect(wrongForB == 0)
        #expect(firstAnswerToA == "A" || firstAnswerToA == "B")
    }

    @Test("a lone session answers its own request")
    func aLoneSessionAnswersItsOwnRequest() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.install(responder("solo"))
        let answer = try await body(from: session, path: "/solo")
        #expect(answer == "solo")
    }

    @Test("a session with no handler fails closed instead of hanging")
    func aSessionWithoutAHandlerFailsClosed() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.invalidate()
        await #expect(throws: (any Error).self) {
            _ = try await body(from: session, path: "/nothing")
        }
    }

    @Test("a session hands out a configuration carrying its own protocol class")
    func configurationRoutesThroughTheMockProtocol() throws {
        let session = MockURLProtocolSession()
        let other = MockURLProtocolSession()
        defer {
            session.invalidate()
            other.invalidate()
        }
        let classes = try #require(session.configuration.protocolClasses)
        #expect(classes.count == 1)
        #expect(classes.contains { ObjectIdentifier($0) == ObjectIdentifier(session.protocolClass) })
        let superclass: AnyClass = try #require(class_getSuperclass(session.protocolClass))
        #expect(ObjectIdentifier(superclass) == ObjectIdentifier(MockURLProtocol.self))
        #expect(ObjectIdentifier(session.protocolClass) != ObjectIdentifier(other.protocolClass))
        #expect(MockURLProtocolSession.owner(forProtocolClass: session.protocolClass) === session)
        #expect(!session.token.isEmpty)
        #expect(other.token != session.token)
    }

    @Test("replacing or invalidating one session cannot alter another")
    func replacingOneSessionLeavesTheOtherAlone() async throws {
        let sessionA = MockURLProtocolSession()
        let sessionB = MockURLProtocolSession()
        defer {
            sessionA.invalidate()
            sessionB.invalidate()
        }
        sessionA.install(responder("A1"))
        sessionB.install(responder("B1"))
        let firstA = try await body(from: sessionA, path: "/a")

        sessionB.install(responder("B2"))
        let afterReplacementA = try await body(from: sessionA, path: "/a")
        let afterReplacementB = try await body(from: sessionB, path: "/b")

        sessionB.invalidate()
        let afterInvalidationA = try await body(from: sessionA, path: "/a")

        #expect(firstA == "A1")
        #expect(afterReplacementA == "A1")
        #expect(afterReplacementB == "B2")
        #expect(afterInvalidationA == "A1")
    }

    @Test("an invalidated session cannot leak into a later one")
    func anInvalidatedSessionCannotLeak() async throws {
        let stale = MockURLProtocolSession()
        stale.install(responder("STALE"))
        let staleConfiguration = stale.configuration
        stale.invalidate()

        // The retired configuration still carries its token. The request must
        // fail closed rather than be answered by anybody at all.
        let retired = URLSession(configuration: staleConfiguration)
        defer { retired.finishTasksAndInvalidate() }
        await #expect(throws: (any Error).self) {
            _ = try await retired.data(from: #require(URL(string: "https://mock.invalid/stale")))
        }

        let fresh = MockURLProtocolSession()
        defer { fresh.invalidate() }
        fresh.install(responder("FRESH"))
        let answer = try await body(from: fresh, path: "/fresh")
        #expect(answer == "FRESH")
    }

    /// There is no fallback. A request that names no session — the bare base
    /// class, the shared host — is refused even while a live session with a
    /// handler exists, and that session is not consulted.
    @Test("a request bound to no session fails closed")
    func aRequestBoundToNoSessionFailsClosed() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.install(responder("SESSION"))

        let unbound = URLSession(configuration: unboundConfiguration())
        defer { unbound.finishTasksAndInvalidate() }
        let sharedURL = try #require(URL(string: "https://mock.invalid/nobody"))
        await #expect(throws: (any Error).self) {
            _ = try await unbound.data(from: sharedURL)
        }

        let viaConfiguration = try await body(from: session, path: "/mine", via: .configuration)
        let viaHost = try await body(from: session, path: "/mine", via: .host)
        #expect(viaConfiguration == "SESSION")
        #expect(viaHost == "SESSION")
    }

    // MARK: - Plan 09-13 — the client every migration target actually uses

    /// The transport seam a migrated suite adopts, spelled exactly once here so
    /// this suite proves the same shape 09-11 and 09-12 will write: the base URL
    /// comes from the session, the configuration comes from the session, and the
    /// client is the real production `APIClient` — not a stub, not a bare
    /// `URLSession`.
    private func client(for session: MockURLProtocolSession) -> APIClient {
        let environment = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.0.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: environment,
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
    }

    /// One GET through the real client, with the transport error folded into
    /// the observed value. A thrown error would fail the case without printing
    /// the expected reason, and the RED gate matches on that reason.
    private func body(from api: APIClient, path: String) async -> String {
        do {
            let (data, _) = try await api.download(
                APIRequest<Data>(method: .get, path: path, maxRetries: 0)
            )
            return String(bytes: data, encoding: .utf8) ?? "<undecodable>"
        } catch {
            return "<threw \(error)>"
        }
    }

    /// The one client every suite uses, addressed through the session's host.
    @Test("a real APIClient is answered by its own session")
    func aRealAPIClientIsAnsweredByItsOwnSession() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.install(responder("SESSION-ROUTED"))
        let api = client(for: session)
        let observed = await body(from: api, path: "/api/session-routed")

        #expect(
            observed == "SESSION-ROUTED",
            "EXPECTED_RED: a real APIClient was not routed to its own session, observed \(observed)"
        )
    }

    /// The address is an exact, opaque namespace: one label per session, below
    /// a suffix no production code names. The bare `mock.invalid` is **not** a
    /// session host.
    @Test("a session address is an opaque per-session host")
    func aSessionAddressIsAnOpaquePerSessionHost() {
        let session = MockURLProtocolSession()
        let other = MockURLProtocolSession()
        defer {
            session.invalidate()
            other.invalidate()
        }

        #expect(session.token == session.token.lowercased())
        #expect(session.host == session.token + MockURLProtocolSession.hostSuffix)
        #expect(session.baseURL.host == session.host)
        #expect(session.baseURL.scheme == "https")
        #expect(session.host != other.host)
        #expect(MockURLProtocolSession.isSessionHost(session.host))
        #expect(MockURLProtocolSession.owner(forHost: session.host) === session)
        #expect(MockURLProtocolSession.owner(forHost: session.host.uppercased()) === session)
        #expect(!MockURLProtocolSession.isSessionHost("mock.invalid"))
        #expect(!MockURLProtocolSession.isSessionHost(".mock.invalid"))
        #expect(!MockURLProtocolSession.isSessionHost("test.healthlog.local"))
        #expect(MockURLProtocolSession.owner(forHost: "mock.invalid") == nil)
    }

    /// The host channel's isolation property, proven the same way 09-10 proved
    /// the configuration channel's: fixed install order, only the two requests
    /// overlapping behind a two-party barrier, so the result is deterministic
    /// instead of a schedule race that is red here and green on the next
    /// machine. Both configurations are unbound here — nothing but the address
    /// distinguishes the two requests.
    @Test("two concurrent sessions keep distinct host-routed handlers")
    func twoConcurrentSessionsKeepDistinctHostRoutedHandlers() async throws {
        let sessionA = MockURLProtocolSession()
        let sessionB = MockURLProtocolSession()
        defer {
            sessionA.invalidate()
            sessionB.invalidate()
        }

        var wrongForA = 0
        var wrongForB = 0
        for _ in 0 ..< Self.rounds {
            let answers = try await overlapRound(sessionA, sessionB, via: .host)
            if answers.a != "A" { wrongForA += 1 }
            if answers.b != "B" { wrongForB += 1 }
        }

        #expect(wrongForA == 0)
        #expect(wrongForB == 0)
    }

    /// Fail-closed, host edition. An address whose owner is gone is refused,
    /// even through a configuration that belongs to a live session with a
    /// handler — the address is resolved first and names nobody.
    @Test("an unresolvable session host fails closed")
    func anUnresolvableSessionHostFailsClosed() async throws {
        let stale = MockURLProtocolSession()
        stale.install(responder("STALE"))
        let staleBase = stale.baseURL
        stale.invalidate()

        let live = MockURLProtocolSession()
        defer { live.invalidate() }
        live.install(responder("LIVE"))

        let plain = URLSession(configuration: live.configuration)
        defer { plain.finishTasksAndInvalidate() }
        let staleURL = try #require(URL(string: staleBase.absoluteString + "/gone"))

        await #expect(throws: (any Error).self) {
            _ = try await plain.data(from: staleURL)
        }
    }

    /// Resolution order, pinned. The two channels normally name the same
    /// session because they come from the same object; crossing them on purpose
    /// is the only way to observe the order, and the address wins, because it
    /// is what the test author wrote at the call site.
    @Test("the host channel is resolved before the protocol-class channel")
    func theHostChannelIsResolvedBeforeTheProtocolClassChannel() async throws {
        let sessionA = MockURLProtocolSession()
        let sessionB = MockURLProtocolSession()
        defer {
            sessionA.invalidate()
            sessionB.invalidate()
        }
        sessionA.install(responder("A"))
        sessionB.install(responder("B"))

        // A's address, B's configuration.
        let crossed = URLSession(configuration: sessionB.configuration)
        defer { crossed.finishTasksAndInvalidate() }
        let crossedURL = try #require(URL(string: sessionA.baseURL.absoluteString + "/x"))
        let (data, _) = try await crossed.data(from: crossedURL)

        #expect(String(bytes: data, encoding: .utf8) == "A")
    }

    /// `APIClient.init` mutates the configuration object it is handed. The
    /// session hands out a fresh one every time, so building a client leaves
    /// every later consumer of the same session routed.
    @Test("constructing an APIClient does not disarm the session")
    func constructingAnAPIClientDoesNotDisarmTheSession() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.install(responder("STILL-MINE"))

        let api = client(for: session)
        let viaClient = await body(from: api, path: "/api/via-client")
        let viaConfiguration = try await body(from: session, path: "/after-client", via: .configuration)
        let viaHost = try await body(from: session, path: "/after-client", via: .host)

        #expect(viaClient == "STILL-MINE")
        #expect(viaConfiguration == "STILL-MINE")
        #expect(viaHost == "STILL-MINE")
    }

    @Test("the session registry holds its sessions weakly")
    func theRegistryHoldsSessionsWeakly() throws {
        var scoped: MockURLProtocolSession? = MockURLProtocolSession()
        let token = try #require(scoped?.token)
        #expect(MockURLProtocolSession.owner(for: token) != nil)
        let whileLive = MockURLProtocolSession.liveSessionCount

        scoped = nil
        #expect(MockURLProtocolSession.owner(for: token) == nil)
        #expect(MockURLProtocolSession.liveSessionCount < whileLive)
    }

    /// Until C2 this case pinned the opposite: a session configuration with a
    /// hard-coded host was *not* routed, because `APIClient.init` replaces the
    /// caller's `httpAdditionalHeaders` and the token rode in a header. The
    /// per-session protocol class rides in `protocolClasses`, which the client
    /// copies to all its sessions, so the configuration alone is now enough —
    /// which is what lets `.mock()` bind a suite without touching its base URL.
    @Test("a session configuration alone routes a real APIClient")
    func aSessionConfigurationAloneRoutesAClient() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.install(responder("SESSION"))

        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "0.0.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: environment,
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
        let observed = await body(from: api, path: "/api/hard-coded-host")

        #expect(observed == "SESSION", "a hard-coded base URL was not routed to the session; observed \(observed)")
    }
}

// swiftlint:enable force_unwrapping type_body_length
