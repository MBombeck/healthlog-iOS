// L1 — a refused passkey sign-in must say so, not "Sign-in expired".
//
// Drives the REAL `AuthStore` → `AuthService` → `APIClient` against the v1.39.2
// server answers of the two passkey legs (`src/app/api/auth/passkey/
// login-options/route.ts`, `login-verify/route.ts` at tag `v1.39.2`):
// 401 "Passkey verification failed", 404 "User not found", 403 `oidc_only`,
// 429 from the per-IP limiter. The passkey sheet itself is stubbed; the sheet
// answers (assertion, cancel) are the ones `PasskeyService` hands on.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Passkey sign-in failure copy (L1)", .serialized, .mockURLSession)
    struct PasskeyLoginFailureTests {
        private func makeStore(passkeyError: (any Error)? = nil) -> AuthStore {
            let keychain = InMemoryKeychain()
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            let passkey = Phase09AuthStubPasskey(assertionError: passkeyError)
            let service = AuthService(api: api, keychain: keychain, passkey: passkey)
            return AuthStore(auth: service, keychain: keychain)
        }

        /// `login-options` answers with a challenge; `login-verify` answers
        /// `status` + `body`.
        private func respondToVerify(status: Int, body: String, headers: [String: String]? = nil) {
            MockURLProtocol.install { req in
                let url = req.url!
                if url.path.hasSuffix("/api/auth/passkey/login-options") {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Phase09AuthBody.passkeyOptions
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
                    Data(body.utf8)
                )
            }
        }

        private static let sessionExpired = HLError.unauthorized.userFacingDescription
        private static let rejected = String(localized: "auth.passkey.error.rejected")

        @Test("401 Passkey verification failed reads as a refused passkey, not an expired session")
        func verificationFailed() async throws {
            let store = makeStore()
            respondToVerify(status: 401, body: #"{"data":null,"error":"Passkey verification failed"}"#)
            await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

            let error = try #require(store.lastError)
            #expect(error != .unauthorized)
            #expect(error.signInFacingDescription == Self.rejected)
            #expect(error.signInFacingDescription != Self.sessionExpired)
            #expect(error.userFacingDescription != Self.sessionExpired)
            #expect(store.phase == .unknown)
        }

        @Test("404 User not found (the passkey's account is gone) reads as a refused passkey")
        func accountGone() async throws {
            let store = makeStore()
            respondToVerify(status: 404, body: #"{"data":null,"error":"User not found"}"#)
            await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

            let error = try #require(store.lastError)
            #expect(error.signInFacingDescription == Self.rejected)
        }

        @Test("403 oidc_only keeps its code and reads as SSO-only")
        func oidcOnly() async throws {
            let store = makeStore()
            respondToVerify(
                status: 403,
                body: #"{"data":null,"error":"Passkey login is disabled. Sign in with SSO.","meta":{"errorCode":"oidc_only"}}"#
            )
            await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

            let error = try #require(store.lastError)
            guard case let .server(status, code, _) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(status == 403)
            #expect(code == "oidc_only")
            #expect(error.signInFacingDescription == String(localized: "auth.passkey.error.ssoOnly"))
        }

        @Test("429 gets the sign-in rate-limit sentence")
        func rateLimited() async throws {
            let store = makeStore()
            respondToVerify(
                status: 429,
                body: #"{"data":null,"error":"Too many attempts. Please wait 15 minutes."}"#,
                headers: ["Retry-After": "900"]
            )
            await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

            let error = try #require(store.lastError)
            // R2 / B — the 429 named its wait, so the sentence names it too.
            #expect(error.signInFacingDescription == AuthStore.rateLimitedSignIn(retryAfter: 900).signInFacingDescription)
            #expect(error.signInFacingDescription.contains(AuthStore.signInRetryWait(900)))
            #expect(error.signInFacingDescription != Self.sessionExpired)
        }

        #if canImport(AuthenticationServices)
            @Test("a cancelled passkey sheet raises no banner at all")
            func cancelledSheet() async {
                let store = makeStore(passkeyError: ASAuthorizationError(.canceled))
                respondToVerify(status: 200, body: "{}")
                await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

                #expect(store.lastError == nil)
                #expect(store.isWorking == false)
            }
        #endif

        @Test("no network reads as an unreachable server, not as cached data or an expired session")
        func offline() async throws {
            let store = makeStore()
            MockURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
            await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

            let error = try #require(store.lastError)
            #expect(error.signInFacingDescription == String(localized: "auth.error.unreachable"))
            #expect(error.signInFacingDescription != Self.sessionExpired)
            #expect(error.signInFacingDescription != HLError.offline.userFacingDescription)
        }

        @Test("the mapping is narrow: an expired session and a server fault keep their copy")
        func mappingIsNarrow() {
            #expect(HLError.unauthorized.userFacingDescription == Self.sessionExpired)
            let outage = HLError.server(status: 500, code: nil, message: "Interner Serverfehler")
            #expect(AuthStore.passkeyLoginFailure(outage) == outage)
            #expect(AuthStore.passkeyLoginFailure(.offline) == .offline)
            let other = HLError.server(status: 400, code: "something.else", message: "Server sentence")
            #expect(AuthStore.passkeyLoginFailure(other) == other)
            // The sign-in banner never shows a 5xx body (it may be a leaked stack line).
            #expect(outage.signInFacingDescription == outage.userFacingDescription)
        }
    }

#endif
