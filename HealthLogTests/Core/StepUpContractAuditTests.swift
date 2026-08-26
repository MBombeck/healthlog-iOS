// CU-22 (#57 / Block C3) — the step-up contract, pinned.
//
// This file is the audit's memory. Every assertion below corresponds to one
// clause of the C3 contract, and each was re-read in the server source
// (the HealthLog server repo, v1.34.3) on 2026-07-31 rather than taken
// from prose. Where a line cites a server file:line, that citation is the reason
// the expectation is what it is — if the server moves, this file is where the
// drift surfaces.
//
// Doctrine: real `APIClient` over `MockURLProtocol` (never a mock server), and
// `.serialized` on every suite that touches the global handler.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // MARK: - Shared fixtures

    enum StepUpAuditFixture {
        static let bearer = "hlk_cu22_token"

        static func makeAPI() throws -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let keychain = InMemoryKeychain()
            try keychain.setString(bearer, forKey: KeychainKey.authToken)
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        static func makeRepo() throws -> AccountSecurityRepository {
            let api = try makeAPI()
            return AccountSecurityRepository(api: api)
        }

        static func response(_ req: URLRequest, _ code: Int, _ json: String) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
            response(req, 200, json)
        }

        /// A realistic elevation secret: the `hle_` prefix plus 64 hex, exactly
        /// the shape `mintStepUpElevation` returns.
        static let elevation = "hle_" + String(repeating: "ab", count: 32)
    }

    // MARK: - Header contract

    /// C3: “`X-Step-Up: hle_…` verbatim, kein Schema-Präfix, neben
    /// `Authorization: Bearer`.”
    @Suite("CU-22 — X-Step-Up header contract", .serialized)
    struct StepUpHeaderContractTests {
        /// Captured per request so one sweep can assert on all nine routes.
        private struct Seen {
            var stepUp: String?
            var authorization: String?
            var method: String
        }

        private func sweep(
            _ work: (AccountSecurityRepository) async throws -> Void
        ) async throws -> [String: Seen] {
            let repo = try StepUpAuditFixture.makeRepo()
            nonisolated(unsafe) var seen: [String: Seen] = [:]
            MockURLProtocol.handler = { req in
                seen[req.url?.path ?? ""] = Seen(
                    stepUp: req.value(forHTTPHeaderField: "X-Step-Up"),
                    authorization: req.value(forHTTPHeaderField: "Authorization"),
                    method: req.httpMethod ?? ""
                )
                // A body every decoded response type tolerates: each call below
                // either ignores the payload (`sendVoid`) or is driven one at a
                // time with its own handler.
                return StepUpAuditFixture.ok(req, #"{"data":{"recoveryCodes":[],"recoveryCodesRemaining":0},"error":null}"#)
            }
            try await work(repo)
            return seen
        }

        @Test("Every elevation-gated route sends the raw hle_ token, with no scheme prefix")
        func rawTokenNoScheme() async throws {
            let token = StepUpAuditFixture.elevation
            let seen = try await sweep { repo in
                _ = try await repo.regenerateRecoveryCodes(elevation: token)
                try await repo.disableTotp(code: "123456", method: .totp, elevation: token)
                try await repo.deleteSecurityKey(id: "k1", elevation: token)
            }
            let gated = [
                "/api/auth/me/mfa/recovery-codes/regenerate",
                "/api/auth/me/mfa/disable",
                "/api/auth/me/mfa/webauthn/k1"
            ]
            for path in gated {
                let entry = try #require(seen[path], "no request captured for \(path)")
                #expect(entry.stepUp == token, "\(path) must carry the elevation verbatim")
                // The three shapes a well-meaning refactor would reach for.
                let value = entry.stepUp ?? ""
                #expect(!value.hasPrefix("Bearer "))
                #expect(!value.hasPrefix("StepUp "))
                #expect(!value.hasPrefix("X-Step-Up"))
                #expect(
                    entry.authorization == "Bearer \(StepUpAuditFixture.bearer)",
                    "\(path) must present the elevation ALONGSIDE the bearer token, not instead of it"
                )
            }
        }

        @Test("TOTP setup, confirm and rename ride the same header on their own verbs")
        func remainingGatedRoutes() async throws {
            let token = StepUpAuditFixture.elevation
            let repo = try StepUpAuditFixture.makeRepo()

            nonisolated(unsafe) var setup: (String?, String)?
            MockURLProtocol.handler = { req in
                // CU-07: the handler is process-global — record only OUR route so
                // a parallel suite's request cannot overwrite the capture.
                if req.targets("/api/auth/me/mfa/totp/setup") {
                    setup = (req.value(forHTTPHeaderField: "X-Step-Up"), req.httpMethod ?? "")
                }
                return StepUpAuditFixture.ok(req, #"{"data":{"otpauthUri":"otpauth://totp/x","totpSecret":"S"},"error":null}"#)
            }
            _ = try await repo.totpSetup(elevation: token)
            #expect(setup?.0 == token)
            #expect(setup?.1 == "POST")

            nonisolated(unsafe) var confirm: String?
            MockURLProtocol.handler = { req in
                if req.targets("/api/auth/me/mfa/totp/confirm") {
                    confirm = req.value(forHTTPHeaderField: "X-Step-Up")
                }
                return StepUpAuditFixture.ok(
                    req,
                    #"{"data":{"enabled":true,"recoveryCodes":["a"],"recoveryCodesRemaining":1},"error":null}"#
                )
            }
            _ = try await repo.totpConfirm(code: "123456", elevation: token)
            #expect(confirm == token)

            nonisolated(unsafe) var rename: (String?, String)?
            MockURLProtocol.handler = { req in
                if req.targets("/api/auth/me/mfa/webauthn/k1") {
                    rename = (req.value(forHTTPHeaderField: "X-Step-Up"), req.httpMethod ?? "")
                }
                return StepUpAuditFixture.ok(req, #"{"data":{},"error":null}"#)
            }
            try await repo.renameSecurityKey(id: "k1", name: "Yubikey", elevation: token)
            #expect(rename?.0 == token)
            #expect(rename?.1 == "PATCH")
        }

        @Test("The mint and options routes never present an elevation themselves")
        func mintRoutesCarryNoElevation() async throws {
            let repo = try StepUpAuditFixture.makeRepo()
            nonisolated(unsafe) var seen: [String: (String?, String?)] = [:]
            MockURLProtocol.handler = { req in
                seen[req.url?.path ?? ""] = (
                    req.value(forHTTPHeaderField: "X-Step-Up"),
                    req.value(forHTTPHeaderField: "Authorization")
                )
                if req.url?.path == "/api/auth/step-up/options" {
                    return StepUpAuditFixture.ok(
                        req,
                        #"{"data":{"challengeId":"c","options":{"challenge":"x","rpId":"r","allowCredentials":[]}},"error":null}"#
                    )
                }
                return StepUpAuditFixture.ok(
                    req,
                    #"{"data":{"elevation":"hle_x","expiresAt":"2030-01-01T00:00:00Z","expiresInSeconds":300,"method":"password","satisfiesFreshFactor":false},"error":null}"#
                )
            }
            _ = try await repo.stepUpOptions(.passkey)
            _ = try await repo.stepUpMint(.password("pw"))

            for path in ["/api/auth/step-up/options", "/api/auth/step-up"] {
                let entry = try #require(seen[path])
                #expect(entry.0 == nil, "\(path) mints an elevation, it does not present one")
                // Bearer-only by construction on the server (`requireBearerAuth`);
                // the client must therefore always have a token on these.
                #expect(entry.1 == "Bearer \(StepUpAuditFixture.bearer)")
            }
        }
    }

    // MARK: - The mint contract

    /// C3: TTL 300 s, single-use, token-bound, overwritten by a re-mint;
    /// `satisfiesFreshFactor` false for `password`; recovery codes not accepted.
    @Suite("CU-22 — mint contract")
    struct StepUpMintContractTests {
        @Test("The TTL the server publishes is 300 seconds", arguments: StepUpMethod.allCases)
        func ttlIsFiveMinutes(_ method: StepUpMethod) throws {
            let fresh = method.satisfiesFreshFactor
            let json = """
            {"elevation":"hle_abc","expiresAt":"2030-01-01T00:05:00Z","expiresInSeconds":300,
             "method":"\(method.rawValue)","satisfiesFreshFactor":\(fresh)}
            """
            let mint = try JSONDecoder.hlDefault.decode(StepUpMintResponse.self, from: Data(json.utf8))
            #expect(mint.expiresInSeconds == 300, "STEP_UP_ELEVATION_TTL_SECONDS is 300 — a client-side default must not diverge")
            #expect(mint.method == method.rawValue)
            #expect(mint.satisfiesFreshFactor == fresh)
        }

        @Test("Only password fails the fresh-factor test")
        func passwordIsNotAFreshFactor() {
            #expect(StepUpMethod.password.satisfiesFreshFactor == false)
            #expect(StepUpMethod.allCases.filter(\.satisfiesFreshFactor).count == 3)
        }

        @Test("The mint union has exactly the four server arms — no recovery arm")
        func unionArms() {
            #expect(StepUpMethod.allCases == [.password, .totp, .webauthn, .passkey])
            // C3: “Recovery-Codes werden nicht akzeptiert.” The server's
            // `stepUpMintSchema` has no such variant, so neither may the client:
            // there must be no way to *express* a recovery proof at the mint.
            #expect(!StepUpMethod.allCases.contains { $0.rawValue.contains("recovery") })
        }

        @Test("A recovery code is disable-body material only, never a mint proof")
        func recoveryIsDisableBodyOnly() throws {
            // A recovery code IS legitimate on `…/mfa/disable`, where it proves
            // live possession on top of a fresh-factor elevation …
            let data = try JSONEncoder.hlDefault.encode(MfaDisableRequestBody(code: "abcd-efgh", method: .recovery))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["method"] as? String == "recovery")
            // … but it can never become a step-up proof: the mint union has no
            // arm that would carry one, so the refusal is structural rather than
            // a check somebody could delete.
            #expect(StepUpMethod(rawValue: "recovery") == nil)
            #expect(StepUpCeremony(rawValue: "recovery") == nil)
        }

        @Test("The options body carries the ceremony and nothing else", arguments: [
            (StepUpCeremony.passkey, "passkey"), (StepUpCeremony.webauthn, "webauthn")
        ])
        func optionsBodyIsMethodOnly(_ testCase: (ceremony: StepUpCeremony, wire: String)) throws {
            let data = try JSONEncoder.hlDefault.encode(StepUpOptionsRequestBody(ceremony: testCase.ceremony))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json.count == 1, "stepUpOptionsSchema accepts { method } and nothing else")
            #expect(json["method"] as? String == testCase.wire)
        }

        @Test("Each mint arm encodes its own fields and no foreign ones")
        func mintArmsAreDisjoint() throws {
            func keys(_ body: StepUpMintBody) throws -> Set<String> {
                let data = try JSONEncoder.hlDefault.encode(body)
                let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                return Set(json.keys)
            }
            let credential = WebAuthnAssertionCredential(
                id: "c", rawId: "c",
                response: .init(clientDataJSON: "j", authenticatorData: "a", signature: "s", userHandle: nil)
            )
            let passwordKeys = try keys(.password("pw"))
            let totpKeys = try keys(.totp("123456"))
            let webauthnKeys = try keys(.webauthn(challengeId: "x", credential: credential))
            let passkeyKeys = try keys(.passkey(challengeId: "x", credential: credential))
            #expect(passwordKeys == ["method", "password"])
            #expect(totpKeys == ["method", "code"])
            #expect(webauthnKeys == ["method", "challengeId", "credential"])
            #expect(passkeyKeys == ["method", "challengeId", "credential"])
        }
    }

    // MARK: - Fresh-factor route map

    /// C3's starred operations. Verified against the server source rather than
    /// the brief's prose — see ``MfaManagementOperation`` for the citations.
    @Suite("CU-22 — fresh-factor route map")
    struct FreshFactorRouteMapTests {
        @Test("Exactly three reachable operations demand a fresh second factor")
        func threeFreshRoutes() {
            let fresh = Set(MfaManagementOperation.allCases.filter(\.requiresFreshFactor))
            #expect(fresh == [.totpDisable, .recoveryRegenerate, .securityKeyRemove])
        }

        @Test("Rename is NOT a fresh-factor route")
        func renameIsNotFresh() {
            // `src/app/api/auth/me/mfa/webauthn/[id]/route.ts:31` calls
            // `requireMfaManagementAuth()` with no options, in contrast to the
            // DELETE half at `:73`. Unchanged between v1.34.2 and v1.34.3.
            #expect(MfaManagementOperation.securityKeyRename.requiresFreshFactor == false)
            #expect(MfaManagementOperation.securityKeyRemove.requiresFreshFactor)
        }

        @Test("Enrolment routes accept a password elevation")
        func enrolmentIsNonFresh() {
            #expect(MfaManagementOperation.totpSetup.requiresFreshFactor == false)
            #expect(MfaManagementOperation.totpConfirm.requiresFreshFactor == false)
        }

        @Test("A fresh-factor operation never offers the password arm", arguments: MfaManagementOperation.allCases)
        func passwordArmGating(_ operation: MfaManagementOperation) {
            let accepted = operation.acceptedMethods
            #expect(accepted.contains(.password) == !operation.requiresFreshFactor)
            #expect(accepted.contains(.totp))
            #expect(accepted.contains(.passkey))
        }
    }

    // MARK: - Uniform rejection handling

    /// C3: “Die Ablehnung ist absichtlich uniform — bei `auth.stepup.required`
    /// die gecachte Elevation wegwerfen und neu minten, nicht diagnostizieren.”
    @Suite("CU-22 — step-up rejection classification")
    struct StepUpRejectionTests {
        private func serverError(_ status: Int, _ code: String?, _ message: String = "x") -> HLError {
            .server(status: status, code: code, message: message)
        }

        @Test("required and mfa_not_enrolled both read as a step-up rejection")
        func prefixMatching() {
            #expect(SecurityStepUp.isRequired(serverError(401, "auth.stepup.required")))
            #expect(SecurityStepUp.isRequired(serverError(401, "auth.stepup.mfa_not_enrolled")))
            #expect(SecurityStepUp.isRequired(serverError(401, "auth.stepup.future_sibling")))
        }

        @Test("Only mfa_not_enrolled reads as an enrolment problem")
        func notEnrolledIsNarrow() {
            #expect(SecurityStepUp.isMfaNotEnrolled(serverError(401, "auth.stepup.mfa_not_enrolled")))
            #expect(!SecurityStepUp.isMfaNotEnrolled(serverError(401, "auth.stepup.required")))
            #expect(!SecurityStepUp.isMfaNotEnrolled(serverError(403, "auth.stepup.mfa_not_enrolled")))
        }

        @Test("A code-less 401 is an ordinary auth failure, not a step-up rejection")
        func bareUnauthorizedIsNotStepUp() {
            #expect(!SecurityStepUp.isRequired(serverError(401, nil, "Verification failed")))
            #expect(!SecurityStepUp.isRequired(serverError(401, nil, "Invalid code")))
        }

        @Test("Only a gate rejection spends the elevation")
        func consumptionClassifier() {
            #expect(SecurityStepUp.consumesElevation(serverError(401, "auth.stepup.required")))
            #expect(SecurityStepUp.consumesElevation(serverError(401, "auth.stepup.mfa_not_enrolled")))
            // Every one of these is refused BEFORE `commitElevation()`:
            #expect(!SecurityStepUp.consumesElevation(HLError.rateLimited(retryAfter: nil)))
            #expect(!SecurityStepUp.consumesElevation(serverError(429, nil, "Too many requests")))
            #expect(!SecurityStepUp.consumesElevation(serverError(422, nil, "Invalid request")))
            #expect(!SecurityStepUp.consumesElevation(serverError(409, nil, "A second factor is already active")))
            #expect(!SecurityStepUp.consumesElevation(serverError(404, nil, "Security key not found")))
            #expect(!SecurityStepUp.consumesElevation(serverError(401, nil, "Invalid code")))
            #expect(!SecurityStepUp.consumesElevation(HLError.offline))
        }
    }

    // MARK: - Single-use + the rate-limit-aware hand-back

    @Suite("CU-22 — elevation lifecycle")
    struct ElevationLifecycleTests {
        private func makeElevation(_ token: String = "hle_one") -> ConsumableElevation {
            ConsumableElevation(StepUpElevation(token: token, method: .totp, satisfiesFreshFactor: true))
        }

        @Test("Consume yields once and never again")
        func singleUse() {
            let elevation = makeElevation()
            #expect(elevation.consume()?.token == "hle_one")
            #expect(elevation.consume() == nil)
            #expect(elevation.isSpent)
        }

        @Test("A restored elevation is usable exactly once more")
        func restoreRearms() throws {
            let elevation = makeElevation()
            let proof = try #require(elevation.consume())
            #expect(elevation.isSpent)
            elevation.restore(proof)
            #expect(elevation.isSpent == false)
            #expect(elevation.consume()?.token == "hle_one")
            #expect(elevation.consume() == nil, "restore re-arms once, it does not make the proof reusable")
        }

        @Test("Restore never overwrites a live elevation")
        func restoreDoesNotClobber() {
            let elevation = makeElevation("hle_live")
            elevation.restore(StepUpElevation(token: "hle_stale", method: .password, satisfiesFreshFactor: false))
            #expect(elevation.consume()?.token == "hle_live")
        }

        @Test("satisfiesFreshFactor peeks without spending")
        func peekIsNonConsuming() {
            let elevation = makeElevation()
            #expect(elevation.satisfiesFreshFactor)
            #expect(elevation.isSpent == false)
            #expect(elevation.consume() != nil)
            #expect(elevation.satisfiesFreshFactor == false, "a spent elevation proves nothing")
        }
    }

    // MARK: - Store behaviour against the real transport

    /// The clauses that only show up end-to-end: which failures cost the user a
    /// re-mint, and which error gets which sentence.
    @Suite("CU-22 — management-action outcomes", .serialized)
    @MainActor
    struct StepUpActionOutcomeTests {
        private func makeStore() throws -> AccountSecurityStore {
            let repo = try StepUpAuditFixture.makeRepo()
            return AccountSecurityStore(repo: repo)
        }

        private func freshElevation() -> ConsumableElevation {
            ConsumableElevation(
                StepUpElevation(token: StepUpAuditFixture.elevation, method: .totp, satisfiesFreshFactor: true)
            )
        }

        @Test("A wrong disable code keeps the elevation alive")
        func wrongCodeKeepsElevation() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            MockURLProtocol.handler = { req in
                // `…/mfa/disable/route.ts:82` — 401 "Invalid code", NO errorCode,
                // thrown before `commitElevation()` at `:87`.
                StepUpAuditFixture.response(req, 401, #"{"data":null,"error":"Invalid code","meta":{}}"#)
            }
            await store.disableTotp(code: "000000", method: .totp, elevation: elevation)
            #expect(store.actionError != nil)
            #expect(
                elevation.isSpent == false,
                "the server did not spend this proof — dropping it would burn one of five mints per 15 min"
            )
        }

        @Test("A 429 keeps the elevation alive")
        func rateLimitKeepsElevation() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            MockURLProtocol.handler = { req in
                StepUpAuditFixture.response(req, 429, #"{"data":null,"error":"Too many requests","meta":{}}"#)
            }
            await store.regenerateRecoveryCodes(elevation: elevation)
            #expect(elevation.isSpent == false)
        }

        @Test("A 422 keeps the elevation alive")
        func unprocessableKeepsElevation() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            MockURLProtocol.handler = { req in
                StepUpAuditFixture.response(req, 422, #"{"data":null,"error":"Invalid request","meta":{}}"#)
            }
            await store.renameSecurityKey(id: "k1", name: "Key", elevation: elevation)
            #expect(elevation.isSpent == false)
        }

        @Test("A gate rejection spends the elevation and asks for a fresh one")
        func stepUpRequiredSpendsAndReverifies() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            MockURLProtocol.handler = { req in
                StepUpAuditFixture.response(
                    req, 401,
                    #"{"data":null,"error":"Recent second-factor verification required","meta":{"errorCode":"auth.stepup.required"}}"#
                )
            }
            await store.deleteSecurityKey(id: "k1", elevation: elevation)
            #expect(elevation.isSpent, "a refused elevation is unusable — re-mint, do not retry")
            #expect(
                store.actionError == String(localized: "settings.security.twoFactor.error.reverify"),
                "the refusal is deliberately uniform; the client must not try to diagnose it"
            )
        }

        @Test("mfa_not_enrolled gets the enrolment hint, not the re-verify prompt")
        func notEnrolledGetsItsOwnMessage() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            MockURLProtocol.handler = { req in
                StepUpAuditFixture.response(
                    req, 401,
                    #"{"data":null,"error":"Recent second-factor verification required","meta":{"errorCode":"auth.stepup.mfa_not_enrolled"}}"#
                )
            }
            await store.regenerateRecoveryCodes(elevation: elevation)
            let expected = String(localized: "settings.security.twoFactor.error.notEnrolled")
            #expect(store.actionError == expected)
            #expect(store.actionError != String(localized: "settings.security.twoFactor.error.reverify"))
        }

        @Test("An already-spent elevation is refused before it reaches the wire")
        func spentElevationNeverHitsTheNetwork() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            _ = elevation.consume()
            nonisolated(unsafe) var hits = 0
            MockURLProtocol.handler = { req in
                // CU-07: `hits == 0` only means something when a parallel suite's
                // request cannot raise it — scope to the route this action uses.
                if req.targets("/api/auth/me/mfa/webauthn/k1") { hits += 1 }
                return StepUpAuditFixture.ok(req, #"{"data":{},"error":null}"#)
            }
            await store.deleteSecurityKey(id: "k1", elevation: elevation)
            #expect(hits == 0)
            #expect(store.actionError == String(localized: "settings.security.twoFactor.error.reverify"))
        }

        @Test("A successful action spends the elevation")
        func successSpends() async throws {
            let store = try makeStore()
            let elevation = freshElevation()
            MockURLProtocol.handler = { req in
                StepUpAuditFixture.ok(req, #"{"data":{"recoveryCodes":["a-b"],"recoveryCodesRemaining":1},"error":null}"#)
            }
            await store.regenerateRecoveryCodes(elevation: elevation)
            #expect(store.actionError == nil)
            #expect(elevation.isSpent)
            #expect(store.consumeRevealedRecoveryCodes() == ["a-b"])
        }

        @Test("The TOTP arm is only offered when the account actually has one")
        func totpArmTracksStatus() async throws {
            let store = try makeStore()
            #expect(store.isTotpEnabled == false, "idle must not claim a factor exists")
            MockURLProtocol.handler = { req in
                if req.url?.path == "/api/version" {
                    return StepUpAuditFixture.ok(req, #"{"data":{"version":"1.34.3"},"error":null}"#)
                }
                return StepUpAuditFixture.ok(
                    req,
                    #"{"data":{"totp":{"enabled":true},"recoveryCodesRemaining":5,"webauthn":[],"passkeyNudgeDismissed":false},"error":null}"#
                )
            }
            await store.loadTwoFactor()
            #expect(store.isTotpEnabled)
        }
    }

    // MARK: - Elevations are never cached

    /// C3: an elevation is “an genau das mintende Token gebunden” and “wird von
    /// einem Re-Mint überschrieben”. The client half of that is simply: never
    /// hold one. Each mint is its own object; nothing memoises.
    @Suite("CU-22 — no client-side elevation cache", .serialized)
    struct ElevationCachingTests {
        @Test("Two mints yield two independent single-use elevations")
        func remintIsIndependent() async throws {
            let repo = try StepUpAuditFixture.makeRepo()
            nonisolated(unsafe) var counter = 0
            MockURLProtocol.handler = { req in
                // CU-07: only the mint route advances the counter.
                if req.targets("/api/auth/step-up") { counter += 1 }
                return StepUpAuditFixture.ok(
                    req,
                    """
                    {"data":{"elevation":"hle_mint\(counter)","expiresAt":"2030-01-01T00:00:00Z",
                     "expiresInSeconds":300,"method":"totp","satisfiesFreshFactor":true},"error":null}
                    """
                )
            }
            let first = try await repo.stepUpMint(.totp("111111"))
            let second = try await repo.stepUpMint(.totp("222222"))
            #expect(first.elevation != second.elevation)
            #expect(counter == 2, "a cached elevation would have skipped the second round-trip")
        }
    }

#endif
