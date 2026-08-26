// A refresh response is a credential write, not merely a network result. If
// account deletion wins while that response is suspended, the old account's
// rotated bundle must never be allowed to repopulate the wiped Keychain.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    private final class RefreshTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<RefreshOutcome, Never>?

        func store(_ task: Task<RefreshOutcome, Never>) {
            lock.withLock { self.task = task }
        }

        func value() async throws -> RefreshOutcome {
            for _ in 0 ..< 500 {
                if let task = lock.withLock({ task }) {
                    return await task.value
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("the refresh task must be queued from inside credential teardown")
            return .transient
        }
    }

    @MainActor
    @Suite("Refresh persistence across account deletion", .serialized)
    struct AuthRefreshDeletionLeaseTests {
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

        private final class SuspendedRefresh: @unchecked Sendable {
            private let lock = NSLock()
            private let startedSemaphore = DispatchSemaphore(value: 0)
            private var _started = false
            private var completion: (@Sendable () -> Void)?

            var started: Bool {
                lock.withLock { _started }
            }

            func suspend(completion: @escaping @Sendable () -> Void) {
                lock.withLock {
                    _started = true
                    self.completion = completion
                }
                startedSemaphore.signal()
            }

            func release() {
                let completion = lock.withLock {
                    let completion = self.completion
                    self.completion = nil
                    return completion
                }
                completion?()
            }

            func waitSynchronouslyForStart() {
                _ = startedSemaphore.wait(timeout: .now() + .milliseconds(200))
            }
        }

        private final class InterlockingKeychain: KeychainStoring, @unchecked Sendable {
            private let storage = InMemoryKeychain()
            private let lock = NSLock()
            private var onFirstAuthRemoval: (@Sendable () -> Void)?
            private var refreshGate: SuspendedRefresh?

            func arm(refreshGate: SuspendedRefresh, onFirstAuthRemoval: @escaping @Sendable () -> Void) {
                lock.withLock {
                    self.refreshGate = refreshGate
                    self.onFirstAuthRemoval = onFirstAuthRemoval
                }
            }

            func setString(_ value: String, forKey key: String) throws {
                try storage.setString(value, forKey: key)
            }

            func getString(forKey key: String) -> String? {
                storage.getString(forKey: key)
            }

            func setData(_ data: Data, forKey key: String) throws {
                try storage.setData(data, forKey: key)
            }

            func getData(forKey key: String) -> Data? {
                storage.getData(forKey: key)
            }

            func remove(forKey key: String) throws {
                if key == KeychainKey.authToken {
                    let interlock = lock.withLock {
                        let result = (onFirstAuthRemoval, refreshGate)
                        onFirstAuthRemoval = nil
                        refreshGate = nil
                        return result
                    }
                    interlock.0?()
                    interlock.1?.waitSynchronouslyForStart()
                }
                try storage.remove(forKey: key)
            }

            func removeAll() throws {
                try storage.removeAll()
            }
        }

        /// A URLProtocol whose handler completes requests asynchronously. The
        /// shared MockURLProtocol handler is synchronous, so parking it on a
        /// semaphore also parks URLSession's delivery path and prevents the
        /// concurrent deletion request this suite is meant to exercise.
        private final class ConcurrentURLProtocol: URLProtocol, @unchecked Sendable {
            typealias Completion = @Sendable (HTTPURLResponse, Data?) -> Void
            typealias Handler = @Sendable (URLRequest, @escaping Completion) -> Void

            private nonisolated(unsafe) static var _handler: Handler?
            private static let handlerLock = NSLock()

            static var handler: Handler? {
                get { handlerLock.withLock { _handler } }
                set { handlerLock.withLock { _handler = newValue } }
            }

            private let stateLock = NSLock()
            private var stopped = false

            override class func canInit(with _: URLRequest) -> Bool {
                true
            }

            override class func canonicalRequest(for request: URLRequest) -> URLRequest {
                request
            }

            override func startLoading() {
                guard let handler = Self.handler else {
                    client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                    return
                }
                handler(request) { [weak self] response, data in
                    self?.complete(response: response, data: data)
                }
            }

            override func stopLoading() {
                stateLock.withLock { stopped = true }
            }

            private func complete(response: HTTPURLResponse, data: Data?) {
                let shouldComplete = stateLock.withLock {
                    guard !stopped else { return false }
                    stopped = true
                    return true
                }
                guard shouldComplete else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        private final class RequestTrace: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []

            func record(_ request: URLRequest) -> Int {
                lock.withLock {
                    paths.append(request.url?.path ?? "")
                    return paths.count
                }
            }

            var snapshot: [String] {
                lock.withLock { paths }
            }
        }

        private struct Fixture {
            let api: APIClient
            let auth: AuthService
            let store: AuthStore
            let keychain: KeychainStoring
        }

        private func makeFixture(
            keychain: KeychainStoring = InMemoryKeychain(),
            refreshBridge: Bool = false
        ) async throws -> Fixture {
            try seedSession(keychain)
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [ConcurrentURLProtocol.self]
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: sessionConfiguration
            )
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            if refreshBridge {
                let coordinator = RefreshCoordinator(auth: auth)
                await api.setRefreshHandler { await coordinator.attemptRefresh() }
            }
            let suiteName = "auth-refresh-deletion.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            let store = AuthStore(auth: auth, keychain: keychain, defaults: defaults)
            store.setPhaseForTesting(.authenticated(Self.owner))
            return Fixture(api: api, auth: auth, store: store, keychain: keychain)
        }

        private func seedSession(_ keychain: KeychainStoring) throws {
            try keychain.setString("owner-a-access", forKey: KeychainKey.authToken)
            try keychain.setString("owner-a-refresh", forKey: KeychainKey.refreshToken)
            try keychain.setString("2026-09-01T12:00:00Z", forKey: KeychainKey.accessTokenExpiresAt)
            try keychain.setString("2026-10-01T12:00:00Z", forKey: KeychainKey.refreshTokenExpiresAt)
            try keychain.setString(Self.owner.id, forKey: KeychainKey.userID)
            try keychain.setString("device-a", forKey: KeychainKey.deviceID)
        }

        private func waitUntilStarted(_ suspendedRefresh: SuspendedRefresh) async throws {
            for _ in 0 ..< 500 where !suspendedRefresh.started {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(suspendedRefresh.started, "the refresh request must be suspended before deletion starts")
        }

        private func expectNoAuthBundle(_ keychain: KeychainStoring) {
            #expect(keychain.getString(forKey: KeychainKey.authToken) == nil)
            #expect(keychain.getString(forKey: KeychainKey.refreshToken) == nil)
            #expect(keychain.getString(forKey: KeychainKey.accessTokenExpiresAt) == nil)
            #expect(keychain.getString(forKey: KeychainKey.refreshTokenExpiresAt) == nil)
            #expect(keychain.getString(forKey: KeychainKey.userID) == nil)
        }

        private nonisolated static let owner = User(
            id: "owner-a",
            email: nil,
            username: nil,
            displayName: nil,
            createdAt: .now
        )

        private nonisolated static func refreshedSessionBody() -> Data {
            Data(#"""
            {
                "data": {
                    "user": {
                        "id": "owner-a",
                        "email": null,
                        "username": null,
                        "displayName": null
                    },
                    "token": "owner-a-rotated-access",
                    "tokenExpiresAt": "2026-09-02T12:00:00Z",
                    "refreshToken": "owner-a-rotated-refresh",
                    "refreshTokenExpiresAt": "2026-10-02T12:00:00Z"
                }
            }
            """#.utf8)
        }

        private nonisolated static func replacementSessionBody() -> Data {
            Data(#"""
            {
                "data": {
                    "user": { "id": "owner-b", "displayName": "Replacement" },
                    "token": "owner-b-access",
                    "tokenExpiresAt": "2026-09-03T12:00:00Z",
                    "refreshToken": "owner-b-refresh",
                    "refreshTokenExpiresAt": "2026-10-03T12:00:00Z"
                }
            }
            """#.utf8)
        }

        @Test("native 2xx deletion invalidates an already-suspended refresh write")
        func nativeDeletionRejectsSuspendedRefreshPersistence() async throws {
            let fixture = try await makeFixture()
            let suspendedRefresh = SuspendedRefresh()
            ConcurrentURLProtocol.handler = { request, complete in
                switch request.url?.path {
                case "/api/auth/refresh":
                    suspendedRefresh.suspend {
                        complete(
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Self.refreshedSessionBody()
                        )
                    }
                case "/api/settings/account":
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                        nil
                    )
                default:
                    Issue.record("unexpected request in native deletion refresh race")
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        nil
                    )
                }
            }

            let refresh = Task { await fixture.auth.refresh() }
            try await waitUntilStarted(suspendedRefresh)
            try await fixture.auth.deleteAccount()
            expectNoAuthBundle(fixture.keychain)

            suspendedRefresh.release()
            #expect(await refresh.value == .transient)
            expectNoAuthBundle(fixture.keychain)
        }

        @Test("tokenless web deletion invalidates an already-suspended refresh write")
        func tokenlessWebDeletionRejectsSuspendedRefreshPersistence() async throws {
            let fixture = try await makeFixture()
            fixture.store.markPendingWebDeletion()
            let suspendedRefresh = SuspendedRefresh()
            ConcurrentURLProtocol.handler = { request, complete in
                guard request.targets("/api/auth/refresh") else {
                    Issue.record("a tokenless web-deletion probe must not issue a network request")
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        nil
                    )
                    return
                }
                suspendedRefresh.suspend {
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.refreshedSessionBody()
                    )
                }
            }

            let refresh = Task { await fixture.auth.refresh() }
            try await waitUntilStarted(suspendedRefresh)
            try fixture.keychain.remove(forKey: KeychainKey.authToken)
            await fixture.store.reconcilePendingWebDeletion()
            expectNoAuthBundle(fixture.keychain)

            suspendedRefresh.release()
            #expect(await refresh.value == .transient)
            expectNoAuthBundle(fixture.keychain)
        }

        @Test("web 404 deletion invalidates an already-suspended refresh write")
        func web404DeletionRejectsSuspendedRefreshPersistence() async throws {
            let fixture = try await makeFixture()
            fixture.store.markPendingWebDeletion()
            let suspendedRefresh = SuspendedRefresh()
            ConcurrentURLProtocol.handler = { request, complete in
                switch request.url?.path {
                case "/api/auth/refresh":
                    suspendedRefresh.suspend {
                        complete(
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Self.refreshedSessionBody()
                        )
                    }
                case "/api/auth/me":
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"Not found"}"#.utf8)
                    )
                default:
                    Issue.record("unexpected request in web 404 refresh race")
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        nil
                    )
                }
            }

            let refresh = Task { await fixture.auth.refresh() }
            try await waitUntilStarted(suspendedRefresh)
            await fixture.store.reconcilePendingWebDeletion()
            expectNoAuthBundle(fixture.keychain)

            suspendedRefresh.release()
            #expect(await refresh.value == .transient)
            expectNoAuthBundle(fixture.keychain)
        }
    }

    extension AuthRefreshDeletionLeaseTests {
        @Test("refresh queued at the first web-teardown removal cannot capture the new generation")
        func webTeardownInvalidationAndWipeAreOneActorTurn() async throws {
            let keychain = InterlockingKeychain()
            let fixture = try await makeFixture(keychain: keychain)
            fixture.store.markPendingWebDeletion()
            let queuedRefreshResponse = SuspendedRefresh()
            let queuedRefreshTask = RefreshTaskBox()
            keychain.arm(refreshGate: queuedRefreshResponse) {
                queuedRefreshTask.store(Task { await fixture.auth.refresh() })
            }
            ConcurrentURLProtocol.handler = { request, complete in
                switch request.url?.path {
                case "/api/auth/me":
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"Not found"}"#.utf8)
                    )
                case "/api/auth/refresh":
                    queuedRefreshResponse.suspend {
                        complete(
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Self.refreshedSessionBody()
                        )
                    }
                default:
                    Issue.record("unexpected request in atomic web teardown race")
                }
            }

            await fixture.store.reconcilePendingWebDeletion()
            queuedRefreshResponse.release()
            let outcome = try await queuedRefreshTask.value()

            #expect(outcome == .transient)
            #expect(!queuedRefreshResponse.started, "refresh must enter only after the actor-isolated wipe removed its token")
            expectNoAuthBundle(fixture.keychain)
        }

        @Test("suspended A refresh cannot overwrite B after user logout")
        func logoutInvalidatesSuspendedRefreshBeforeReplacementLogin() async throws {
            let fixture = try await makeFixture()
            let suspendedRefresh = SuspendedRefresh()
            let trace = RequestTrace()
            ConcurrentURLProtocol.handler = { request, complete in
                let requestNumber = trace.record(request)
                switch (request.url?.path, requestNumber) {
                case ("/api/auth/refresh", 1):
                    suspendedRefresh.suspend {
                        complete(
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Self.refreshedSessionBody()
                        )
                    }
                case ("/api/auth/refresh", 2):
                    complete(HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, nil)
                case ("/api/auth/login", 3):
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.replacementSessionBody()
                    )
                default:
                    Issue.record("unexpected request in logout refresh race")
                }
            }

            let staleRefresh = Task { await fixture.auth.refresh() }
            try await waitUntilStarted(suspendedRefresh)
            await fixture.store.logout()
            await fixture.store.login(email: "replacement@example.invalid", password: "fixture-password")
            suspendedRefresh.release()

            #expect(await staleRefresh.value == .transient)
            #expect(fixture.keychain.getString(forKey: KeychainKey.authToken) == "owner-b-access")
            #expect(fixture.keychain.getString(forKey: KeychainKey.refreshToken) == "owner-b-refresh")
            #expect(fixture.keychain.getString(forKey: KeychainKey.userID) == "owner-b")
        }

        @Test("suspended A refresh cannot overwrite B after terminal unauthorized teardown")
        func unauthorizedInvalidatesSuspendedRefreshBeforeReplacementLogin() async throws {
            let fixture = try await makeFixture()
            let suspendedRefresh = SuspendedRefresh()
            ConcurrentURLProtocol.handler = { request, complete in
                switch request.url?.path {
                case "/api/auth/refresh":
                    suspendedRefresh.suspend {
                        complete(
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Self.refreshedSessionBody()
                        )
                    }
                case "/api/auth/login":
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.replacementSessionBody()
                    )
                default:
                    Issue.record("unexpected request in unauthorized refresh race")
                }
            }

            let staleRefresh = Task { await fixture.auth.refresh() }
            try await waitUntilStarted(suspendedRefresh)
            #expect(await fixture.store.handleUnauthorized())
            await fixture.store.login(email: "replacement@example.invalid", password: "fixture-password")
            suspendedRefresh.release()

            #expect(await staleRefresh.value == .transient)
            #expect(fixture.keychain.getString(forKey: KeychainKey.authToken) == "owner-b-access")
            #expect(fixture.keychain.getString(forKey: KeychainKey.refreshToken) == "owner-b-refresh")
            #expect(fixture.keychain.getString(forKey: KeychainKey.userID) == "owner-b")
        }
    }

    extension AuthRefreshDeletionLeaseTests {
        @Test("web probe may refresh after 401, retry, then delete without deadlock or resurrection")
        func web401RefreshOrderingCompletes() async throws {
            let fixture = try await makeFixture(refreshBridge: true)
            fixture.store.markPendingWebDeletion()
            let trace = RequestTrace()
            ConcurrentURLProtocol.handler = { request, complete in
                let requestNumber = trace.record(request)
                switch (request.url?.path, requestNumber) {
                case ("/api/auth/me", 1):
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"Expired"}"#.utf8)
                    )
                case ("/api/auth/refresh", 2):
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.refreshedSessionBody()
                    )
                case ("/api/auth/me", 3):
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"Not found"}"#.utf8)
                    )
                default:
                    Issue.record("unexpected request ordering in web deletion refresh bridge")
                    complete(
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        nil
                    )
                }
            }

            await fixture.store.reconcilePendingWebDeletion()

            #expect(trace.snapshot == ["/api/auth/me", "/api/auth/refresh", "/api/auth/me"])
            expectNoAuthBundle(fixture.keychain)
            #expect(fixture.store.phase == .unauthenticated)
            #expect(!fixture.store.hasPendingWebDeletion)
        }

        @Test("normal refresh still persists the rotated auth bundle")
        func normalRefreshPersists() async throws {
            let fixture = try await makeFixture()
            ConcurrentURLProtocol.handler = { request, complete in
                #expect(request.targets("/api/auth/refresh", method: "POST"))
                complete(
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.refreshedSessionBody()
                )
            }

            #expect(await fixture.auth.refresh() == .refreshed)
            #expect(fixture.keychain.getString(forKey: KeychainKey.authToken) == "owner-a-rotated-access")
            #expect(fixture.keychain.getString(forKey: KeychainKey.refreshToken) == "owner-a-rotated-refresh")
            #expect(fixture.keychain.getString(forKey: KeychainKey.userID) == "owner-a")
        }
    }

#endif // !SWIFT_PACKAGE
