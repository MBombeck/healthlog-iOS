// #49 / v1.30.11 — pins the native OIDC SSO login flow.
//
// Coverage (per the coordination contract in GH #49 + openapi.yaml
// POST /api/auth/oidc/native/token):
//   1. PKCE S256 challenge derivation from a known verifier (RFC 7636 App. B).
//   2. the native/token exchange request SHAPE (body {code, codeVerifier} +
//      X-Client-Type: native header) + the standard bundle decode → stored.
//   3. the `mfa_ticket` callback branch routes into the existing #37 MFA-verify
//      flow (challenge raised, no token yet).
//   4. each closed-set `error=<reason>` maps to a surfaced, non-empty message.
//
// Drives the REAL `APIClient` over a stub `URLProtocol`, per the repo's
// no-mock-server doctrine.

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("OIDC SSO login (#49)", .serialized)
    struct OidcSSOLoginTests {
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

        /// Test double for the ASWebAuthenticationSession driver — returns a
        /// canned callback URL without ever opening a web sheet.
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
                "user": { "id": "user-sso-1", "username": "ssouser" },
                "token": "hlk_bearer_SSO",
                "tokenExpiresAt": "2026-07-01T12:00:00Z",
                "refreshToken": "hlr_refresh_SSO",
                "refreshTokenExpiresAt": "2026-09-01T12:00:00Z"
              },
              "error": null
            }
            """#.utf8)
        }

        // MARK: - 1) PKCE S256 derivation

        @Test("PKCE S256 challenge matches the RFC 7636 Appendix B test vector")
        func pkceKnownVectorDerivation() {
            // RFC 7636 Appendix B: verifier → SHA256 → base64url = challenge.
            let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
            #expect(OidcPKCE.s256Challenge(for: verifier) == expected)
            #expect(OidcPKCE(codeVerifier: verifier).codeChallenge == expected)
        }

        @Test("PKCE generate() emits a verifier in the RFC 7636 43–128 char range")
        func pkceGeneratedVerifierShape() {
            let pkce = OidcPKCE.generate()
            #expect(pkce.codeVerifier.count >= 43)
            #expect(pkce.codeVerifier.count <= 128)
            // base64url alphabet only (no padding, no +/).
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            #expect(pkce.codeVerifier.allSatisfy(allowed.contains))
            #expect(pkce.codeChallenge == OidcPKCE.s256Challenge(for: pkce.codeVerifier))
        }

        // MARK: - 2) native/token exchange request shape + bundle decode → stored

        @Test("oidcNativeTokenExchange posts {code, codeVerifier} + X-Client-Type: native and stores the bundle")
        func tokenExchangeShapeAndPersist() async throws {
            let (service, kc) = makeService()
            nonisolated(unsafe) var capturedBody: Data?
            nonisolated(unsafe) var capturedClientType: String?
            nonisolated(unsafe) var capturedPath: String?
            MockURLProtocol.handler = { req in
                capturedPath = req.url?.path
                capturedClientType = req.value(forHTTPHeaderField: "X-Client-Type")
                capturedBody = req.httpBody ?? req.httpBodyStream.map { stream in
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let size = 4096
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                    defer { buf.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buf, maxLength: size)
                        if read <= 0 { break }
                        data.append(buf, count: read)
                    }
                    return data
                }
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }

            let session = try await service.oidcNativeTokenExchange(
                code: "hlh_abcABC0123456789012345678901234567890123",
                codeVerifier: "verifier-xyz-0123456789012345678901234567890"
            )

            #expect(session.token == "hlk_bearer_SSO")
            #expect(session.user.id == "user-sso-1")
            #expect(capturedPath == "/api/auth/oidc/native/token")
            #expect(capturedClientType == "native")
            let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("hlh_abcABC0123456789012345678901234567890123"))
            #expect(bodyString.contains("verifier-xyz-0123456789012345678901234567890"))
            // Stored + rotatable exactly like password/passkey login.
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_SSO")
            #expect(kc.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_SSO")
        }

        @Test("a consumed/expired code (401) surfaces as a login failure — no token stored")
        @MainActor
        func tokenExchangeFailureSurfaces() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            let callback = try #require(URL(string: "healthlog://oidc-callback?code=hlh_used0000000000000000000000000000000000000"))

            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Invalid or expired code"}"#.utf8)
                )
            }
            await store.handleSSOCallback(callback, codeVerifier: "verifier-0123456789012345678901234567890123")

            #expect(store.lastError != nil)
            #expect(store.phase == .unknown)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        // MARK: - 3) mfa_ticket branch routes into the existing MFA-verify flow

        @MainActor
        @Test("mfa_ticket callback raises the existing MFA challenge (no token yet)")
        func mfaTicketBranchRaisesChallenge() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            let callback = try #require(URL(
                string: "healthlog://oidc-callback?mfa_ticket=tkt_SSO123&methods=totp,recovery,webauthn"
            ))

            await store.handleSSOCallback(callback, codeVerifier: "verifier-0123456789012345678901234567890123")

            let challenge = store.mfaChallenge
            #expect(challenge != nil)
            #expect(challenge?.methods == [.totp, .recovery, .webauthn])
            // Still pre-auth — no phase promotion, no token.
            #expect(store.phase == .unknown)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        @MainActor
        @Test("full loginWithSSO happy path via stub authenticator exchanges + promotes phase")
        func loginWithSSOHappyPath() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            let authenticator = try StubOidcAuthenticator(
                outcome: .callback(
                    #require(URL(string: "healthlog://oidc-callback?code=hlh_ok00000000000000000000000000000000000000000"))
                )
            )
            store.oidcAuthenticator = authenticator

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }
            await store.loginWithSSO(anchor: StubAnchor())

            #expect(store.phase == .authenticating(User(
                id: "user-sso-1",
                email: nil,
                username: "ssouser",
                displayName: nil,
                createdAt: nil
            )))
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_SSO")
            // The authorize URL carried the native opt-in + a code_challenge.
            let url = authenticator.capturedLoginURL?.absoluteString ?? ""
            #expect(url.contains("/api/auth/oidc/login"))
            #expect(url.contains("client=native"))
            #expect(url.contains("code_challenge="))
        }

        @MainActor
        @Test("a user-cancelled SSO sheet shows no error banner")
        func loginWithSSOCancelNoBanner() async {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            store.oidcAuthenticator = StubOidcAuthenticator(outcome: .canceled)

            await store.loginWithSSO(anchor: StubAnchor())

            #expect(store.lastError == nil)
            #expect(store.phase == .unknown)
        }

        // MARK: - 4) each error reason maps to a surfaced message

        @Test("every closed-set error reason parses + maps to a non-empty distinct message")
        func errorReasonsMapToMessages() throws {
            let cases: [(String, OidcErrorReason)] = [
                ("denied", .denied),
                ("no-email", .noEmail),
                ("email-unverified", .emailUnverified),
                ("identity-conflict", .identityConflict),
                ("registration-disabled", .registrationDisabled),
                ("rate-limited", .rateLimited)
            ]
            var seen = Set<String>()
            for (raw, expected) in cases {
                #expect(OidcErrorReason(raw: raw) == expected)
                let url = try #require(URL(string: "healthlog://oidc-callback?error=\(raw)"))
                #expect(OidcCallback.parse(url) == .error(expected))
                let message = expected.localizedMessage
                #expect(!message.isEmpty)
                seen.insert(message)
            }
            // Distinct copy per reason (no accidental shared string).
            #expect(seen.count == cases.count)
            // An out-of-set reason falls back to the generic message, not a crash.
            let unknown = OidcErrorReason(raw: "some-future-reason")
            #expect(unknown == .unknown("some-future-reason"))
            #expect(!unknown.localizedMessage.isEmpty)
        }

        @MainActor
        @Test("an error callback surfaces the mapped message and stores no token")
        func errorCallbackSurfacesMessage() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)

            try await store.handleSSOCallback(
                #require(URL(string: "healthlog://oidc-callback?error=identity-conflict")),
                codeVerifier: "verifier-0123456789012345678901234567890123"
            )
            #expect(store.lastError != nil)
            #expect(store.phase == .unknown)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }
    }

#endif
