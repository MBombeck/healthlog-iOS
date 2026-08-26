// #65 / v1.32.11 — pins the AuthStore web-handoff login session leg.
//
// Coverage (template: OidcSSOLoginTests):
//   1. happy path — stub driver returns a login-callback code, handler 200 +
//      bundle → phase promotes to .authenticating(user), token stored, and the
//      login URL carried /api/auth/native/login + code_challenge=.
//   2. a user-cancelled sheet → no banner, phase stays .unknown.
//   3. handleWebLoginCallback with ?error=stale_session → lastError set, no token.
//   4. exchange 401 → lastError set, phase .unknown, Keychain empty.
//   5. cross-flow: an oidc-callback URL → generic error, NO exchange fired
//      (handler hit-count stays 0).
//
// Drives the REAL `APIClient` over a stub `URLProtocol`, per the no-mock-server
// doctrine.

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Web-handoff login store leg (#65)", .serialized)
    struct WebLoginStoreTests {
        // MARK: - Fixtures

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

        /// Returns a canned callback URL without ever opening a web sheet, and
        /// captures the login URL the store built.
        @MainActor
        private final class StubOidcAuthenticator: OidcAuthenticating {
            var outcome: OidcAuthOutcome
            private(set) var capturedLoginURL: URL?
            init(outcome: OidcAuthOutcome) {
                self.outcome = outcome
            }

            func authenticate(
                loginURL: URL,
                callbackScheme _: String,
                anchor _: ASPresentationAnchorProvider
            ) async -> OidcAuthOutcome {
                capturedLoginURL = loginURL
                return outcome
            }
        }

        @MainActor
        private final class StubAnchor: ASPresentationAnchorProvider {
            func anchor() -> ASPresentationAnchor {
                ASPresentationAnchor()
            }
        }

        private func makeService(_ keychain: InMemoryKeychain = InMemoryKeychain()) -> (AuthService, InMemoryKeychain) {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            // Der Browser-Login baut seine URL NICHT aus `env`, sondern aus
            // `AppEnvironment.currentBaseURL(keychain:)`. Seit die App keinen
            // eingebauten Server mehr mitbringt, ist das ohne Keychain-Eintrag
            // `nil` — vorher hat der fest verdrahtete Produktionshost diese
            // Abhaengigkeit im Test verdeckt. Also hier ausdruecklich setzen.
            try? keychain.setString("https://test.healthlog.local", forKey: KeychainKey.serverURL)
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            return (AuthService(api: api, keychain: keychain, passkey: NoopPasskey()), keychain)
        }

        private static func bundleBody() -> Data {
            Data(#"""
            {
              "data": {
                "user": { "id": "user-web-1", "username": "webuser" },
                "token": "hlk_bearer_WEB",
                "tokenExpiresAt": "2026-07-01T12:00:00Z",
                "refreshToken": "hlr_refresh_WEB",
                "refreshTokenExpiresAt": "2026-09-01T12:00:00Z"
              },
              "error": null
            }
            """#.utf8)
        }

        // MARK: - 1) happy path

        @MainActor
        @Test("full loginWithWebLogin happy path exchanges + promotes phase")
        func loginWithWebLoginHappyPath() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            let authenticator = try StubOidcAuthenticator(
                outcome: .callback(
                    #require(URL(string: "healthlog://login-callback?code=hlh_ok00000000000000000000000000000000000000000"))
                )
            )
            store.oidcAuthenticator = authenticator

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }
            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(store.phase == .authenticating(User(
                id: "user-web-1",
                email: nil,
                username: "webuser",
                displayName: nil,
                createdAt: nil
            )))
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_WEB")
            let url = authenticator.capturedLoginURL?.absoluteString ?? ""
            #expect(url.contains("/api/auth/native/login"))
            #expect(url.contains("code_challenge="))
            #expect(!url.contains("client="))
        }

        // MARK: - 1b) no server configured → say so, don't say "try again"

        @MainActor
        @Test("without a configured server the web-login names that, instead of a retry banner")
        func loginWithWebLoginWithoutServer() async {
            // Seit die App keinen eingebauten Server mehr mitbringt, ist das ein
            // erreichbarer Zustand: Onboarding abgebrochen, dann auf dem
            // Anmeldebildschirm "über den Browser" tippen. Die generische
            // Fehlermeldung ("hat nicht geklappt, bitte erneut versuchen") waere
            // hier eine Luege — kein Wiederholen richtet eine fehlende Adresse.
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            try? kc.remove(forKey: KeychainKey.serverURL)
            let store = AuthStore(auth: service, keychain: kc)
            let authenticator = StubOidcAuthenticator(outcome: .canceled)
            store.oidcAuthenticator = authenticator

            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(store.lastError == .serverNotConfigured)
            #expect(store.phase == .unknown)
            // Der Browser wurde gar nicht erst geoeffnet.
            #expect(authenticator.capturedLoginURL == nil)
        }

        // MARK: - 2) cancel → no banner

        @MainActor
        @Test("a user-cancelled web-login sheet shows no error banner")
        func loginWithWebLoginCancelNoBanner() async {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            store.oidcAuthenticator = StubOidcAuthenticator(outcome: .canceled)

            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(store.lastError == nil)
            #expect(store.phase == .unknown)
        }

        // MARK: - 3) error callback (stale_session) surfaces, no token

        @MainActor
        @Test("a stale_session error callback surfaces the mapped message and stores no token")
        func staleSessionErrorSurfaces() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)

            try await store.handleWebLoginCallback(
                #require(URL(string: "healthlog://login-callback?error=stale_session")),
                codeVerifier: "verifier-0123456789012345678901234567890123"
            )
            #expect(store.lastError != nil)
            #expect(store.lastError?.localizedDescription == WebLoginErrorReason.staleSession.localizedMessage)
            #expect(store.phase == .unknown)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        // MARK: - 4) exchange 401 surfaces + no token

        @MainActor
        @Test("a consumed/expired code (401) surfaces as a login failure — no token stored")
        func tokenExchangeFailureSurfaces() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            let callback = try #require(URL(string: "healthlog://login-callback?code=hlh_used0000000000000000000000000000000000000"))

            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Invalid code"}"#.utf8)
                )
            }
            await store.handleWebLoginCallback(callback, codeVerifier: "verifier-0123456789012345678901234567890123")

            #expect(store.lastError != nil)
            #expect(store.phase == .unknown)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        // MARK: - 5) cross-flow guard — no exchange fired

        @MainActor
        @Test("an oidc-callback URL routed here surfaces a generic error and fires no exchange")
        func crossFlowCallbackFiresNoExchange() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            nonisolated(unsafe) var handlerHits = 0
            MockURLProtocol.handler = { req in
                handlerHits += 1
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }

            try await store.handleWebLoginCallback(
                #require(URL(string: "healthlog://oidc-callback?code=hlh_oidc00000000000000000000000000000000000000")),
                codeVerifier: "verifier-0123456789012345678901234567890123"
            )

            #expect(handlerHits == 0)
            #expect(store.lastError != nil)
            #expect(store.phase == .unknown)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }
    }

#endif
