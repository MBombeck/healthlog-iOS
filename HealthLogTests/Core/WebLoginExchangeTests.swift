// #65 / v1.32.11 — pins the web-handoff token exchange
// (POST /api/auth/native/token).
//
// Coverage:
//   1. request SHAPE — path /api/auth/native/token, X-Client-Type: native
//      header, body {code, codeVerifier} (body-stream drain like the OIDC test).
//   2. 200 + standard bundle → session decoded, authToken + refreshToken stored.
//   3. 401 (generic invalid-code) → throws; Keychain stays empty.
//
// Drives the REAL `APIClient` over a stub `URLProtocol`, per the repo's
// no-mock-server doctrine (fixtures mirror `OidcSSOLoginTests`).

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Web-handoff token exchange (#65)", .serialized)
    struct WebLoginExchangeTests {
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

        private static func bundleBody() -> Data {
            Data(#"""
            {
              "data": {
                "user": { "id": "user-web-1", "username": "webuser" },
                "token": "hlk_bearer_WEB",
                "tokenExpiresAt": "2026-07-01T12:00:00Z",
                "refreshToken": "hlr_refresh_WEB",
                "refreshTokenExpiresAt": "2026-09-01T12:00:00Z"
              },
              "error": null
            }
            """#.utf8)
        }

        // MARK: - 1) + 2) request shape + bundle decode → stored

        @Test("webLoginTokenExchange posts {code, codeVerifier} + X-Client-Type: native and stores the bundle")
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

            let session = try await service.webLoginTokenExchange(
                code: "hlh_web0123456789012345678901234567890123456",
                codeVerifier: "verifier-web-0123456789012345678901234567890"
            )

            #expect(session.token == "hlk_bearer_WEB")
            #expect(session.user.id == "user-web-1")
            #expect(capturedPath == "/api/auth/native/token")
            #expect(capturedClientType == "native")
            let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("hlh_web0123456789012345678901234567890123456"))
            #expect(bodyString.contains("verifier-web-0123456789012345678901234567890"))
            // Stored + rotatable exactly like password/passkey/OIDC login.
            #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_WEB")
            #expect(kc.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_WEB")
        }

        // MARK: - 3) generic 401 → throws, no token

        @Test("a consumed/expired code (generic 401) throws and stores no token")
        func tokenExchangeFailureThrows() async throws {
            let kc = InMemoryKeychain()
            let (service, _) = makeService(kc)
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Invalid code"}"#.utf8)
                )
            }

            await #expect(throws: (any Error).self) {
                _ = try await service.webLoginTokenExchange(
                    code: "hlh_used0000000000000000000000000000000000000",
                    codeVerifier: "verifier-0123456789012345678901234567890123"
                )
            }
            #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
            #expect(kc.getString(forKey: KeychainKey.refreshToken) == nil)
        }

        // MARK: - version gate: webLoginAvailable() (fail-closed)

        private static func versionBody(_ version: String) -> Data {
            Data(#"{"data":{"version":"\#(version)"},"error":null}"#.utf8)
        }

        @Test("webLoginAvailable — the frozen contract version (1.32.11) is available")
        func versionGateAtFloor() async {
            let (service, _) = makeService()
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.versionBody("1.32.11"))
            }
            let available = await service.webLoginAvailable()
            #expect(available == true)
        }

        @Test("webLoginAvailable — one patch below the floor is NOT available")
        func versionGateBelowFloor() async {
            let (service, _) = makeService()
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.versionBody("1.32.10"))
            }
            let available = await service.webLoginAvailable()
            #expect(available == false)
        }

        @Test("webLoginAvailable — a newer minor is available")
        func versionGateAboveFloor() async {
            let (service, _) = makeService()
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.versionBody("1.33.0"))
            }
            let available = await service.webLoginAvailable()
            #expect(available == true)
        }

        @Test("webLoginAvailable — a 500 fails closed to false")
        func versionGateServerErrorFailsClosed() async {
            let (service, _) = makeService()
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }
            let available = await service.webLoginAvailable()
            #expect(available == false)
        }

        @Test("webLoginAvailable — a transport error fails closed to false")
        func versionGateTransportErrorFailsClosed() async {
            let (service, _) = makeService()
            MockURLProtocol.handler = { _ in
                throw URLError(.notConnectedToInternet)
            }
            let available = await service.webLoginAvailable()
            #expect(available == false)
        }
    }

#endif
