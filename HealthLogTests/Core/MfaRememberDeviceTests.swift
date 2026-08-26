// Parity 2.4 — "remember this device" on MFA verify.
//
// `AuthService.verifyMFA` has accepted a `rememberDevice` argument since #37,
// but nothing ever passed it: `AuthStore.verifyMFA(method:code:)` called the
// three-argument overload, so the flag defaulted to `false` on every login and
// iOS users re-entered a TOTP code every single time while web users skipped it
// for 30 days. The gap was the *threading*, not the wire format — which is
// exactly why these tests assert against the bytes on the wire through the real
// `APIClient`, from the store entry point the UI actually calls.
//
// Also pinned: the recovery-code carve-out. The server refuses to trust a device
// on a recovery login (that path means "I lost my authenticator"), so the store
// must force the flag off there rather than send a promise the server drops.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("MFA remember-device threading (parity 2.4)", .serialized)
    struct MfaRememberDeviceTests {
        /// Passkey stub — the TOTP / recovery paths never touch it.
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

        private static let bundleBody = Data(#"""
        {
          "data": {
            "user": { "id": "user-rd-1", "username": "rd" },
            "token": "hlk_bearer_RD",
            "tokenExpiresAt": "2030-01-01T00:00:00Z",
            "refreshToken": "hlr_refresh_RD",
            "refreshTokenExpiresAt": "2030-01-01T00:00:00Z"
          },
          "error": null
        }
        """#.utf8)

        private static let mfaRequiredBody = Data(#"""
        {
          "data": null,
          "error": null,
          "meta": {
            "mfaRequired": true,
            "mfaTicket": "tkt_RD",
            "methods": ["totp", "recovery"]
          }
        }
        """#.utf8)

        private func makeService(
            _ keychain: InMemoryKeychain = InMemoryKeychain()
        ) -> (AuthService, InMemoryKeychain) {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            return (AuthService(api: api, keychain: keychain, passkey: NoopPasskey()), keychain)
        }

        /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
        private static func body(of request: URLRequest) -> String {
            let data = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var acc = Data()
                let size = 4096
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buf, maxLength: size)
                    if read <= 0 { break }
                    acc.append(buf, count: read)
                }
                return acc
            }
            return String(data: data ?? Data(), encoding: .utf8) ?? ""
        }

        // MARK: - AuthService level

        @Test("rememberDevice: true reaches the verify body")
        func serviceSendsFlagWhenOptedIn() async throws {
            let (service, _) = makeService()
            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.bundleBody
                )
            }
            _ = try await service.verifyMFA(
                ticket: "tkt_RD", method: .totp, code: "123456", rememberDevice: true
            )
            #expect(captured.contains("\"rememberDevice\":true"))
        }

        @Test("rememberDevice: false omits the key entirely rather than sending an explicit false")
        func serviceOmitsFlagWhenNotOptedIn() async throws {
            let (service, _) = makeService()
            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.bundleBody
                )
            }
            _ = try await service.verifyMFA(
                ticket: "tkt_RD", method: .totp, code: "123456", rememberDevice: false
            )
            #expect(!captured.contains("rememberDevice"))
        }

        // MARK: - AuthStore level (the threading the parity gap was actually about)

        /// Drives the store exactly as `MfaChallengeSheet` does: raise a challenge
        /// via a password login, then verify with the toggle on.
        @MainActor
        private func challengedStore() async -> (AuthStore, InMemoryKeychain) {
            let keychain = InMemoryKeychain()
            let (service, _) = makeService(keychain)
            let store = AuthStore(auth: service, keychain: keychain)
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.mfaRequiredBody
                )
            }
            await store.login(email: "u@e.co", password: "pw")
            return (store, keychain)
        }

        @Test("AuthStore threads the toggle through to the wire on the TOTP path")
        @MainActor
        func storeThreadsFlagOnTotp() async {
            let (store, _) = await challengedStore()
            #expect(store.mfaChallenge != nil)

            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.bundleBody
                )
            }
            await store.verifyMFA(method: .totp, code: "123456", rememberDevice: true)
            // The regression this whole item exists to prevent.
            #expect(captured.contains("\"rememberDevice\":true"))
        }

        @Test("AuthStore still omits the flag when the user leaves the toggle off")
        @MainActor
        func storeOmitsFlagByDefault() async {
            let (store, _) = await challengedStore()

            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.bundleBody
                )
            }
            await store.verifyMFA(method: .totp, code: "123456")
            #expect(!captured.contains("rememberDevice"))
        }

        @Test("A recovery-code login forces the flag off even when the caller asks for it")
        @MainActor
        func storeForcesFlagOffOnRecovery() async {
            let (store, _) = await challengedStore()

            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.bundleBody
                )
            }
            await store.verifyMFA(method: .recovery, code: "recovery-code-abc", rememberDevice: true)
            #expect(captured.contains("\"method\":\"recovery\""))
            // The server would drop the trust anyway; sending it would be a lie.
            #expect(!captured.contains("rememberDevice"))
        }
    }

#endif
