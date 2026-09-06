import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// #5 — the daily forced re-login, reproduced at the seam where it happened.
///
/// The 24 h access token expires while a dozen requests are on the wire. They
/// all get 401, single-flight folds them onto ONE rotation (A → B) and they
/// replay with B. Meanwhile a straggler that left with A gets `401 revoked`,
/// rotates a SECOND time (B → C) and revokes B — so the replays come back 401
/// for a bearer that was valid when they were built. `APIClient` allows one
/// refresh per request, had already spent it, and fired `onUnauthorized`:
/// a full logout, every morning, without the server ever rejecting a refresh.
///
/// The rule these cases pin: **a 401 for a bearer the session has already
/// replaced is not an auth verdict.** It is answered by rebuilding the request
/// with the current bearer — once, without spending the refresh — and only a
/// 401 for the CURRENT bearer still means the session is dead.
@Suite("#5 — a 401 for a superseded bearer must not log the user out")
struct APIClientRotationRaceTests {
    // MARK: - Harness

    /// The transport's bookkeeping: which bearers were actually sent, in
    /// order, plus the refresh/logout counts. Lock-protected because the
    /// handler runs on URLSession's queue.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var bearers: [String] = []
        private var refreshes = 0
        private var logouts = 0

        func recordBearer(_ bearer: String?) {
            lock.lock()
            defer { lock.unlock() }
            bearers.append(bearer ?? "<none>")
        }

        func recordRefresh() {
            lock.lock()
            defer { lock.unlock() }
            refreshes += 1
        }

        func recordLogout() {
            lock.lock()
            defer { lock.unlock() }
            logouts += 1
        }

        var sentBearers: [String] {
            lock.lock()
            defer { lock.unlock() }
            return bearers
        }

        var refreshCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return refreshes
        }

        var logoutCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return logouts
        }
    }

    /// Hands out "B", "C", "D", … so a case can rotate on every single
    /// response without repeating a bearer.
    private final class BearerMint: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        private let names = ["B", "C", "D", "E", "F", "G", "H"]

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            let name = names[min(index, names.count - 1)]
            index += 1
            return name
        }
    }

    /// The bearer a request carried, without the scheme — "A", "B", …
    private static func bearer(of request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "")
    }

    private static func reply(_ status: Int, to request: URLRequest) -> (HTTPURLResponse, Data?) {
        let body = status == 200
            ? #"{"data":null,"error":null}"#
            : #"{"data":null,"error":"Invalid token"}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(body.utf8))
    }

    private func makeAPI(
        session: MockURLProtocolSession,
        keychain: InMemoryKeychain,
        refreshHandler: (@Sendable () async -> RefreshOutcome)? = nil,
        onUnauthorized: (@Sendable () async -> Void)? = nil
    ) -> APIClient {
        let environment = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: environment,
            keychain: keychain,
            sessionConfiguration: session.configuration,
            onUnauthorized: onUnauthorized,
            refreshHandler: refreshHandler
        )
    }

    /// The route under test: an ordinary authenticated read, the shape the
    /// field reports died on.
    private static let route = "/api/measurements"

    // MARK: - Cases

    @Test("The field case: a concurrent second rotation is retried, not logged out")
    func doubleRotationIsRetriedWithTheCurrentBearer() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try? keychain.setString("A", forKey: KeychainKey.authToken)
        let ledger = Ledger()

        let api = makeAPI(
            session: session,
            keychain: keychain,
            refreshHandler: { @Sendable in
                ledger.recordRefresh()
                try? keychain.setString("B", forKey: KeychainKey.authToken)
                return .refreshed
            },
            onUnauthorized: { @Sendable in ledger.recordLogout() }
        )

        session.install { request in
            let bearer = Self.bearer(of: request)
            ledger.recordBearer(bearer)
            switch bearer {
            case "A":
                // The 24 h expiry. The client refreshes A → B and replays.
                return Self.reply(401, to: request)
            case "B":
                // The straggler's rotation lands while this replay is on the
                // wire: B is revoked and the session is already on C.
                try? keychain.setString("C", forKey: KeychainKey.authToken)
                return Self.reply(401, to: request)
            default:
                return Self.reply(200, to: request)
            }
        }

        let request = APIRequest<EmptyPayload>(method: .get, path: Self.route)
        do {
            try await api.sendVoid(request)
        } catch {
            Issue.record("the request must survive the double rotation, got \(error)")
        }

        #expect(ledger.sentBearers == ["A", "B", "C"], "the retry must carry the bearer the session actually holds")
        #expect(ledger.refreshCount == 1, "the second rotation was somebody else's — this request must not spend a refresh")
        #expect(ledger.logoutCount == 0, "this is the daily forced re-login; it must not happen")
    }

    @Test("A straggler sent with a superseded bearer refreshes nothing")
    func supersededBearerRetriesWithoutRefreshing() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try? keychain.setString("A", forKey: KeychainKey.authToken)
        let ledger = Ledger()

        let api = makeAPI(
            session: session,
            keychain: keychain,
            refreshHandler: { @Sendable in
                ledger.recordRefresh()
                return .refreshed
            },
            onUnauthorized: { @Sendable in ledger.recordLogout() }
        )

        session.install { request in
            let bearer = Self.bearer(of: request)
            ledger.recordBearer(bearer)
            guard bearer == "A" else { return Self.reply(200, to: request) }
            // Somebody else rotated while this request was in flight.
            try? keychain.setString("B", forKey: KeychainKey.authToken)
            return Self.reply(401, to: request)
        }

        let request = APIRequest<EmptyPayload>(method: .get, path: Self.route)
        do {
            try await api.sendVoid(request)
        } catch {
            Issue.record("a straggler must simply re-send with the current bearer, got \(error)")
        }

        #expect(ledger.sentBearers == ["A", "B"])
        #expect(ledger.refreshCount == 0, "the session is already fresh — refreshing again is the rotation storm")
        #expect(ledger.logoutCount == 0)
    }

    @Test("A genuine rejection of the current bearer still logs out")
    func rejectionOfTheCurrentBearerStillLogsOut() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try? keychain.setString("A", forKey: KeychainKey.authToken)
        let ledger = Ledger()

        let api = makeAPI(
            session: session,
            keychain: keychain,
            refreshHandler: { @Sendable in
                ledger.recordRefresh()
                try? keychain.setString("B", forKey: KeychainKey.authToken)
                return .refreshed
            },
            onUnauthorized: { @Sendable in ledger.recordLogout() }
        )

        // Every bearer is rejected and the Keychain is never moved behind the
        // request's back: each 401 is a verdict on the bearer that was sent.
        session.install { request in
            ledger.recordBearer(Self.bearer(of: request))
            return Self.reply(401, to: request)
        }

        let request = APIRequest<EmptyPayload>(method: .get, path: Self.route)
        do {
            try await api.sendVoid(request)
            Issue.record("a dead session must still surface as .unauthorized")
        } catch let error as HLError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(ledger.sentBearers == ["A", "B"])
        #expect(ledger.refreshCount == 1)
        #expect(ledger.logoutCount == 1, "the fix must not swallow a real auth failure")
    }

    @Test("The rotation retry is bounded")
    func rotationRetryIsBounded() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try? keychain.setString("A", forKey: KeychainKey.authToken)
        let ledger = Ledger()
        let mint = BearerMint()

        let api = makeAPI(
            session: session,
            keychain: keychain,
            refreshHandler: { @Sendable in
                ledger.recordRefresh()
                try? keychain.setString(mint.next(), forKey: KeychainKey.authToken)
                return .refreshed
            },
            onUnauthorized: { @Sendable in ledger.recordLogout() }
        )

        // Pathological server: every answer is a 401 AND every answer moves the
        // session on, so the bearer is superseded forever. Without a bound this
        // is an infinite request loop.
        session.install { request in
            ledger.recordBearer(Self.bearer(of: request))
            try? keychain.setString(mint.next(), forKey: KeychainKey.authToken)
            return Self.reply(401, to: request)
        }

        let request = APIRequest<EmptyPayload>(method: .get, path: Self.route)
        do {
            try await api.sendVoid(request)
            Issue.record("expected the client to give up")
        } catch let error as HLError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(ledger.sentBearers.count <= 4, "one rotation retry + one refresh retry, and then it is over")
        #expect(ledger.logoutCount == 1)
    }

    @Test("Auth-exempt routes are untouched by the rotation retry")
    func authExemptRoutesDoNotRetryOnRotation() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try? keychain.setString("A", forKey: KeychainKey.authToken)
        let ledger = Ledger()

        let api = makeAPI(
            session: session,
            keychain: keychain,
            refreshHandler: { @Sendable in
                ledger.recordRefresh()
                return .refreshed
            },
            onUnauthorized: { @Sendable in ledger.recordLogout() }
        )

        session.install { request in
            ledger.recordBearer(Self.bearer(of: request))
            // Even with the session moving underneath it, a login 401 is a
            // login 401 — there is no session to be superseded here.
            try? keychain.setString("B", forKey: KeychainKey.authToken)
            return Self.reply(401, to: request)
        }

        let request = APIRequest<EmptyPayload>(method: .post, path: "/api/auth/login", body: Data("{}".utf8))
        do {
            try await api.sendVoid(request)
            Issue.record("a rejected login must still throw")
        } catch let error as HLError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(ledger.sentBearers == ["A"], "no retry — a wrong password does not get a second attempt")
        #expect(ledger.refreshCount == 0)
    }
}

// swiftlint:enable force_unwrapping
