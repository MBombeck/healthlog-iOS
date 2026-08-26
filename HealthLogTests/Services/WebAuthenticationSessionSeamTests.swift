#if canImport(AuthenticationServices) && canImport(UIKit)
    import AuthenticationServices
    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("Web authentication session seam", .serialized)
    struct WebAuthenticationSessionSeamTests {
        @MainActor
        private final class ControlledSession: WebAuthenticationSession {
            var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
            var prefersEphemeralWebBrowserSession = true
            var startResult = true
            private(set) var startCount = 0
            private(set) var cancelCount = 0

            func start() -> Bool {
                startCount += 1
                return startResult
            }

            func cancel() {
                cancelCount += 1
            }
        }

        @MainActor
        private final class ControlledFactory: WebAuthenticationSessionCreating {
            let session: ControlledSession
            private(set) var url: URL?
            private(set) var callbackScheme: String?
            private(set) var callback: ((URL?, Error?) -> Void)?

            init(session: ControlledSession = ControlledSession()) {
                self.session = session
            }

            func makeSession(
                url: URL,
                callbackURLScheme: String?,
                completionHandler: @escaping (URL?, Error?) -> Void
            ) -> any WebAuthenticationSession {
                self.url = url
                callbackScheme = callbackURLScheme
                callback = completionHandler
                return session
            }
        }

        @MainActor
        private final class StubAnchor: ASPresentationAnchorProvider {
            func anchor() -> ASPresentationAnchor {
                ASPresentationAnchor()
            }
        }

        @Test("OIDC forwards construction, context, persistence and callback")
        func oidcForwardsConfigurationAndCallback() async throws {
            let factory = ControlledFactory()
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: factory)
            let loginURL = try #require(URL(string: "https://healthlog.example/api/auth/oidc/login"))
            let callbackURL = try #require(URL(string: "healthlog://oidc-callback?code=opaque"))

            let task = Task { @MainActor in
                await driver.authenticate(loginURL: loginURL, callbackScheme: "healthlog", anchor: StubAnchor())
            }
            await waitUntilStarted(factory.session)

            #expect(factory.url == loginURL)
            #expect(factory.callbackScheme == "healthlog")
            #expect(factory.session.presentationContextProvider != nil)
            #expect(factory.session.prefersEphemeralWebBrowserSession == false)
            #expect(factory.session.startCount == 1)

            factory.callback?(callbackURL, nil)
            guard case let .callback(url) = await task.value else {
                Issue.record("expected callback outcome")
                return
            }
            #expect(url == callbackURL)
        }

        @Test("WHOOP forwards construction, context, persistence and cancellation callback")
        func whoopForwardsConfigurationAndCallback() async throws {
            let factory = ControlledFactory()
            let driver = WhoopConnectService(anchorProvider: StubAnchor(), sessionFactory: factory)
            let connectURL = try #require(URL(string: "https://healthlog.example/api/whoop/connect"))

            let task = Task { @MainActor in
                await driver.connect(connectURL: connectURL)
            }
            await waitUntilStarted(factory.session)

            #expect(factory.url == connectURL)
            #expect(factory.callbackScheme == WhoopConnectService.callbackScheme)
            #expect(factory.session.presentationContextProvider != nil)
            #expect(factory.session.prefersEphemeralWebBrowserSession == false)
            #expect(factory.session.startCount == 1)

            factory.callback?(nil, nil)
            #expect(await task.value == .canceled)
        }

        private func waitUntilStarted(_ session: ControlledSession) async {
            while session.startCount == 0 {
                await Task.yield()
            }
        }
    }
#endif
