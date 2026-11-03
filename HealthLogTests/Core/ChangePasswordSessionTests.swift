// B5 (1.4, from A4) — a wrong current password must not sign the person out.
//
// Server contract, read at v1.43.10 (`git show`, not invented):
// - `src/app/api/auth/password/route.ts` answers a wrong current password with
//   `apiError("Current password is incorrect", 401)`; `withErrorEnvelopeDefaults`
//   adds `meta.errorCode: "http.unauthenticated"` (v1.43.7). Before that the
//   401 carried no code at all.
// - A dead or expired bearer answers 401 with `auth.token.expired`,
//   `auth.token.invalid` or `auth.missing` (`AUTH_ERROR_CODES`, v1.38.15).
//
// Up to 1.3 the client read every 401 there as a dead session: refresh, send
// the password change a second time (a second guess against the re-proof
// budget), meet the same 401, spend the refresh budget, `onUnauthorized`, out.
// Drives the REAL `APIClient` over `MockURLProtocol`.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("B5 — change password: a wrong current password keeps the session", .serialized, .mockURLSession)
    struct ChangePasswordSessionTests {
        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() {
                lock.withLock { value += 1 }
            }

            var total: Int {
                lock.withLock { value }
            }
        }

        private static func response(_ req: URLRequest, _ status: Int, _ json: String) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        private func makeAPI(refreshes: Counter, signOuts: Counter) throws -> APIClient {
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

        /// v1.43.7 and later name the default code; older servers name none.
        @Test("wrong current password: one request, no refresh, no sign-out, the refusal surfaces typed", arguments: [
            "http.unauthenticated", nil
        ] as [String?])
        func wrongCurrentPasswordKeepsTheSession(_ code: String?) async throws {
            let meta = code.map { #","meta":{"errorCode":"\#($0)","requestId":"req_1"}"# } ?? ""
            let body = #"{"data":null,"error":"Current password is incorrect"\#(meta)}"#
            let refreshes = Counter()
            let signOuts = Counter()
            let sent = Counter()
            let api = try makeAPI(refreshes: refreshes, signOuts: signOuts)
            MockURLProtocol.install { req in
                sent.bump()
                return Self.response(req, 401, body)
            }

            let repo = AccountSecurityRepository(api: api)
            var thrown: HLError?
            do {
                try await repo.changePassword(current: "wrong", new: "a-New-pass-phrase-42", confirm: "a-New-pass-phrase-42")
            } catch let error as HLError {
                thrown = error
            }
            #expect(thrown == .server(status: 401, code: code, message: "Current password is incorrect"))
            #expect(sent.total == 1, "a second send spends a second guess of the re-proof budget")
            #expect(refreshes.total == 0)
            #expect(signOuts.total == 0, "a wrong current password must never sign the person out")
        }

        @Test("an expired bearer on the same route still refreshes once and goes through", arguments: [
            "auth.token.expired", "auth.token.invalid", "auth.missing"
        ])
        func expiredBearerStillRefreshes(_ code: String) async throws {
            let refreshes = Counter()
            let signOuts = Counter()
            let sent = Counter()
            let api = try makeAPI(refreshes: refreshes, signOuts: signOuts)
            MockURLProtocol.install { req in
                sent.bump()
                if sent.total == 1 {
                    return Self.response(req, 401, #"{"data":null,"error":"Token expired","meta":{"errorCode":"\#(code)"}}"#)
                }
                return Self.response(req, 200, #"{"data":{"success":true},"error":null}"#)
            }

            try await AccountSecurityRepository(api: api)
                .changePassword(current: "right", new: "a-New-pass-phrase-42", confirm: "a-New-pass-phrase-42")
            #expect(refreshes.total == 1)
            #expect(signOuts.total == 0)
            #expect(sent.total == 2)
        }

        @Test("only the password route reads a code-less 401 as a credential check")
        func scopedToThePasswordRoute() {
            let plain = Data(#"{"data":null,"error":"Not authenticated","meta":{"errorCode":"http.unauthenticated"}}"#.utf8)
            #expect(APIClient.isCredentialCheckRefusal(path: "/api/auth/password", body: plain))
            #expect(!APIClient.isCredentialCheckRefusal(path: "/api/measurements", body: plain))
            let expired = Data(#"{"data":null,"error":"Token expired","meta":{"errorCode":"auth.token.expired"}}"#.utf8)
            #expect(!APIClient.isCredentialCheckRefusal(path: "/api/auth/password", body: expired))
        }
    }
#endif
