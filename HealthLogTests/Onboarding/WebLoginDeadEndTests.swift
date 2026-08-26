// 13-02 (K7 client half + K5) — the web-handoff leg must never leave a new
// user on a browser error page with no way back, and the "sign in with
// password instead" link must actually reveal something.
//
// Build 266's server answers a valid S256 challenge with
// `307 → https://0.0.0.0:3000/auth/login?flow=native` (issue #96): a redirect
// built from the process bind address instead of the forwarded host. The
// client cannot reach that address and does not try to correct it — the
// server's bug stays the server's. What IS the client's is what happens next.
//
// Drives the REAL `AuthStore` over a stub authenticator and a session-scoped
// `MockURLProtocolSession` (09-13), per the no-mock-server doctrine.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Web-login dead ends (13-02)", .serialized)
    struct WebLoginDeadEndTests {
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

        /// The address the operator's instance actually redirects to (#96),
        /// verbatim from the measurement.
        private static let deadEndRedirect = "https://0.0.0.0:3000/auth/login?flow=native"

        @MainActor
        private func makeStore(
            _ session: MockURLProtocolSession,
            keychain: InMemoryKeychain = InMemoryKeychain()
        ) -> (AuthStore, InMemoryKeychain) {
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            // The web leg builds its URL from `currentBaseURL(keychain:)`, not
            // from `environment` — the app carries no built-in server.
            try? keychain.setString(session.baseURL.absoluteString, forKey: KeychainKey.serverURL)
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
            let service = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            return (AuthStore(auth: service, keychain: keychain), keychain)
        }

        // MARK: - 1) the dead end

        /// The session hands back the address it died on rather than a
        /// `healthlog://login-callback`. Today the store publishes a generic
        /// error and stops there — the user is looking at a browser error page
        /// and the screen behind it still has no password form on it.
        @MainActor
        @Test("Eine Sackgasse im Browser führt zurück auf das Passwortformular")
        func nonRoutableRedirectFailsBackToPasswordForm() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let (store, keychain) = makeStore(session)
            store.oidcAuthenticator = try StubOidcAuthenticator(
                outcome: .callback(#require(URL(string: Self.deadEndRedirect)))
            )

            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(
                store.lastError != nil && store.passwordFallbackRevealed,
                "EXPECTED_RED: a dead-ended web login strands the user with no way back"
            )
            // Nothing was signed in and nothing was stored — the leg failed,
            // it did not half-succeed.
            #expect(store.phase == .unknown)
            #expect(keychain.getString(forKey: KeychainKey.authToken) == nil)
        }

        // MARK: - 2) the fallback link

        /// Driven in the order a device walks it: the step switches while the
        /// probe is still in flight, the form's `.onAppear` fires, the probe
        /// lands, and only then does the user tap "sign in with password
        /// instead". Today the `.onAppear` latch already fired, so the tap has
        /// nothing left to reveal and only moves the cursor.
        @Test("Der Rückfall-Link öffnet ein Formular, das vorher zu war")
        func fallbackLinkRevealsTheHiddenForm() {
            var availability = WebLoginAvailability.probing
            var latched = false
            func visibility() -> AuthStepFormVisibility {
                AuthStepFormVisibility(
                    prefersWebHandoff: true,
                    availability: availability,
                    latched: latched
                )
            }

            // First render, probe still in flight.
            if visibility().showsEmailSection, visibility().mayLatchOnAppear { latched = true }
            // The probe lands: this server does serve the web-handoff contract.
            availability = .available
            let hiddenBeforeTap = !visibility().showsEmailSection
            // The user taps the fallback link.
            latched = true
            let visibleAfterTap = visibility().showsEmailSection

            #expect(
                hiddenBeforeTap && visibleAfterTap,
                "EXPECTED_RED: the fallback link has nothing to reveal because the form latched open"
            )
            #expect(visibility().showsWebHandoffCTA)
        }

        // MARK: - the other two ways the leg can end without a session

        /// The session could not start, or ended without a callback at all.
        @MainActor
        @Test("Eine gescheiterte Browser-Sitzung sagt es und öffnet das Formular")
        func failedSessionStatesItAndOpensTheForm() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let (store, _) = makeStore(session)
            store.oidcAuthenticator = StubOidcAuthenticator(outcome: .failed)

            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(store.lastError != nil)
            #expect(store.passwordFallbackRevealed)
        }

        /// A user who dismissed the sheet gets the form — because the reason
        /// they dismissed it may well have been an error page — but NOT a red
        /// banner they did not ask for. Both halves matter.
        @MainActor
        @Test("Ein Abbruch öffnet das Formular, ohne ein Banner zu behaupten")
        func cancellationOpensTheFormWithoutABanner() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let (store, _) = makeStore(session)
            store.oidcAuthenticator = StubOidcAuthenticator(outcome: .canceled)

            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(store.lastError == nil)
            #expect(store.passwordFallbackRevealed)
        }

        /// A signed-in user has no fallback left to take, so accepting a
        /// session closes it again. Without this the form would still be open
        /// behind the shell on the next visit to the auth step.
        @MainActor
        @Test("Eine erfolgreiche Anmeldung schließt den Rückfall wieder")
        func acceptedSessionClearsTheFallback() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"""
                    {"data":{"user":{"id":"user-web-1","username":"webuser"},
                     "token":"hlk_bearer_WEB","tokenExpiresAt":"2026-07-01T12:00:00Z",
                     "refreshToken":"hlr_refresh_WEB","refreshTokenExpiresAt":"2026-09-01T12:00:00Z"},
                     "error":null}
                    """#.utf8)
                )
            }
            let (store, _) = makeStore(session)
            store.oidcAuthenticator = StubOidcAuthenticator(outcome: .failed)
            await store.loginWithWebLogin(anchor: StubAnchor())
            #expect(store.passwordFallbackRevealed)

            store.oidcAuthenticator = try StubOidcAuthenticator(
                outcome: .callback(
                    #require(URL(string: "healthlog://login-callback?code=hlh_ok0000000000000000000000000000000000000000"))
                )
            )
            await store.loginWithWebLogin(anchor: StubAnchor())

            #expect(store.passwordFallbackRevealed == false)
        }

        // MARK: - control (green before and after)

        /// The host where no handoff is possible at all: the password form is
        /// the primary door, present from the first render and latched. This
        /// must not change in either direction.
        @Test("Ohne Browser-Übergabe bleibt das Passwortformular die Haupttür")
        func withoutHandoffTheFormIsThePrimaryDoor() {
            for availability in [WebLoginAvailability.probing, .available, .unavailable] {
                let visibility = AuthStepFormVisibility(
                    prefersWebHandoff: false,
                    availability: availability,
                    latched: false
                )
                #expect(visibility.showsEmailSection)
                #expect(visibility.showsWebHandoffCTA == false)
                #expect(visibility.mayLatchOnAppear)
            }
        }

        /// The other end of the latch rule: once the probe has come back and
        /// said "no handoff here", the form is the primary door again and may
        /// latch itself open exactly as it always did. A fix that left it
        /// permanently unlatchable would be a different bug.
        @Test("Sagt die Probe Nein, rastet das Formular wie eh und je ein")
        func aSettledNegativeProbeRestoresTheLatch() {
            let probing = AuthStepFormVisibility(
                prefersWebHandoff: true,
                availability: .probing,
                latched: false
            )
            let settled = AuthStepFormVisibility(
                prefersWebHandoff: true,
                availability: .unavailable,
                latched: false
            )
            #expect(probing.mayLatchOnAppear == false)
            #expect(settled.mayLatchOnAppear)
            // In both states the form is on screen — a sign-in step is never
            // blank while the app makes up its mind.
            #expect(probing.showsEmailSection)
            #expect(settled.showsEmailSection)
        }
    }

#endif
