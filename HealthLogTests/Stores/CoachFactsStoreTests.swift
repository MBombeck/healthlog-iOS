import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// Thread-safe counter for handler-side bookkeeping. The handler closure is
/// `@Sendable` and runs on the URL-loading queue, so the count sits behind a
/// `Mutex` — checked concurrency rather than a hand-written promise the
/// compiler cannot verify. Since Plan 09-11 it is also owned by one session, so
/// nothing but that session's own requests can move it.
private final class Counter: Sendable {
    private let count = Mutex(0)

    func bump() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

/// File-scope on purpose: the suite is `@MainActor`, and a `@Sendable` handler
/// closure running on the URL-loading queue cannot call a main-actor member.
private func respond(_ req: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
    let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (http, Data(json.utf8))
}

/// **v0.14.2 FW5-C — CoachFactsStore (coach memory) state-machine.**
///
/// Drives the store through the real `APIClient` + stubbed `URLSession` so the
/// store→repo→wire contract is exercised end-to-end. Pins:
///   - load populates `facts` + groups them by category,
///   - the disabled Coach surface flips `isCoachDisabled` (calm placeholder),
///     NOT `error`,
///   - forget removes the fact locally,
///   - forgetAll clears the list.
@Suite("CoachFactsStore", .serialized)
@MainActor
struct CoachFactsStoreTests {
    /// The transport seam (issue #82 / Plan 09-11). Both halves come from the
    /// caller's retained session, so every request this client makes is answered
    /// by that session's handler or by nothing at all.
    ///
    /// `baseURL: session.baseURL` is the load-bearing half, and it is not
    /// interchangeable with the configuration. `APIClient.init` assigns
    /// `config.httpAdditionalHeaders` **wholesale** on the configuration object
    /// it is handed, before its `URLSession` exists, so the session token is gone
    /// by the time the first request is built. Keeping the old hard-coded host
    /// here while passing `session.configuration` would leave every request
    /// untagged on a host that is not a session host — answered by the legacy
    /// process-global slot, with this suite's handlers installed and never
    /// reached. `MockURLProtocolIsolationTests.aSessionConfigurationAloneDoesNotMigrateAClient`
    /// pins exactly that trap.
    private func makeAPI(session: MockURLProtocolSession) -> APIClient {
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
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
    }

    @Test("load populates facts grouped by category")
    func loadGroups() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeAPI(session: session)
        session.install { req in
            let payload = """
            {"data":{"facts":[\
            {"id":"f1","category":"preferences","text":"Metric units","confidence":0.9,"createdAt":"2026-06-04T10:00:00Z"},\
            {"id":"f2","category":"preferences","text":"Dark mode","confidence":0.8,"createdAt":"2026-06-04T09:00:00Z"},\
            {"id":"f3","category":"routine","text":"Morning workouts","confidence":0.7,"createdAt":"2026-06-03T08:00:00Z"}\
            ]},"error":null}
            """
            return respond(req, payload)
        }
        let store = CoachFactsStore(repo: CoachFactsRepository(api: api))
        await store.load()
        #expect(store.facts.count == 3)
        #expect(!store.isCoachDisabled)
        #expect(store.error == nil)
        let groups = store.groupedByCategory
        #expect(groups.count == 2)
        #expect(groups[0].category == "preferences")
        #expect(groups[0].facts.count == 2)
        #expect(groups[1].category == "routine")
    }

    @Test("a disabled Coach surface flips isCoachDisabled, not error")
    func disabledSurface() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeAPI(session: session)
        session.install { req in
            let payload = #"{"data":null,"error":"Coach is disabled","errorCode":"assistant.disabled.coach"}"#
            return respond(req, payload, status: 403)
        }
        let store = CoachFactsStore(repo: CoachFactsRepository(api: api))
        await store.load()
        #expect(store.isCoachDisabled)
        #expect(store.error == nil)
        #expect(store.facts.isEmpty)
    }

    @Test("forget removes the fact locally on a confirmed delete")
    func forgetRemovesLocally() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let api = makeAPI(session: session)
        // First call: list. Subsequent: delete.
        //
        // The counter used to be an unsafely-nonisolated `var` captured by a
        // `@Sendable` closure installed on the process-global slot — unsound on
        // both axes: unsynchronized, and movable by any suite running in
        // parallel. It is now `Mutex`-backed and reachable only through this
        // test's own session, and it is additionally gated on the endpoint so
        // the assertion says "my route was called twice", not "two requests
        // happened somewhere".
        let calls = Counter()
        session.install { req in
            guard req.targets(prefixedBy: "/api/insights/coach/facts") else { return respond(req, "{}") }
            calls.bump()
            let payload = if req.httpMethod == "DELETE" {
                #"{"data":{"deleted":true},"error":null}"#
            } else {
                """
                {"data":{"facts":[\
                {"id":"f1","category":"health","text":"Sleeps 7h","confidence":0.9,"createdAt":"2026-06-04T10:00:00Z"}\
                ]},"error":null}
                """
            }
            return respond(req, payload)
        }
        let store = CoachFactsStore(repo: CoachFactsRepository(api: api))
        await store.load()
        #expect(store.facts.count == 1)
        let fact = store.facts[0]
        await store.forget(fact)
        #expect(store.facts.isEmpty)
        #expect(store.error == nil)
        // The list and the delete, both answered by this test's own session.
        #expect(calls.value == 2)
    }

    // MARK: - Transport ownership (issue #82 / Plan 09-11)

    @Test("a handler installed after ours cannot answer this suite's request")
    func aLaterInstallCannotAnswerThisSuite() async {
        // The failure this migration removes: a suite running in parallel
        // replaces the handler between our install and our request, so our
        // request is answered by a foreign closure and our counter stays at
        // zero. Here the foreign install happens *after* ours — deterministically
        // the losing order under one process-global slot — and must still not be
        // reached.
        let session = MockURLProtocolSession()
        let foreign = MockURLProtocolSession()
        defer {
            session.invalidate()
            foreign.invalidate()
        }
        let mine = Counter()
        let theirs = Counter()
        session.install { req in
            guard req.targets("/api/insights/coach/facts") else { return respond(req, "{}") }
            mine.bump()
            return respond(req, #"{"data":{"facts":[]},"error":null}"#)
        }
        foreign.install { req in
            theirs.bump()
            return respond(req, "{}")
        }

        let store = CoachFactsStore(repo: CoachFactsRepository(api: makeAPI(session: session)))
        await store.load()

        // A positive count is the whole point. `store.error == nil` and an empty
        // fact list are produced just as well by a request that never arrived,
        // so only the count proves this suite was routed to its own session.
        #expect(mine.value == 1, "EXPECTED_RED: CoachFactsStoreTests was not routed to its own session")
        #expect(theirs.value == 0)
    }
}
