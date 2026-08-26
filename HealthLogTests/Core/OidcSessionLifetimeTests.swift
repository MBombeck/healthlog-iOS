#if canImport(AuthenticationServices)
    import AuthenticationServices
    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("OIDC session lifetime", .serialized)
    struct OidcSessionLifetimeTests {
        @MainActor
        private final class ControlledSession: WebAuthenticationSession {
            var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
            var prefersEphemeralWebBrowserSession = true
            var startResult = true
            private(set) var startCount = 0
            private(set) var cancelCount = 0
            var callback: ((URL?, Error?) -> Void)?

            func start() -> Bool {
                startCount += 1
                return startResult
            }

            func cancel() {
                cancelCount += 1
            }
        }

        @MainActor
        private final class SessionFactory: WebAuthenticationSessionCreating {
            private var sessions: [ControlledSession]
            private(set) var made: [ControlledSession] = []

            init(_ sessions: [ControlledSession]) {
                self.sessions = sessions
            }

            func makeSession(
                url _: URL,
                callbackURLScheme _: String?,
                completionHandler: @escaping (URL?, Error?) -> Void
            ) -> any WebAuthenticationSession {
                let session = sessions.removeFirst()
                session.callback = completionHandler
                made.append(session)
                return session
            }
        }

        @MainActor
        private final class StubAnchor: ASPresentationAnchorProvider {
            func anchor() -> ASPresentationAnchor {
                ASPresentationAnchor()
            }
        }

        @Test("overlap cancellation and late callback are exactly once")
        func overlapCancellationAndLateCallbackAreExactlyOnce() async throws {
            let first = ControlledSession()
            let second = ControlledSession()
            let factory = SessionFactory([first, second])
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: factory)
            let loginURL = try #require(URL(string: "https://healthlog.example/api/auth/oidc/login"))
            let firstCallback = try #require(URL(string: "healthlog://oidc-callback?code=first"))
            let secondCallback = try #require(URL(string: "healthlog://oidc-callback?code=second"))

            let firstTask = Task { @MainActor in
                await driver.authenticate(loginURL: loginURL, callbackScheme: "healthlog", anchor: StubAnchor())
            }
            await waitUntilStarted(first)

            let secondTask = Task { @MainActor in
                await driver.authenticate(loginURL: loginURL, callbackScheme: "healthlog", anchor: StubAnchor())
            }
            await waitUntilStarted(second)

            // A stale callback must be ignored after overlap has terminally
            // cancelled A; it must never clear or finish operation B.
            first.callback?(firstCallback, nil)
            await Task.yield()
            second.callback?(secondCallback, nil)

            let firstOutcome = await firstTask.value
            let secondOutcome = await secondTask.value
            let firstWasCanceled = if case .canceled = firstOutcome {
                true
            } else {
                false
            }
            let secondWasCurrent = if case let .callback(url) = secondOutcome {
                url == secondCallback
            } else {
                false
            }
            if first.cancelCount != 1 || !firstWasCanceled || !secondWasCurrent {
                Issue.record("EXPECTED_RED: OIDC overlap completed wrong operation")
            }
        }

        @Test("task cancellation cancels its platform session and ignores a late callback")
        func taskCancellationCancelsMatchingSession() async throws {
            let session = ControlledSession()
            let factory = SessionFactory([session])
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: factory)
            let loginURL = try #require(URL(string: "https://healthlog.example/api/auth/oidc/login"))
            let lateURL = try #require(URL(string: "healthlog://oidc-callback?code=late"))

            let task = Task { @MainActor in
                await driver.authenticate(loginURL: loginURL, callbackScheme: "healthlog", anchor: StubAnchor())
            }
            await waitUntilStarted(session)
            task.cancel()
            await Task.yield()
            session.callback?(lateURL, nil)

            let outcome = await task.value
            #expect(session.cancelCount == 1)
            guard case .canceled = outcome else {
                Issue.record("task cancellation must yield one canceled outcome")
                return
            }
        }

        @Test("failed start returns failed exactly once")
        func failedStartReturnsFailed() async throws {
            let session = ControlledSession()
            session.startResult = false
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: SessionFactory([session]))
            let loginURL = try #require(URL(string: "https://healthlog.example/api/auth/oidc/login"))
            let outcome = await driver.authenticate(
                loginURL: loginURL,
                callbackScheme: "healthlog",
                anchor: StubAnchor()
            )
            guard case .failed = outcome else {
                Issue.record("failed start must return failed")
                return
            }
        }

        @Test("duplicate callback completes exactly once")
        func duplicateCallbackCompletesExactlyOnce() async throws {
            let session = ControlledSession()
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: SessionFactory([session]))
            let loginURL = try #require(URL(string: "https://healthlog.example/api/auth/oidc/login"))
            let callback = try #require(URL(string: "healthlog://oidc-callback?code=once"))
            let task = Task { @MainActor in
                await driver.authenticate(loginURL: loginURL, callbackScheme: "healthlog", anchor: StubAnchor())
            }
            await waitUntilStarted(session)
            session.callback?(callback, nil)
            session.callback?(callback, nil)
            guard case let .callback(received) = await task.value else {
                Issue.record("first callback must complete the operation")
                return
            }
            #expect(received == callback)
        }

        private func waitUntilStarted(_ session: ControlledSession) async {
            while session.startCount == 0 {
                await Task.yield()
            }
        }
    }
#endif
