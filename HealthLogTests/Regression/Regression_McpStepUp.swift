// Every value below is a fixture shape, not a real credential.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **REG (1.5) — SEC, #151: a connector (MCP) token is never created
    /// without the second factor.** POLISH-C (C1, #163 B1): the store
    /// mirrors the server's `elevation-if-enrolled` rule through its real
    /// resolver and a real ``AccountSecurityStore``. An account with a factor
    /// or a passkey sends no `POST /api/mcp/tokens` until a proof is
    /// supplied, also when `GET /api/version` fails and the status cannot be
    /// read (fail closed). An account without either mints straight away,
    /// without a proof and without the browser.
    @Suite("REG #151 SEC: no MCP token without the second factor, version unknown", .serialized, .mockURLSession)
    struct Regression_McpStepUp {
        private static let elevation = "hle_fixture_elevation_not_a_secret"
        private static let minted = #"{"data":{"token":"hlk_fixture_minted","name":"Claude"},"error":null}"#

        /// Every request the stub saw: path, method, `X-Step-Up`.
        private final class Seen: @unchecked Sendable {
            private struct Row {
                let path: String
                let method: String
                let stepUp: String?
            }

            private let lock = NSLock()
            private var rows: [Row] = []
            func record(_ req: URLRequest) {
                let row = Row(
                    path: req.url?.path ?? "",
                    method: req.httpMethod ?? "GET",
                    stepUp: req.value(forHTTPHeaderField: "X-Step-Up")
                )
                lock.withLock { rows.append(row) }
            }

            var mints: [String?] {
                lock.withLock { rows.filter { $0.path == "/api/mcp/tokens" && $0.method == "POST" }.map(\.stepUp) }
            }
        }

        /// `version` `nil` answers `GET /api/version` with a 404 (unreachable).
        private static func install(_ seen: Seen, version: String?, mfa: String) {
            MockURLProtocol.install { req in
                seen.record(req)
                let path = req.url?.path ?? ""
                let (status, body): (Int, String) = switch (path, req.httpMethod ?? "GET") {
                case ("/api/version", _):
                    version.map { (200, #"{"data":{"version":"\#($0)"},"error":null}"#) } ?? (404, "")
                case ("/api/auth/me/mfa", _): (200, #"{"data":\#(mfa),"error":null}"#)
                case ("/api/mcp/tokens", "POST"): (201, minted)
                default: (200, #"{"data":[],"error":null}"#)
                }
                return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
        }

        private static func mfa(totp: Bool, methods: String) -> String {
            #"{"totp":{"enabled":\#(totp)},"recoveryCodesRemaining":0,"webauthn":[],"#
                + #""passkeyNudgeDismissed":false,"proofMethods":\#(methods)}"#
        }

        private static func makeAPI() throws -> APIClient {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_fixture_session", forKey: KeychainKey.authToken)
            return APIClient(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local")!,
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.5.0",
                    buildNumber: "300"
                ),
                keychain: keychain,
                sessionConfiguration: .mock(),
                onUnauthorized: {},
                refreshHandler: { .refreshed }
            )
        }

        @MainActor
        private static func makeStore() throws -> McpStore {
            let api = try makeAPI()
            let security = AccountSecurityStore(repo: AccountSecurityRepository(api: api))
            return McpStore(repo: McpRepository(api: api)) { await McpStore.resolveProofUpFront(security: security) }
        }

        @MainActor
        @Test("an account with a second factor: no mint goes out without the proof, then one with it")
        func enrolledNeverMintsWithoutProof() async throws {
            let seen = Seen()
            Self.install(seen, version: "1.47.0", mfa: Self.mfa(totp: true, methods: #"["totp"]"#))
            let store = try Self.makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .readWrite) == false)
            #expect(seen.mints.isEmpty, "a mint left without the second factor")
            #expect(store.stepUp.isRequested)
            #expect(store.error == StepUpRetry.requiredMessage)
            #expect(store.freshToken == nil)

            store.stepUp.supply(Self.elevation)
            #expect(await store.mintToken(name: "Claude", scope: .readWrite))
            #expect(seen.mints == [Self.elevation])
        }

        @MainActor
        @Test("the version probe fails, so the status cannot be read: still no mint without the proof")
        func unreachableVersionNeverMintsWithoutProof() async throws {
            let seen = Seen()
            Self.install(seen, version: nil, mfa: Self.mfa(totp: true, methods: #"["totp"]"#))
            let store = try Self.makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .readWrite) == false)
            #expect(seen.mints.isEmpty, "a mint left on the token alone")
            #expect(store.stepUp.isRequested)

            store.stepUp.supply(Self.elevation)
            #expect(await store.mintToken(name: "Claude", scope: .readWrite))
            #expect(seen.mints == [Self.elevation])
        }

        @MainActor
        @Test("an account with neither factor nor passkey (SSO only) mints straight away, without a proof")
        func unenrolledMintsDirectly() async throws {
            let seen = Seen()
            Self.install(seen, version: "1.47.0", mfa: Self.mfa(totp: false, methods: "[]"))
            let store = try Self.makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .readWrite))
            #expect(seen.mints == [nil])
            #expect(store.stepUp.isRequested == false)
        }

        @MainActor
        @Test("a passkey alone is enough to be asked for the proof")
        func passkeyOnlyAsks() async throws {
            let seen = Seen()
            Self.install(seen, version: "1.47.0", mfa: Self.mfa(totp: false, methods: #"["password","passkey"]"#))
            let store = try Self.makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .readWrite) == false)
            #expect(seen.mints.isEmpty)
            #expect(store.stepUp.isRequested)
        }
    }
#endif
