#if canImport(AuthenticationServices) && canImport(UIKit)
    import AuthenticationServices
    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("WHOOP session lifetime", .serialized)
    struct WhoopSessionLifetimeTests {
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
            let driver = WhoopConnectService(
                anchorProvider: StubAnchor(),
                sessionFactory: SessionFactory([first, second])
            )
            let connectURL = try #require(URL(string: "https://healthlog.example/api/whoop/connect"))
            let firstCallback = try #require(URL(string: "dev.healthlog.app://whoop?whoop=connected"))
            let secondCallback = try #require(URL(string: "dev.healthlog.app://whoop?whoop=error&reason=denied"))

            let firstTask = Task { @MainActor in
                await driver.connect(connectURL: connectURL)
            }
            await waitUntilStarted(first)
            let secondTask = Task { @MainActor in
                await driver.connect(connectURL: connectURL)
            }
            await waitUntilStarted(second)

            first.callback?(firstCallback, nil)
            await Task.yield()
            second.callback?(secondCallback, nil)

            let firstOutcome = await firstTask.value
            let secondOutcome = await secondTask.value
            if first.cancelCount != 1 || firstOutcome != .canceled || secondOutcome != .failed(reason: "denied") {
                Issue.record("EXPECTED_RED: WHOOP overlap completed wrong operation")
            }
        }

        @Test("task cancellation cancels its platform session")
        func taskCancellationCancelsMatchingSession() async throws {
            let session = ControlledSession()
            let driver = WhoopConnectService(
                anchorProvider: StubAnchor(),
                sessionFactory: SessionFactory([session])
            )
            let connectURL = try #require(URL(string: "https://healthlog.example/api/whoop/connect"))
            let lateURL = try #require(URL(string: "dev.healthlog.app://whoop?whoop=connected"))

            let task = Task { @MainActor in
                await driver.connect(connectURL: connectURL)
            }
            await waitUntilStarted(session)
            task.cancel()
            await Task.yield()
            session.callback?(lateURL, nil)

            #expect(await task.value == .canceled)
            #expect(session.cancelCount == 1)
        }

        @Test("failed start returns canceled exactly once")
        func failedStartReturnsCanceled() async throws {
            let session = ControlledSession()
            session.startResult = false
            let driver = WhoopConnectService(
                anchorProvider: StubAnchor(),
                sessionFactory: SessionFactory([session])
            )
            let connectURL = try #require(URL(string: "https://healthlog.example/api/whoop/connect"))
            #expect(await driver.connect(connectURL: connectURL) == .canceled)
        }

        @Test("duplicate callback completes exactly once")
        func duplicateCallbackCompletesExactlyOnce() async throws {
            let session = ControlledSession()
            let driver = WhoopConnectService(
                anchorProvider: StubAnchor(),
                sessionFactory: SessionFactory([session])
            )
            let connectURL = try #require(URL(string: "https://healthlog.example/api/whoop/connect"))
            let callback = try #require(URL(string: "dev.healthlog.app://whoop?whoop=connected"))
            let task = Task { @MainActor in await driver.connect(connectURL: connectURL) }
            await waitUntilStarted(session)
            session.callback?(callback, nil)
            session.callback?(callback, nil)
            #expect(await task.value == .connected)
        }

        private func waitUntilStarted(_ session: ControlledSession) async {
            while session.startCount == 0 {
                await Task.yield()
            }
        }
    }
#endif
