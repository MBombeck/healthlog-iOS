import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks: APIClient versucht bei 401 genau einmal `POST /api/auth/refresh`
/// und wiederholt den originalrequest mit dem frischen Bearer. Bei
/// Refresh-Failure fällt er auf `onUnauthorized` zurück und wirft
/// `HLError.unauthorized` (siehe `05-auth-flows.md §3` + `17-error-handling.md §9`).
@Suite("Refresh-token 401-bridge", .serialized)
struct RefreshFlowTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool = false
        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }

        var fired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makeAPI(
        keychain: InMemoryKeychain = InMemoryKeychain(),
        refreshHandler: (@Sendable () async -> RefreshOutcome)? = nil,
        onUnauthorized: (@Sendable () async -> Void)? = nil
    ) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock(),
            onUnauthorized: onUnauthorized,
            refreshHandler: refreshHandler
        )
    }

    @Test("401 → refresh succeeds → original request is retried with fresh bearer")
    func happyPath() async throws {
        let kc = InMemoryKeychain()
        try kc.setString("hlk_old", forKey: KeychainKey.authToken)
        let attempts = Counter()
        nonisolated(unsafe) let bearers: NSMutableArray = []
        let lock = NSLock()

        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in
                // Server hat den Token rotiert — Keychain wird normalerweise vom AuthService
                // gesetzt, hier simulieren wir das direkt.
                try? kc.setString("hlk_new", forKey: KeychainKey.authToken)
                return .refreshed
            }
        )

        MockURLProtocol.handler = { req in
            lock.lock()
            let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
            bearers.add(bearer)
            lock.unlock()
            let n = attempts.increment()
            if n == 1 {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Token expired"}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null}"#.utf8)
            )
        }

        let req: APIRequest<EmptyPayload> = .get("/api/measurements")
        _ = try await api.send(req)
        #expect(attempts.current == 2)
        // First attempt used the stale token, second used the rotated one.
        let snapshot = bearers as? [String] ?? []
        #expect(snapshot.first?.contains("hlk_old") == true)
        #expect(snapshot.last?.contains("hlk_new") == true)
    }

    @Test("401 → refresh fails → onUnauthorized + HLError.unauthorized")
    func refreshFails() async {
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_dead", forKey: KeychainKey.authToken)
        let unauthorizedFired = Flag()
        let attempts = Counter()
        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in .authFailure },
            onUnauthorized: { @Sendable in unauthorizedFired.set() }
        )

        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Invalid token"}"#.utf8)
            )
        }

        do {
            let req: APIRequest<EmptyPayload> = .get("/api/measurements")
            _ = try await api.send(req)
            Issue.record("expected throw")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(unauthorizedFired.fired)
        // Original + 1 retry after refresh-attempt-failure → only 1 server hit
        // because the failed refresh stays inside the actor (no second HTTP call here).
        #expect(attempts.current == 1)
    }

    @Test("401-cascade gating: TRANSIENT refresh failure must NOT log the user out")
    func transientRefreshDoesNotLogout() async {
        // The 401-cascade protection (v0.10.0): a refresh that fails for a
        // transient reason (offline / 5xx / rate-limit) returns `.transient`.
        // The request fails THIS once, but the session is left intact —
        // `onUnauthorized` must NOT fire. Pre-v0.10.0 this path nuked the
        // session on every transient hiccup (the spurious-logout storm).
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_live", forKey: KeychainKey.authToken)
        let unauthorizedFired = Flag()
        let refreshCalls = Counter()
        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in
                _ = refreshCalls.increment()
                return .transient
            },
            onUnauthorized: { @Sendable in unauthorizedFired.set() }
        )

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Token expired"}"#.utf8)
            )
        }

        do {
            let req: APIRequest<EmptyPayload> = .get("/api/measurements")
            _ = try await api.send(req)
            Issue.record("expected throw")
        } catch let err as HLError {
            // The request still surfaces .unauthorized (it didn't succeed)…
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(refreshCalls.current == 1, "exactly one refresh attempt")
        // …but the session SURVIVES — no logout cascade on a transient failure.
        #expect(!unauthorizedFired.fired, "transient refresh failure must not trigger onUnauthorized")
    }

    @Test("Refresh is attempted at most once per request — second 401 still gives up")
    func refreshOnceBudget() async {
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_old", forKey: KeychainKey.authToken)
        let unauthorizedFired = Flag()
        let attempts = Counter()
        let refreshCalls = Counter()
        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in
                _ = refreshCalls.increment()
                try? kc.setString("hlk_new", forKey: KeychainKey.authToken)
                return .refreshed
            },
            onUnauthorized: { @Sendable in unauthorizedFired.set() }
        )

        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Invalid token"}"#.utf8)
            )
        }

        do {
            let req: APIRequest<EmptyPayload> = .get("/api/measurements")
            _ = try await api.send(req)
            Issue.record("expected throw")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(refreshCalls.current == 1, "refresh must be attempted at most once per request")
        #expect(attempts.current == 2, "exactly initial + one retry, no more")
        #expect(unauthorizedFired.fired)
    }

    @Test("Auth endpoints (e.g. /api/auth/login) skip the refresh-bridge entirely")
    func authPathSkipsRefresh() async {
        let kc = InMemoryKeychain()
        let refreshCalls = Counter()
        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in
                _ = refreshCalls.increment()
                return .refreshed
            }
        )
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Invalid credentials"}"#.utf8)
            )
        }
        do {
            let req: APIRequest<EmptyPayload> = APIRequest(method: .post, path: "/api/auth/login", body: Data("{}".utf8))
            _ = try await api.send(req)
            Issue.record("expected throw")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(refreshCalls.current == 0, "auth endpoints must never trigger refresh-bridge")
    }
}
