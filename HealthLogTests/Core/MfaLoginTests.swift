// #37 / v1.23.0 — pins the two-factor login handling.
//
// Before #37 an MFA-enrolled user's password login (`200 { data: null,
// error: null, meta: { mfaRequired: true, mfaTicket, methods } }`) fell
// through to a raw `NativeLoginResponse` decode and threw a misleading
// "no Bearer token" error — hard-locking the user out of the native app.
//
// These tests drive the REAL `APIClient` (no mock client) against a stub
// `URLProtocol`, per the repo's no-mock-server doctrine:
//   1. an MFA-required 200 → `login` returns `.mfaRequired`, NOT a throw.
//   2. a normal 200 → `login` still returns `.session` (no regression).
//   3. `verifyMFA` decodes the SAME token bundle and persists the session.
//   4. the MFA ticket is held transiently in `AuthStore` (challenge raised
//      on `.mfaRequired`, cleared on verify-success / cancel).

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("MFA login (#37)", .serialized)
    struct MfaLoginTests {
        /// Passkey stub — verifyMFA(TOTP/recovery) never touches it.
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

        private func makeService(_ keychain: InMemoryKeychain = InMemoryKeychain()) -> (AuthService, InMemoryKeychain) {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            return (AuthService(api: api, keychain: keychain, passkey: NoopPasskey()), keychain)
        }

        private static let mfaRequiredBody = Data(#"""
        {
          "data": null,
          "error": null,
          "meta": {
            "mfaRequired": true,
            "mfaTicket": "tkt_ABC123",
            "methods": ["totp", "recovery", "webauthn"]
          }
        }
        """#.utf8)

        private static func bundleBody() -> Data {
            Data(#"""
            {
              "data": {
                "user": { "id": "user-mfa-1", "username": "mfauser" },
                "token": "hlk_bearer_MFA",
                "tokenExpiresAt": "2026-07-01T12:00:00Z",
                "refreshToken": "hlr_refresh_MFA",
                "refreshTokenExpiresAt": "2026-09-01T12:00:00Z"
              },
              "error": null
            }
            """#.utf8)
        }

        // MARK: - AuthService.login branching

        @Test("MFA-required 200 → .mfaRequired (not a thrown 'no Bearer token' error)")
        func loginReturnsMfaRequired() async throws {
            let (service, kc) = makeService()
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.mfaRequiredBody)
            }
            let outcome = try await service.login(email: "u@e.co", password: "pw")
            switch outcome {
            case let .mfaRequired(ticket, methods):
                #expect(ticket == "tkt_ABC123")
                #expect(methods == [.totp, .recovery, .webauthn])
            case .session:
                Issue.record("expected .mfaRequired, got .session")
            }
            // No token persisted on the challenge branch.
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        @Test("Normal 200 → .session (no regression)")
        func loginReturnsSession() async throws {
            let (service, kc) = makeService()
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }
            let outcome = try await service.login(email: "u@e.co", password: "pw")
            switch outcome {
            case let .session(session):
                #expect(session.token == "hlk_bearer_MFA")
                #expect(session.user.id == "user-mfa-1")
            case .mfaRequired:
                Issue.record("expected .session, got .mfaRequired")
            }
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_MFA")
        }

        // MARK: - AuthService.verifyMFA

        @Test("verifyMFA decodes the token bundle and persists the session")
        func verifyMfaPersists() async throws {
            let (service, kc) = makeService()
            nonisolated(unsafe) var capturedBody: Data?
            MockURLProtocol.handler = { req in
                // URLProtocol strips httpBody onto httpBodyStream; read either.
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
                #expect(req.url?.path == "/api/auth/mfa/verify")
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }
            let session = try await service.verifyMFA(ticket: "tkt_ABC123", method: .totp, code: "123456")
            #expect(session.token == "hlk_bearer_MFA")
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_MFA")
            #expect(kc.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_MFA")
            // Body carries the ticket + method, omits rememberDevice (default false).
            let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("tkt_ABC123"))
            #expect(bodyString.contains("\"method\":\"totp\""))
            #expect(!bodyString.contains("rememberDevice"))
        }

        // MARK: - AuthStore transient ticket holding

        @MainActor
        @Test("AuthStore holds the ticket transiently: challenge up on .mfaRequired, cleared on verify-success")
        func storeHoldsTicketTransiently() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)

            // 1) Password login → server demands a second factor.
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.mfaRequiredBody)
            }
            await store.login(email: "u@e.co", password: "pw")
            let challenge = try #require(store.mfaChallenge, "challenge must be raised on .mfaRequired")
            #expect(challenge.methods == [.totp, .recovery, .webauthn])
            #expect(store.lastError == nil)
            // Still pre-auth — no phase promotion until a code verifies.
            #expect(store.phase == .unknown)

            // 2) Correct code → verify returns the bundle → challenge cleared,
            //    phase joins the normal post-login handoff.
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.bundleBody())
            }
            await store.verifyMFA(method: .totp, code: "123456")
            #expect(store.mfaChallenge == nil, "challenge must clear on verify-success")
            #expect(store.phase == .authenticating(User(
                id: "user-mfa-1",
                email: nil,
                username: "mfauser",
                displayName: nil,
                createdAt: nil
            )))
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_MFA")
        }

        // MARK: - #37/H1 — wrong code retries, dead ticket ejects

        @MainActor
        @Test("wrong code (401 'Invalid code') keeps the challenge sheet open for retry")
        func wrongCodeStaysOnSheet() async {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.mfaRequiredBody)
            }
            await store.login(email: "u@e.co", password: "pw")
            #expect(store.mfaChallenge != nil)

            // Server rejects a wrong code with 401 + body "Invalid code".
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Invalid code"}"#.utf8)
                )
            }
            await store.verifyMFA(method: .totp, code: "000000")

            // Stays on the sheet — NOT ejected to the password form.
            #expect(store.mfaChallenge != nil, "a wrong code must keep the challenge open")
            #expect(store.lastError != nil)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        @MainActor
        @Test("dead ticket (401 'Invalid or expired challenge') routes back to the password form")
        func deadTicketEjectsToPassword() async {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.mfaRequiredBody)
            }
            await store.login(email: "u@e.co", password: "pw")
            #expect(store.mfaChallenge != nil)

            // Server reports a dead ticket with 401 + body "Invalid or expired challenge".
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Invalid or expired challenge"}"#.utf8)
                )
            }
            await store.verifyMFA(method: .totp, code: "123456")

            // Challenge cleared → password form revealed with an inline message.
            #expect(store.mfaChallenge == nil, "a dead ticket must clear the challenge")
            #expect(store.lastError != nil)
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        }

        @MainActor
        @Test("cancelMFA clears the transient challenge and error")
        func cancelClearsChallenge() async {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            let store = AuthStore(auth: service, keychain: kc)
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.mfaRequiredBody)
            }
            await store.login(email: "u@e.co", password: "pw")
            #expect(store.mfaChallenge != nil)
            store.cancelMFA()
            #expect(store.mfaChallenge == nil)
            #expect(store.lastError == nil)
        }
    }

#endif
