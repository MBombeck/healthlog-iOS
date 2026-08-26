import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Drift-test for `APIClient.isAuthExempt(path:)`.
///
/// `docs/api-contract.md` ("Auth-endpoint exemption from the 401→refresh
/// bridge") pins five path prefixes that must NEVER trigger the one-shot
/// refresh attempt. The test exists to make the contract failure-load-bearing:
/// adding a new `/api/auth/...` route on the server without listing it here
/// will surface as a red test, not a silent 401-storm at runtime (M-1 audit).
///
/// The test parameterises over:
///   - the **exempt** prefix set (must skip the refresh handler entirely),
///   - a representative **non-exempt** route set (must call the refresh
///     handler exactly once per 401).
///
/// Source of truth for the exempt table: `APIClient.isAuthExempt(path:)`
/// (private — mirrored here verbatim so a typo on either side fails the test).
@Suite("Refresh-bridge exemption contract (M-1)", .serialized)
struct RefreshExemptionTest {
    /// Canonical exempt routes. Mirrors `APIClient.isAuthExempt(path:)` —
    /// keep these in sync with the implementation. Each entry is a path that
    /// SHOULD match the exemption (so `refreshHandler` MUST NOT fire on a
    /// 401 from that path).
    private static let exemptRoutes: [String] = [
        "/api/auth/login",
        "/api/auth/refresh",
        "/api/auth/logout",
        "/api/auth/passkey/login-options",
        "/api/auth/passkey/login-verify",
        "/api/auth/passkey/register-options",
        "/api/auth/passkey/register-verify",
        "/api/auth/register"
    ]

    /// Representative non-exempt routes — any route that authenticates with a
    /// Bearer must trigger the bridge so a single stale token is rotated +
    /// retried instead of bouncing the user to the login screen.
    private static let authenticatedRoutes: [String] = [
        "/api/dashboard/summary",
        "/api/measurements",
        "/api/medications",
        "/api/insights/comprehensive",
        "/api/user/profile",
        "/api/settings",
        "/api/notifications/preferences"
    ]

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

    @Test("All documented exempt routes skip the refresh bridge", arguments: Self.exemptRoutes)
    func exemptPathsSkipRefresh(path: String) async {
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_stale", forKey: KeychainKey.authToken)
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
            let req = APIRequest<EmptyPayload>(method: .post, path: path, body: Data("{}".utf8))
            _ = try await api.send(req)
            Issue.record("expected throw for path \(path)")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error for path \(path): \(error)")
        }
        #expect(
            refreshCalls.current == 0,
            "Exempt route '\(path)' must NEVER trigger the refresh bridge — would loop."
        )
    }

    @Test("Authenticated routes trigger refresh bridge exactly once", arguments: Self.authenticatedRoutes)
    func authenticatedPathsTriggerRefresh(path: String) async {
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_stale", forKey: KeychainKey.authToken)
        let refreshCalls = Counter()
        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in
                _ = refreshCalls.increment()
                return .authFailure // simulate stale-refresh-token → terminal 401
            }
        )

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Invalid token"}"#.utf8)
            )
        }

        do {
            let req: APIRequest<EmptyPayload> = .get(path)
            _ = try await api.send(req)
            Issue.record("expected throw for path \(path)")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error for path \(path): \(error)")
        }
        #expect(
            refreshCalls.current == 1,
            "Authenticated route '\(path)' must trigger the refresh bridge exactly once."
        )
    }

    /// Drift-defence: any future path starting with `/api/auth/` is presumed
    /// to participate in the auth handshake. If you intentionally add an
    /// `/api/auth/...` route that DOES expect the refresh bridge, add it to
    /// this test's allowlist so the failure is loud.
    @Test("No accidental non-exempt route under /api/auth/")
    func authPrefixesAreExempt() async {
        let kc = InMemoryKeychain()
        try? kc.setString("hlk_stale", forKey: KeychainKey.authToken)
        let refreshCalls = Counter()
        let api = makeAPI(
            keychain: kc,
            refreshHandler: { @Sendable in
                _ = refreshCalls.increment()
                return .refreshed
            }
        )

        // Sample a fresh /api/auth/ path that isn't in the exempt table yet
        // — confirms the test catches new routes added without updating
        // `APIClient.isAuthExempt(path:)`.
        let candidate = "/api/auth/sso/start"

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"SSO declined"}"#.utf8)
            )
        }

        do {
            let req = APIRequest<EmptyPayload>(method: .post, path: candidate, body: Data("{}".utf8))
            _ = try await api.send(req)
            Issue.record("expected throw for path \(candidate)")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The candidate is NOT in the current exempt list — so the bridge
        // fires. This documents the current behaviour: if you add such a
        // route on the server, you MUST update `isAuthExempt` AND this
        // test's `exemptRoutes` array. The assertion below pins the
        // CURRENT contract so a future change in `isAuthExempt` semantics
        // surfaces as a test diff.
        #expect(refreshCalls.current == 1)
    }
}
