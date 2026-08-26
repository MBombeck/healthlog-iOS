// #57 — native 2FA management over the step-up elevation contract.
//
// These tests pin the wire contract against the REAL `APIClient` over a stub
// URLSession (per PROJECT_GUIDE.md — no mock server), plus the pure pieces (body
// encoding, status decode, version gate, single-use elevation, log redaction)
// that carry the security-sensitive invariants. Fixtures are the exact server
// shapes verified against `src/app/api/auth/step-up/*` + `…/me/mfa/*` +
// `docs/api/openapi.yaml` on 2026-07-24.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Native 2FA — step-up elevation wire contract", .serialized)
    struct TwoFactorStepUpTests {
        // MARK: - Fixtures + helpers

        private func makeRepo() -> AccountSecurityRepository {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            return AccountSecurityRepository(api: api)
        }

        /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
        private nonisolated static func body(of request: URLRequest) -> String {
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

        private nonisolated static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        private nonisolated static func status(_ req: URLRequest, _ code: Int, _ json: String) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        // MARK: - Step-up mint bodies (discriminated union)

        @Test("Password mint body encodes { method, password } and nothing else")
        func mintPasswordBody() throws {
            let data = try JSONEncoder.hlDefault.encode(StepUpMintBody.password("s3cret"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json.count == 2)
            #expect(json["method"] as? String == "password")
            #expect(json["password"] as? String == "s3cret")
        }

        @Test("TOTP mint body encodes { method, code }")
        func mintTotpBody() throws {
            let data = try JSONEncoder.hlDefault.encode(StepUpMintBody.totp("123456"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json.count == 2)
            #expect(json["method"] as? String == "totp")
            #expect(json["code"] as? String == "123456")
        }

        @Test("Passkey mint body carries method + challengeId + credential envelope")
        func mintPasskeyBody() throws {
            let cred = WebAuthnAssertionCredential(
                id: "cred-1", rawId: "cred-1",
                response: .init(clientDataJSON: "cdj", authenticatorData: "ad", signature: "sig", userHandle: "uh")
            )
            let data = try JSONEncoder.hlDefault.encode(StepUpMintBody.passkey(challengeId: "ch-1", credential: cred))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["method"] as? String == "passkey")
            #expect(json["challengeId"] as? String == "ch-1")
            let credential = try #require(json["credential"] as? [String: Any])
            #expect(credential["type"] as? String == "public-key")
            let response = try #require(credential["response"] as? [String: Any])
            #expect(response["signature"] as? String == "sig")
        }

        @Test("WebAuthn mint body discriminates on method: webauthn")
        func mintWebauthnBodyMethod() throws {
            let cred = WebAuthnAssertionCredential(
                id: "k", rawId: "k",
                response: .init(clientDataJSON: "c", authenticatorData: "a", signature: "s", userHandle: nil)
            )
            let data = try JSONEncoder.hlDefault.encode(StepUpMintBody.webauthn(challengeId: "ch", credential: cred))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["method"] as? String == "webauthn")
            // A nil userHandle is omitted, not sent as null.
            let response = try #require((json["credential"] as? [String: Any])?["response"] as? [String: Any])
            #expect(response["userHandle"] == nil)
        }

        // MARK: - Step-up options body

        @Test("Options body encodes the ceremony method", arguments: [
            (StepUpCeremony.passkey, "passkey"),
            (StepUpCeremony.webauthn, "webauthn")
        ])
        func optionsBody(_ testCase: (ceremony: StepUpCeremony, expected: String)) throws {
            let data = try JSONEncoder.hlDefault.encode(StepUpOptionsRequestBody(ceremony: testCase.ceremony))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json.count == 1)
            #expect(json["method"] as? String == testCase.expected)
        }

        @Test("Repository sends the options body on POST /api/auth/step-up/options")
        func repoOptionsRequest() async throws {
            let repo = makeRepo()
            nonisolated(unsafe) var captured = ""
            nonisolated(unsafe) var path = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                path = req.url?.path ?? ""
                return Self.ok(
                    req,
                    #"{"data":{"challengeId":"ch","options":{"challenge":"c","rpId":"healthlog.local","allowCredentials":[]}},"error":null}"#
                )
            }
            _ = try await repo.stepUpOptions(.passkey)
            #expect(path == "/api/auth/step-up/options")
            #expect(captured.contains("\"method\":\"passkey\""))
        }

        // MARK: - X-Step-Up header passthrough

        @Test("TOTP setup rides the X-Step-Up header with the elevation token")
        func setupCarriesElevationHeader() async throws {
            let repo = makeRepo()
            nonisolated(unsafe) var header: String?
            nonisolated(unsafe) var path = ""
            MockURLProtocol.handler = { req in
                header = req.value(forHTTPHeaderField: "X-Step-Up")
                path = req.url?.path ?? ""
                return Self.ok(req, #"{"data":{"otpauthUri":"otpauth://totp/HealthLog?secret=ABC","totpSecret":"ABCDEFGH"},"error":null}"#)
            }
            let result = try await repo.totpSetup(elevation: "hle_deadbeef")
            #expect(path == "/api/auth/me/mfa/totp/setup")
            #expect(header == "hle_deadbeef")
            #expect(result.totpSecret == "ABCDEFGH")
        }

        @Test("Every elevation-gated route forwards the token in X-Step-Up")
        func allManagementRoutesForwardElevation() async throws {
            let repo = makeRepo()
            nonisolated(unsafe) var seen: [String: String] = [:]
            MockURLProtocol.handler = { req in
                seen[req.url?.path ?? ""] = req.value(forHTTPHeaderField: "X-Step-Up")
                return Self.ok(req, #"{"data":{"recoveryCodes":["a-b"],"recoveryCodesRemaining":1},"error":null}"#)
            }
            _ = try await repo.regenerateRecoveryCodes(elevation: "hle_regen")
            try await repo.disableTotp(code: "123456", method: .totp, elevation: "hle_disable")
            try await repo.renameSecurityKey(id: "k1", name: "Yubikey", elevation: "hle_rename")
            try await repo.deleteSecurityKey(id: "k1", elevation: "hle_delete")
            #expect(seen["/api/auth/me/mfa/recovery-codes/regenerate"] == "hle_regen")
            #expect(seen["/api/auth/me/mfa/disable"] == "hle_disable")
            #expect(seen["/api/auth/me/mfa/webauthn/k1"] == "hle_delete" || seen["/api/auth/me/mfa/webauthn/k1"] == "hle_rename")
        }

        // MARK: - TOTP confirm + disable bodies

        @Test("Confirm body carries only the code")
        func confirmBody() async throws {
            let repo = makeRepo()
            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return Self.ok(req, #"{"data":{"enabled":true,"recoveryCodes":["x-y","z-w"],"recoveryCodesRemaining":2},"error":null}"#)
            }
            let result = try await repo.totpConfirm(code: "654321", elevation: "hle_x")
            let json = try #require(JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any])
            #expect(json["code"] as? String == "654321")
            #expect(result.recoveryCodes.count == 2)
        }

        @Test("Disable body carries the current code and its method")
        func disableBody() async throws {
            let repo = makeRepo()
            nonisolated(unsafe) var captured = ""
            MockURLProtocol.handler = { req in
                captured = Self.body(of: req)
                return Self.ok(req, #"{"data":{"enabled":false},"error":null}"#)
            }
            try await repo.disableTotp(code: "abcd-efgh-ij", method: .recovery, elevation: "hle_x")
            let json = try #require(JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any])
            #expect(json["code"] as? String == "abcd-efgh-ij")
            #expect(json["method"] as? String == "recovery")
        }

        // MARK: - Fresh-factor gating (authorisation, not preference)

        @Test("Password is the only method that does NOT satisfy a fresh factor")
        func freshFactorMapping() {
            #expect(StepUpMethod.password.satisfiesFreshFactor == false)
            #expect(StepUpMethod.totp.satisfiesFreshFactor)
            #expect(StepUpMethod.webauthn.satisfiesFreshFactor)
            #expect(StepUpMethod.passkey.satisfiesFreshFactor)
        }

        @Test("A mint response echoes the server's satisfiesFreshFactor verbatim")
        func mintResponseFreshFactorDecode() throws {
            let json = #"{"elevation":"hle_abc","expiresAt":"2030-01-01T00:00:00Z","expiresInSeconds":300,"method":"password","satisfiesFreshFactor":false}"#
            let mint = try JSONDecoder.hlDefault.decode(StepUpMintResponse.self, from: Data(json.utf8))
            #expect(mint.satisfiesFreshFactor == false)
            #expect(mint.method == "password")
        }

        // MARK: - Status decode (the real source: GET /api/auth/me/mfa)

        @Test("MFA status decodes an enabled factor with keys and dates")
        func statusDecodeEnabled() throws {
            let json = #"""
            {"totp":{"enabled":true},"recoveryCodesRemaining":7,
             "webauthn":[{"id":"k1","name":"Yubikey","createdAt":"2026-01-01T00:00:00Z","lastUsedAt":null}],
             "passkeyNudgeDismissed":false}
            """#
            let status = try JSONDecoder.hlDefault.decode(MfaStatus.self, from: Data(json.utf8))
            #expect(status.totp.enabled)
            #expect(status.recoveryCodesRemaining == 7)
            #expect(status.webauthn.count == 1)
            #expect(status.webauthn.first?.lastUsedAt == nil)
        }

        @Test("MFA status decodes a disabled factor with no keys")
        func statusDecodeDisabled() throws {
            let json = #"{"totp":{"enabled":false},"recoveryCodesRemaining":0,"webauthn":[],"passkeyNudgeDismissed":true}"#
            let status = try JSONDecoder.hlDefault.decode(MfaStatus.self, from: Data(json.utf8))
            #expect(status.totp.enabled == false)
            #expect(status.webauthn.isEmpty)
        }

        @Test("Repository status read hits GET /api/auth/me/mfa (plain Bearer, no elevation)")
        func repoStatusRequest() async throws {
            let repo = makeRepo()
            nonisolated(unsafe) var method = ""
            nonisolated(unsafe) var header: String?
            MockURLProtocol.handler = { req in
                method = req.httpMethod ?? ""
                header = req.value(forHTTPHeaderField: "X-Step-Up")
                return Self.ok(
                    req,
                    #"{"data":{"totp":{"enabled":true},"recoveryCodesRemaining":3,"webauthn":[],"passkeyNudgeDismissed":false},"error":null}"#
                )
            }
            let status = try await repo.mfaStatus()
            #expect(method == "GET")
            #expect(header == nil, "status read must not present an elevation")
            #expect(status.totp.enabled)
        }

        // MARK: - Fail-close: step-up-required 401 body survives (preserves401Body)

        @Test("A step-up-required 401 on a management route surfaces its errorCode")
        func stepUpRequired401Surfaces() async throws {
            let repo = makeRepo()
            MockURLProtocol.handler = { req in
                Self.status(
                    req,
                    401,
                    #"{"data":null,"error":"Recent second-factor verification required","meta":{"errorCode":"auth.stepup.required"}}"#
                )
            }
            do {
                _ = try await repo.totpSetup(elevation: "hle_stale")
                Issue.record("expected a thrown error")
            } catch let err as HLError {
                #expect(
                    SecurityStepUp.isRequired(err),
                    "the auth.stepup.required code must reach the client, not collapse to .unauthorized"
                )
            }
        }

        @Test("A generic 401 from the step-up mint surfaces verbatim, not as a logout")
        func mintGeneric401Surfaces() async throws {
            let repo = makeRepo()
            MockURLProtocol.handler = { req in
                Self.status(req, 401, #"{"data":null,"error":"Verification failed","meta":{}}"#)
            }
            do {
                _ = try await repo.stepUpMint(.password("wrong"))
                Issue.record("expected a thrown error")
            } catch let err as HLError {
                guard case let .server(status, _, message) = err else {
                    Issue.record("expected .server, got \(err)")
                    return
                }
                #expect(status == 401)
                #expect(message == "Verification failed")
            }
        }
    }

    // MARK: - Version gate

    @Suite("2FA version gate")
    struct TwoFactorVersionGateTests {
        struct VersionCase {
            let version: String
            let target: String
            let expected: Bool
        }

        @Test("Component-wise compare beats a lexical one", arguments: [
            VersionCase(version: "1.32.9", target: "1.32.3", expected: true),
            VersionCase(version: "1.32.3", target: "1.32.3", expected: true),
            VersionCase(version: "1.32.2", target: "1.32.3", expected: false),
            VersionCase(version: "1.9.0", target: "1.32.3", expected: false), // lexical would wrongly say true
            VersionCase(version: "2.0.0", target: "1.32.3", expected: true),
            VersionCase(version: "1.32", target: "1.32.0", expected: true), // missing patch treated as 0
            VersionCase(version: "v1.33.0", target: "1.32.3", expected: true) // leading v tolerated
        ])
        func isAtLeast(_ testCase: VersionCase) {
            let info = ServerVersionInfo(version: testCase.version)
            #expect(info.isAtLeast(testCase.target) == testCase.expected)
        }

        @Test("An unparseable version fails closed")
        func unparseableFailsClosed() {
            #expect(ServerVersionInfo(version: "nightly").isAtLeast("1.32.3") == false)
        }

        @Test("TwoFactorManagement.isAvailable gates on the minimum version")
        func availabilityGate() {
            #expect(TwoFactorManagement.isAvailable(on: ServerVersionInfo(version: "1.32.9")))
            #expect(!TwoFactorManagement.isAvailable(on: ServerVersionInfo(version: "1.31.0")))
        }
    }

    // MARK: - Single-use elevation + redaction

    @Suite("Elevation single-use + log hygiene")
    struct ElevationHygieneTests {
        @Test("A ConsumableElevation yields its value exactly once")
        func singleUse() {
            let e = ConsumableElevation(StepUpElevation(token: "hle_abc", method: .passkey, satisfiesFreshFactor: true))
            #expect(e.isSpent == false)
            #expect(e.consume()?.token == "hle_abc")
            #expect(e.isSpent)
            #expect(e.consume() == nil, "a second consume must never re-yield the token")
        }

        @Test("An hle_ elevation token is redacted from a log line")
        func elevationRedacted() {
            let token = "hle_" + String(repeating: "a", count: 64)
            let redacted = LogSanitizer.redact("minted elevation \(token) for user")
            #expect(!redacted.contains(token))
            #expect(redacted.contains("[redacted-elevation]"))
        }

        @Test("A short hle_ value is still redacted (below the generic token floor)")
        func shortElevationRedacted() {
            let redacted = LogSanitizer.redact("X-Step-Up: hle_deadbeef here")
            #expect(!redacted.contains("hle_deadbeef"))
        }
    }

    // MARK: - Step-up service ceremony wiring (options → assert → mint)

    #if canImport(AuthenticationServices)

        @Suite("Step-up passkey ceremony wiring", .serialized)
        struct StepUpCeremonyTests {
            /// Fake passkey that returns a canned assertion — the TOTP/password
            /// arms never touch it, and this arm needs no real system sheet.
            private final class CannedPasskey: PasskeyServiceProtocol, @unchecked Sendable {
                @MainActor func register(
                    challenge _: String, rpId _: String, rpName _: String,
                    userID _: String, userName _: String, displayName _: String,
                    anchor _: ASPresentationAnchorProvider
                ) async throws -> PasskeyRegistration {
                    throw HLError.unknown("unused")
                }

                @MainActor func assert(
                    challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                    anchor _: ASPresentationAnchorProvider
                ) async throws -> PasskeyAssertion {
                    PasskeyAssertion(
                        credentialID: "cred-xyz",
                        clientDataJSON: "cdj",
                        authenticatorData: "authData",
                        signature: "signature",
                        userHandle: "uh"
                    )
                }
            }

            private final class StubAnchor: ASPresentationAnchorProvider, @unchecked Sendable {
                @MainActor func anchor() -> ASPresentationAnchor {
                    ASPresentationAnchor()
                }
            }

            private func makeService() -> (StepUpElevationService, AccountSecurityRepository) {
                let env = AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local")!,
                    bundleID: "dev.healthlog.app",
                    appVersion: "0.1.0",
                    buildNumber: "1"
                )
                let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
                let repo = AccountSecurityRepository(api: api)
                return (StepUpElevationService(repo: repo, passkey: CannedPasskey()), repo)
            }

            @Test("Passkey elevation runs options → assert → mint and carries the challengeId")
            @MainActor
            func passkeyCeremonyWiring() async throws {
                let (service, _) = makeService()
                nonisolated(unsafe) var mintBody = ""
                MockURLProtocol.handler = { req in
                    let path = req.url?.path ?? ""
                    if path == "/api/auth/step-up/options" {
                        return (
                            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Data(
                                #"{"data":{"challengeId":"challenge-42","options":{"challenge":"c","rpId":"healthlog.local","allowCredentials":[{"id":"cred-xyz","type":"public-key"}]}},"error":null}"#
                                    .utf8
                            )
                        )
                    }
                    // /api/auth/step-up (mint)
                    let data = req.httpBody ?? req.httpBodyStream.map { stream -> Data in
                        stream.open()
                        defer { stream.close() }
                        var acc = Data()
                        let size = 4096
                        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                        defer { buf.deallocate() }
                        while stream.hasBytesAvailable {
                            let r = stream.read(buf, maxLength: size)
                            if r <= 0 { break }
                            acc.append(buf, count: r)
                        }
                        return acc
                    }
                    mintBody = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(
                            #"{"data":{"elevation":"hle_minted","expiresAt":"2030-01-01T00:00:00Z","expiresInSeconds":300,"method":"passkey","satisfiesFreshFactor":true},"error":null}"#
                                .utf8
                        )
                    )
                }

                let elevation = try await service.elevateWithPasskey(anchor: StubAnchor())
                let consumed = try #require(elevation.consume())
                #expect(consumed.token == "hle_minted")
                #expect(consumed.method == .passkey)
                #expect(consumed.satisfiesFreshFactor)
                #expect(mintBody.contains("\"method\":\"passkey\""))
                #expect(mintBody.contains("\"challengeId\":\"challenge-42\""))
                #expect(mintBody.contains("\"signature\":\"signature\""))
            }
        }

    #endif

#endif
