// J1 / F1 — a refused password sign-in must say so, not "Sign-in expired".
//
// Drives the REAL `AuthStore` → `AuthService` → `APIClient` against the v1.39.2
// server responses of `POST /api/auth/login` (`src/app/api/auth/login/route.ts`
// at tag `v1.39.2`): 401 "Invalid credentials" without `meta.errorCode`, 422
// from the zod parse, 429 from the per-IP limiter, 403 `oidc_only`.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Password sign-in failure copy (J1 / F1)", .serialized, .mockURLSession)
    struct PasswordLoginFailureTests {
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

        private func makeStore() -> AuthStore {
            let keychain = InMemoryKeychain()
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            let service = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            return AuthStore(auth: service, keychain: keychain)
        }

        private func respond(status: Int, body: String, headers: [String: String]? = nil) {
            MockURLProtocol.install { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
                    Data(body.utf8)
                )
            }
        }

        private static let sessionExpired = HLError.unauthorized.userFacingDescription

        @Test("401 Invalid credentials reads as a wrong password, not an expired session")
        func wrongPassword() async throws {
            let store = makeStore()
            respond(status: 401, body: #"{"data":null,"error":"Invalid credentials"}"#)
            await store.login(email: "demo", password: "wrong")

            let error = try #require(store.lastError)
            #expect(error.userFacingDescription == String(localized: "onboarding.auth.error.invalidCredentials"))
            #expect(error.userFacingDescription != Self.sessionExpired)
            #expect(error != .unauthorized)
            #expect(store.phase == .unknown)
        }

        @Test("422 from the zod parse (empty field) reads as wrong credentials too")
        func emptyField() async throws {
            let store = makeStore()
            respond(
                status: 422,
                body: #"{"data":null,"error":"Invalid credentials","details":{"issues":[]}}"#
            )
            await store.login(email: "demo", password: "")

            let error = try #require(store.lastError)
            #expect(error.userFacingDescription == String(localized: "onboarding.auth.error.invalidCredentials"))
        }

        @Test("429 with Retry-After says how long to wait (R2 / B)")
        func rateLimited() async throws {
            let store = makeStore()
            // Retry-After above the in-request ceiling: thrown straight back.
            respond(
                status: 429,
                body: #"{"data":null,"error":"Too many login attempts. Please try again later."}"#,
                headers: ["Retry-After": "900"]
            )
            await store.login(email: "demo", password: "pw")

            let error = try #require(store.lastError)
            let expected = String(localized: "onboarding.auth.error.rateLimitedRetry \(AuthStore.signInRetryWait(900))")
            #expect(error.userFacingDescription == expected)
            #expect(error.userFacingDescription != String(localized: "onboarding.auth.error.rateLimited"))
            #expect(error.userFacingDescription != Self.sessionExpired)
            #expect(error.userFacingDescription != String(localized: "onboarding.auth.error.invalidCredentials"))
        }

        @Test("v1.39.3 per-account back-off: a 30 s Retry-After reads in seconds, not as 'a few minutes'")
        func rateLimitedShortWait() async throws {
            let store = makeStore()
            // ≤ the in-request ceiling, but login is `maxRetries: 0` — no silent wait.
            respond(
                status: 429,
                body: #"{"data":null,"error":"Too many login attempts. Please try again later."}"#,
                headers: ["Retry-After": "30"]
            )
            await store.login(email: "demo", password: "pw")

            let error = try #require(store.lastError)
            #expect(error.userFacingDescription
                == String(localized: "onboarding.auth.error.rateLimitedRetry \(AuthStore.signInRetryWait(30))"))
        }

        @Test("429 without a usable Retry-After keeps the J1 sentence")
        func rateLimitedWithoutWait() async throws {
            let store = makeStore()
            respond(
                status: 429,
                body: #"{"data":null,"error":"Too many login attempts. Please try again later."}"#
            )
            await store.login(email: "demo", password: "pw")

            let error = try #require(store.lastError)
            #expect(error.userFacingDescription == String(localized: "onboarding.auth.error.rateLimited"))
        }

        @Test("the wait is rounded up, in seconds below a minute and whole minutes above")
        func retryWaitFormatting() {
            let en = Locale(identifier: "en_US")
            #expect(AuthStore.signInRetryWait(30, locale: en) == "30 seconds")
            #expect(AuthStore.signInRetryWait(59.2, locale: en) == "1 minute")
            #expect(AuthStore.signInRetryWait(60, locale: en) == "1 minute")
            #expect(AuthStore.signInRetryWait(90, locale: en) == "2 minutes")
            #expect(AuthStore.signInRetryWait(900, locale: en) == "15 minutes")
            let de = Locale(identifier: "de_DE")
            #expect(AuthStore.signInRetryWait(900, locale: de) == "15 Minuten")
        }

        @Test("403 oidc_only keeps its server code and reads as SSO-only")
        func oidcOnly() async throws {
            let store = makeStore()
            respond(
                status: 403,
                body: #"{"data":null,"error":"Password login is disabled. Sign in with SSO.","meta":{"errorCode":"oidc_only"}}"#
            )
            await store.login(email: "demo", password: "pw")

            let error = try #require(store.lastError)
            guard case let .server(status, code, _) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(status == 403)
            #expect(code == "oidc_only")
            #expect(error.userFacingDescription == String(localized: "onboarding.auth.error.passwordLoginDisabled"))
        }

        @Test("a real expired session keeps its own copy; unknown codes pass through")
        func mappingIsNarrow() {
            #expect(HLError.unauthorized.userFacingDescription == Self.sessionExpired)
            let other = HLError.server(status: 400, code: "something.else", message: "Server sentence")
            #expect(AuthStore.passwordLoginFailure(other) == other)
            let outage = HLError.server(status: 503, code: nil, message: "down")
            #expect(AuthStore.passwordLoginFailure(outage) == outage)
            #expect(AuthStore.passwordLoginFailure(.offline) == .offline)
        }
    }

#endif
