// Account-deletion cleanup owns the authentication boundary from the foreground
// probe through the final asynchronous cache wipe. A replacement login must not
// persist credentials while the prior owner's anchor/cache teardown can still
// erase account-scoped state.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Web-deletion cleanup serialization", .serialized)
    struct WebDeletionCleanupSerializationTests {
        private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
            @MainActor func register(
                challenge _: String, rpId _: String, rpName _: String,
                userID _: String, userName _: String, displayName _: String,
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyRegistration {
                throw HLError.unknown("noop")
            }

            @MainActor func assert(
                challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyAssertion {
                throw HLError.unknown("noop")
            }
        }

        @MainActor
        private final class AsyncCleanupGate: @unchecked Sendable {
            private var continuation: CheckedContinuation<Void, Never>?
            private(set) var calls = 0
            private(set) var started = false

            func run() async {
                calls += 1
                started = true
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }

            func release() {
                continuation?.resume()
                continuation = nil
            }
        }

        private final class ThreadSafeSpy: @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0

            var calls: Int {
                lock.withLock { _calls }
            }

            func record() {
                lock.withLock { _calls += 1 }
            }
        }

        private struct Fixture {
            let store: AuthStore
            let keychain: InMemoryKeychain
            let anchorCleanup: AsyncCleanupGate
            let localCleanup: AsyncCleanupGate
            let genericUnauthorizedCleanup: ThreadSafeSpy
            let loginRequests: ThreadSafeSpy
        }

        private func makeFixture() throws -> Fixture {
            let keychain = InMemoryKeychain()
            try keychain.setString("owner-a-token", forKey: KeychainKey.authToken)
            try keychain.setString("owner-a-refresh", forKey: KeychainKey.refreshToken)
            try keychain.setString("owner-a", forKey: KeychainKey.userID)
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let unauthorizedRef = UnauthorizedHandlerRef()
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: .mock(),
                onUnauthorized: { await unauthorizedRef.invoke() }
            )
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let suite = "web-deletion-serialization.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let store = AuthStore(auth: auth, keychain: keychain, defaults: defaults)
            let anchorCleanup = AsyncCleanupGate()
            let localCleanup = AsyncCleanupGate()
            let genericUnauthorizedCleanup = ThreadSafeSpy()
            let loginRequests = ThreadSafeSpy()

            store.setPhaseForTesting(.authenticated(
                User(id: "owner-a", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            store.setOnLogoutCleanup { _ in await anchorCleanup.run() }
            store.localCleanupHook = { await localCleanup.run() }
            unauthorizedRef.set { [weak store] in
                let shouldRunGenericCleanup = await store?.handleUnauthorized() ?? false
                if shouldRunGenericCleanup {
                    genericUnauthorizedCleanup.record()
                }
            }
            return Fixture(
                store: store,
                keychain: keychain,
                anchorCleanup: anchorCleanup,
                localCleanup: localCleanup,
                genericUnauthorizedCleanup: genericUnauthorizedCleanup,
                loginRequests: loginRequests
            )
        }

        private func waitUntilStarted(_ cleanup: AsyncCleanupGate) async throws {
            for _ in 0 ..< 500 where !cleanup.started {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(cleanup.started, "the asynchronous cleanup stage must start")
        }

        private nonisolated static func replacementLoginResponseBody() -> Data {
            Data(#"""
            {
                "data": {
                    "user": {
                        "id": "owner-b",
                        "email": "replacement@example.invalid",
                        "username": "replacement",
                        "displayName": "Replacement"
                    },
                    "token": "owner-b-token",
                    "tokenExpiresAt": "2026-09-01T12:00:00Z",
                    "refreshToken": "owner-b-refresh",
                    "refreshTokenExpiresAt": "2026-10-01T12:00:00Z"
                }
            }
            """#.utf8)
        }

        @Test("401 bridge defers to deletion owner and B waits for anchor + local cleanup")
        func replacementLoginWaitsForCompleteDeletionCleanup() async throws {
            let fixture = try makeFixture()
            fixture.store.markPendingWebDeletion()
            let loginRequests = fixture.loginRequests
            MockURLProtocol.handler = { req in
                switch req.url?.path {
                case "/api/auth/me":
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                        Data("{}".utf8)
                    )
                case "/api/auth/login":
                    loginRequests.record()
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.replacementLoginResponseBody()
                    )
                default:
                    Issue.record("unexpected request while reconciling account deletion")
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
            }

            let reconciliation = Task { @MainActor in
                await fixture.store.reconcilePendingWebDeletion()
            }
            try await waitUntilStarted(fixture.anchorCleanup)

            let replacementLogin = Task { @MainActor in
                await fixture.store.login(
                    email: "replacement@example.invalid",
                    password: "fixture-password"
                )
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(fixture.loginRequests.calls == 0, "B must wait while A anchor cleanup is blocked")
            #expect(
                fixture.genericUnauthorizedCleanup.calls == 0,
                "the production 401 bridge must defer its generic cascade to deletion cleanup"
            )

            fixture.anchorCleanup.release()
            try await waitUntilStarted(fixture.localCleanup)
            try await Task.sleep(for: .milliseconds(50))
            #expect(fixture.loginRequests.calls == 0, "B must wait while A local cleanup is blocked")

            fixture.localCleanup.release()
            await reconciliation.value
            await replacementLogin.value

            #expect(fixture.loginRequests.calls == 1)
            #expect(fixture.keychain.getString(forKey: KeychainKey.authToken) == "owner-b-token")
            #expect(fixture.keychain.getString(forKey: KeychainKey.refreshToken) == "owner-b-refresh")
            #expect(fixture.keychain.getString(forKey: KeychainKey.userID) == "owner-b")
            guard case let .authenticating(replacementOwner) = fixture.store.phase else {
                Issue.record("B must be admitted only after A deletion cleanup completes")
                return
            }
            #expect(replacementOwner.id == "owner-b")
        }
    }

#endif // !SWIFT_PACKAGE
