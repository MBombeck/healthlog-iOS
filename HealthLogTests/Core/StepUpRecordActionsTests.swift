// R2 / #115 A3 + A4 — the proof family is "ask for proof and retry", never a
// dead session, and the record actions carry the elevation when asked.
//
// Server contract, read at tag v1.39.6 (`git show`, not invented):
// - `src/lib/api-handler.ts` — `StepUpRequiredError` serialises as
//   `401 { data: null, error, meta: { errorCode: "auth.stepup.required" } }`;
//   the cookie arm answers `auth.reproof.required` (+ `meta.methods`).
//   `requireRecentProof({ bearer })`: `"token"` on `POST /api/share-links` and
//   `POST /api/mcp/tokens` (header not read yet), `"elevation-if-enrolled"` on
//   `POST /api/export/encrypted`, `"elevation"` on `GET /api/export?type=all`
//   and `GET /api/export/full-backup`.
// - `src/app/api/export/route.ts` — `GET` only; query `format`, `type`.
//
// Drives the REAL `APIClient` over `MockURLProtocol`.

// swiftlint:disable force_unwrapping file_length type_body_length

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Step-up on record actions (R2 / A3 + A4)", .serialized, .mockURLSession)
    struct StepUpRecordActionsTests {
        // MARK: - Harness

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() {
                lock.lock()
                defer { lock.unlock() }
                value += 1
            }

            var total: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        /// Every request the stub saw: method, path, query, `X-Step-Up`, `Accept`.
        private final class Wire: @unchecked Sendable {
            struct Seen: Equatable {
                let method: String
                let path: String
                let query: String?
                let stepUp: String?
                let accept: String?
                let hasBody: Bool
            }

            private let lock = NSLock()
            private var seen: [Seen] = []
            func record(_ req: URLRequest) {
                lock.lock()
                defer { lock.unlock() }
                seen.append(Seen(
                    method: req.httpMethod ?? "",
                    path: req.url?.path ?? "",
                    query: req.url?.query,
                    stepUp: req.value(forHTTPHeaderField: "X-Step-Up"),
                    accept: req.value(forHTTPHeaderField: "Accept"),
                    hasBody: req.httpBody != nil || req.httpBodyStream != nil
                ))
            }

            var requests: [Seen] {
                lock.lock()
                defer { lock.unlock() }
                return seen
            }
        }

        private static let stepUpRequired =
            #"{"data":null,"error":"Step-up authentication required","meta":{"errorCode":"auth.stepup.required"}}"#
        private static let elevation = "hle_0123456789abcdef0123456789abcdef"

        private static func response(_ req: URLRequest, _ status: Int, _ json: String) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        private func makeAPI(
            refreshes: Counter = Counter(),
            signOuts: Counter = Counter()
        ) throws -> APIClient {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_valid_bearer", forKey: KeychainKey.authToken)
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: env,
                keychain: keychain,
                sessionConfiguration: .mock(),
                onUnauthorized: { signOuts.bump() },
                refreshHandler: {
                    refreshes.bump()
                    return .refreshed
                }
            )
        }

        private static func shareBody() -> CreateShareLinkBody {
            CreateShareLinkBody(
                label: "Dr. Schmidt",
                rangeStart: "2026-03-01T00:00:00Z",
                rangeEnd: nil,
                expiresAt: "2026-07-01T00:00:00Z",
                selection: ReportSelection(leaves: ["WEIGHT"])
            )
        }

        private static let shareCreated = """
        {"data":{"id":"sl_1","label":"Dr. Schmidt","rangeStart":"2026-03-01T00:00:00Z",\
        "rangeEnd":null,"resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-07-01T00:00:00Z",\
        "createdAt":"2026-06-05T00:00:00Z","revokedAt":null,"lastAccessAt":null,"accessCount":0,\
        "active":true,"token":"hls_0123456789abcdef0123456789abcdef0123456789abcdef"},"error":null}
        """

        // MARK: - Transport: a proof refusal is not a dead session

        struct RefusalCase: CustomTestStringConvertible, Sendable {
            let method: String
            let path: String
            let code: String
            var testDescription: String {
                "\(method) \(path) → \(code)"
            }
        }

        @Test("a proof-family 401 surfaces typed and never refreshes or signs out", arguments: [
            RefusalCase(method: "POST", path: "/api/share-links", code: "auth.stepup.required"),
            RefusalCase(method: "POST", path: "/api/mcp/tokens", code: "auth.stepup.required"),
            RefusalCase(method: "POST", path: "/api/export/encrypted", code: "auth.stepup.required"),
            RefusalCase(method: "GET", path: "/api/export", code: "auth.stepup.required"),
            RefusalCase(method: "POST", path: "/api/share-links", code: "auth.reproof.required"),
            RefusalCase(method: "POST", path: "/api/mcp/tokens", code: "auth.reproof.failed"),
            // Any path: the rule is the code, not an allowlist.
            RefusalCase(method: "POST", path: "/api/account/grants", code: "auth.stepup.required")
        ])
        func proofRefusalIsNotADeadSession(_ testCase: RefusalCase) async throws {
            let refreshes = Counter()
            let signOuts = Counter()
            let api = try makeAPI(refreshes: refreshes, signOuts: signOuts)
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                return Self.response(
                    req, 401,
                    #"{"data":null,"error":"Confirm it is you to continue","meta":{"errorCode":"\#(testCase.code)","methods":["password","passkey"]}}"#
                )
            }

            let request = try APIRequest<EmptyPayload>(
                method: #require(HTTPMethod(rawValue: testCase.method)),
                path: testCase.path,
                maxRetries: 0
            )
            await #expect(throws: HLError.server(status: 401, code: testCase.code, message: "Confirm it is you to continue")) {
                try await api.sendVoid(request)
            }
            #expect(refreshes.total == 0, "a proof refusal must not spend a refresh")
            #expect(signOuts.total == 0, "a proof refusal must never sign the person out")
            #expect(wire.requests.count == 1)
        }

        @Test("a code-less 401 on the same route still refreshes and retries (expired token)")
        func expiredTokenStillRefreshes() async throws {
            let refreshes = Counter()
            let signOuts = Counter()
            let api = try makeAPI(refreshes: refreshes, signOuts: signOuts)
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                if wire.requests.count == 1 {
                    return Self.response(req, 401, #"{"data":null,"error":"Not authenticated"}"#)
                }
                return Self.response(req, 201, Self.shareCreated)
            }

            let link = try await ShareLinkRepository(api: api).create(Self.shareBody())

            #expect(link.id == "sl_1")
            #expect(refreshes.total == 1)
            #expect(signOuts.total == 0)
            #expect(wire.requests.count == 2)
        }

        // MARK: - Share link: ask for proof, retry with X-Step-Up

        @MainActor
        @Test("share link: 401 auth.stepup.required → proof asked → retry carries X-Step-Up once")
        func shareLinkAsksForProofAndRetries() async throws {
            let api = try makeAPI()
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                if req.url?.path == "/api/share-links", req.httpMethod == "POST" {
                    return req.value(forHTTPHeaderField: "X-Step-Up") == Self.elevation
                        ? Self.response(req, 201, Self.shareCreated)
                        : Self.response(req, 401, Self.stepUpRequired)
                }
                return Self.response(req, 200, #"{"data":{"shareLinks":[]},"error":null}"#)
            }
            let store = ShareLinkStore(
                repo: ShareLinkRepository(api: api),
                capabilities: ServerCapabilitiesRepository(api: api)
            )

            #expect(await store.create(Self.shareBody()) == false)
            #expect(store.stepUp.isRequested)
            #expect(store.error == StepUpRetry.requiredMessage)

            store.stepUp.supply(Self.elevation)
            #expect(store.stepUp.isRequested == false)
            #expect(await store.create(Self.shareBody()))
            #expect(store.freshToken?.hasPrefix("hls_") == true)

            let posts = wire.requests.filter { $0.method == "POST" }
            #expect(posts.map(\.stepUp) == [nil, Self.elevation])
            // Single use: a later create does not reuse the elevation.
            #expect(store.stepUp.take() == nil)
        }

        @MainActor
        @Test("share link: cancelling the proof leaves the sentence and no elevation")
        func shareLinkCancelledProof() async throws {
            let api = try makeAPI()
            MockURLProtocol.install { req in Self.response(req, 401, Self.stepUpRequired) }
            let store = ShareLinkStore(
                repo: ShareLinkRepository(api: api),
                capabilities: ServerCapabilitiesRepository(api: api)
            )
            #expect(await store.create(Self.shareBody()) == false)
            store.stepUp.cancel()
            #expect(store.stepUp.isRequested == false)
            #expect(store.stepUp.take() == nil)
            #expect(store.error == StepUpRetry.requiredMessage)
        }

        // MARK: - MCP connector token

        @MainActor
        @Test("connector token: 401 auth.stepup.required → proof → retry carries X-Step-Up")
        func mcpTokenAsksForProofAndRetries() async throws {
            let api = try makeAPI()
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                if req.httpMethod == "POST" {
                    return req.value(forHTTPHeaderField: "X-Step-Up") == Self.elevation
                        ? Self.response(req, 201, #"{"data":{"token":"hlk_new_secret","name":"Claude"},"error":null}"#)
                        : Self.response(req, 401, Self.stepUpRequired)
                }
                return Self.response(req, 200, #"{"data":[],"error":null}"#)
            }
            let store = McpStore(repo: McpRepository(api: api))

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(store.stepUp.isRequested)
            store.stepUp.supply(Self.elevation)
            #expect(await store.mintToken(name: "Claude", scope: .read))
            #expect(store.freshToken?.token == "hlk_new_secret")
            #expect(wire.requests.filter { $0.method == "POST" }.map(\.stepUp) == [nil, Self.elevation])
        }

        // MARK: - A4: full backup is a GET with the elevation

        @Test("full backup is GET /api/export?format=…&type=all — not the POST that answered 405")
        func fullBackupIsAGet() async throws {
            let api = try makeAPI()
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                // The route exports GET only; a POST is what Next answers 405 to.
                guard req.httpMethod == "GET" else {
                    return Self.response(req, 405, "")
                }
                guard req.value(forHTTPHeaderField: "X-Step-Up") == Self.elevation else {
                    return Self.response(req, 401, Self.stepUpRequired)
                }
                return Self.response(req, 200, #"{"data":{"measurements":[],"medications":[]}}"#)
            }
            let service = ExportService(api: api)

            // Without proof: the step-up refusal arrives typed, not as `.unauthorized`.
            await #expect(throws: HLError.server(
                status: 401,
                code: "auth.stepup.required",
                message: "Step-up authentication required"
            )) {
                _ = try await service.downloadFullBackup(.json)
            }
            // With proof: the file.
            let export = try await service.downloadFullBackup(.json, elevation: Self.elevation)
            #expect(export.fileExtension == "json")
            #expect(!export.data.isEmpty)

            let first = try #require(wire.requests.first)
            #expect(first.method == "GET")
            #expect(first.path == "/api/export")
            #expect(first.query?.contains("type=all") == true)
            #expect(first.query?.contains("format=json") == true)
            #expect(first.accept == "application/json")
            #expect(first.hasBody == false)
            #expect(wire.requests.map(\.stepUp) == [nil, Self.elevation])
        }

        @Test("full backup CSV asks for format=csv with a text/csv Accept")
        func fullBackupCSV() async throws {
            let api = try makeAPI()
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                return Self.response(req, 200, "# Medications\nname\n")
            }
            _ = try await ExportService(api: api).downloadFullBackup(.csv, elevation: Self.elevation)
            let seen = try #require(wire.requests.first)
            #expect(seen.query?.contains("format=csv") == true)
            #expect(seen.accept == "text/csv")
        }

        @Test("an elevation-carrying request is never re-sent by the transport")
        func elevationRequestIsNotRetried() async throws {
            let api = try makeAPI()
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                return Self.response(req, 503, #"{"data":null,"error":"down"}"#)
            }
            await #expect(throws: HLError.self) {
                _ = try await ExportService(api: api).downloadFullBackup(.json, elevation: Self.elevation)
            }
            #expect(wire.requests.count == 1)
        }

        // MARK: - Encrypted export

        @Test("encrypted export: second-factor account gets 401 typed, retry carries X-Step-Up")
        func encryptedExportCarriesElevation() async throws {
            let api = try makeAPI()
            let wire = Wire()
            MockURLProtocol.install { req in
                wire.record(req)
                guard req.value(forHTTPHeaderField: "X-Step-Up") == Self.elevation else {
                    return Self.response(req, 401, Self.stepUpRequired)
                }
                return (
                    HTTPURLResponse(
                        url: req.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/octet-stream"]
                    )!,
                    Data("HLX1....".utf8)
                )
            }
            let service = ExportService(api: api)
            do {
                _ = try await service.downloadEncryptedBackup(passphrase: "correct horse battery")
                Issue.record("expected the step-up refusal")
            } catch let error as HLError {
                #expect(SecurityStepUp.asksForProof(error))
                #expect(error != .unauthorized)
            }
            let archive = try await service.downloadEncryptedBackup(
                passphrase: "correct horse battery",
                elevation: Self.elevation
            )
            #expect(archive.data == Data("HLX1....".utf8))
            #expect(wire.requests.map(\.stepUp) == [nil, Self.elevation])
            #expect(wire.requests.allSatisfy { $0.method == "POST" && $0.path == "/api/export/encrypted" })
        }
    }

    // MARK: - Pure pieces

    @Suite("Proof family + step-up strength (R2 / A3)")
    struct ProofFamilyTests {
        @Test("the proof family asks for proof; mfa_not_enrolled and other codes do not", arguments: [
            ("auth.stepup.required", 401, true),
            ("auth.reproof.required", 401, true),
            ("auth.reproof.failed", 401, true),
            ("auth.reproof.too_weak", 422, true),
            ("auth.stepup.mfa_not_enrolled", 401, false),
            ("auth.refresh.invalid", 401, false),
            ("share-link.selection.invalid", 422, false)
        ])
        func asksForProof(_ code: String, _ status: Int, _ expected: Bool) {
            #expect(SecurityStepUp.asksForProof(HLError.server(status: status, code: code, message: "x")) == expected)
        }

        @Test("bare .unauthorized is a session matter, not a proof request")
        func unauthorizedIsNotProof() {
            #expect(SecurityStepUp.asksForProof(HLError.unauthorized) == false)
        }

        @Test("body classifier reads meta.errorCode and the pre-v1.39 top-level code")
        func bodyClassifier() {
            #expect(SecurityStepUp.isProofRefusal(body: Data(#"{"meta":{"errorCode":"auth.stepup.required"}}"#.utf8)))
            #expect(SecurityStepUp.isProofRefusal(body: Data(#"{"errorCode":"auth.reproof.required"}"#.utf8)))
            #expect(SecurityStepUp.isProofRefusal(body: Data(#"{"meta":{"errorCode":"auth.refresh.invalid"}}"#.utf8)) == false)
            #expect(SecurityStepUp.isProofRefusal(body: Data(#"{"error":"Not authenticated"}"#.utf8)) == false)
            #expect(SecurityStepUp.isProofRefusal(body: Data()) == false)
            #expect(SecurityStepUp.isProofRefusal(body: Data("<html>".utf8)) == false)
        }

        @Test("TOTP setup wants a second factor or passkey only on an account that has one (v1.39.3)")
        func totpSetupStrengthFollowsAccount() {
            #expect(MfaManagementOperation.totpSetup.requiresFreshFactor(accountHasSecondFactor: false) == false)
            #expect(MfaManagementOperation.totpSetup.requiresFreshFactor(accountHasSecondFactor: true))
            // Unchanged elsewhere.
            #expect(MfaManagementOperation.totpConfirm.requiresFreshFactor(accountHasSecondFactor: true) == false)
            #expect(MfaManagementOperation.securityKeyRename.requiresFreshFactor(accountHasSecondFactor: true) == false)
            for op in MfaManagementOperation.allCases where op.requiresFreshFactor {
                #expect(op.requiresFreshFactor(accountHasSecondFactor: false))
            }
        }

        @MainActor
        @Test("StepUpRetry hands an elevation out once and drops it on a new refusal")
        func retryStateIsSingleUse() {
            let retry = StepUpRetry()
            #expect(retry.requestIfProofRefusal(HLError.offline) == false)
            #expect(retry.requestIfProofRefusal(HLError.server(status: 401, code: "auth.stepup.required", message: "")))
            retry.supply("hle_a")
            #expect(retry.isRequested == false)
            #expect(retry.take() == "hle_a")
            #expect(retry.take() == nil)
            retry.supply("hle_b")
            #expect(retry.requestIfProofRefusal(HLError.server(status: 401, code: "auth.reproof.required", message: "")))
            #expect(retry.take() == nil)
        }
    }

    @Suite("Second factor on the account drives the picker (R2 / A3)", .serialized, .mockURLSession)
    struct AccountSecondFactorTests {
        @MainActor
        private func loadedStore(mfa: String) async -> AccountSecurityStore {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            MockURLProtocol.install { req in
                let json = req.url?.path == "/api/version"
                    ? #"{"data":{"version":"1.39.6"},"error":null}"#
                    : #"{"data":\#(mfa),"error":null}"#
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            let store = AccountSecurityStore(repo: AccountSecurityRepository(api: api))
            await store.loadTwoFactor()
            return store
        }

        @MainActor
        @Test("a security-key-only account has a second factor (no authenticator)")
        func securityKeyOnly() async {
            let store = await loadedStore(
                mfa: #"{"totp":{"enabled":false},"recoveryCodesRemaining":8,"webauthn":[{"id":"k1","name":"YubiKey"}],"passkeyNudgeDismissed":false}"#
            )
            #expect(store.hasSecondFactor)
            #expect(store.isTotpEnabled == false)
            #expect(MfaManagementOperation.totpSetup.requiresFreshFactor(accountHasSecondFactor: store.hasSecondFactor))
        }

        @MainActor
        @Test("an account without any second factor may confirm with its password")
        func noSecondFactor() async {
            let store = await loadedStore(
                mfa: #"{"totp":{"enabled":false},"recoveryCodesRemaining":0,"webauthn":[],"passkeyNudgeDismissed":false}"#
            )
            #expect(store.hasSecondFactor == false)
            #expect(MfaManagementOperation.totpSetup.requiresFreshFactor(accountHasSecondFactor: store.hasSecondFactor) == false)
        }

        @MainActor
        @Test("an authenticator counts as a second factor")
        func totpEnabled() async {
            let store = await loadedStore(
                mfa: #"{"totp":{"enabled":true},"recoveryCodesRemaining":8,"webauthn":[],"passkeyNudgeDismissed":false}"#
            )
            #expect(store.hasSecondFactor)
        }
    }

#endif
