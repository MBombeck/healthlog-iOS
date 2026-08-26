// parity 2.9 — "auth honesty": the login surface must promise only what the
// configured server can actually deliver.
//
// Coverage:
//   1. `GET /api/auth/oidc/status` decode → `OidcStatus` for the three shapes
//      the server can report (absent IdP / enabled / OIDC-only), plus the
//      operator's `buttonLabel`.
//   2. the fail-soft stance when the probe cannot be answered (never a screen
//      with no way in).
//   3. the `hidesPasswordAffordances` guard, including the misconfiguration
//      (`only` without `enabled`) that must NOT lock every door.
//   4. the signup body carries the device timezone.
//
// Drives the REAL `APIClient` over a stub `URLProtocol`, per the repo's
// no-mock-server doctrine (same idiom as `OidcSSOLoginTests`).

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("OIDC status + signup honesty (parity 2.9)", .serialized)
    struct OidcStatusHonestyTests {
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

        private func makeService(_ keychain: InMemoryKeychain = InMemoryKeychain()) -> AuthService {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            return AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
        }

        /// `URLRequest.httpBody` is nil once URLSession has converted the body
        /// to a stream, so read whichever one the runtime handed us.
        private static func body(of req: URLRequest) -> Data {
            if let data = req.httpBody { return data }
            guard let stream = req.httpBodyStream else { return Data() }
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

        private static func statusBody(enabled: Bool, only: Bool, label: String?) -> Data {
            let labelJSON = label.map { "\"\($0)\"" } ?? "null"
            return Data(#"{"data":{"enabled":\#(enabled),"buttonLabel":\#(labelJSON),"only":\#(only)},"error":null}"#.utf8)
        }

        // MARK: - 1) the three server shapes

        @Test("no IdP configured — SSO button must be hidden")
        func statusAbsentHidesSSO() async {
            let service = makeService()
            nonisolated(unsafe) var capturedPath: String?
            MockURLProtocol.handler = { req in
                capturedPath = req.url?.path
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.statusBody(enabled: false, only: false, label: nil)
                )
            }

            let status = await service.oidcStatus()

            #expect(capturedPath == "/api/auth/oidc/status")
            #expect(status.enabled == false)
            #expect(status.only == false)
            #expect(status.buttonLabel == nil)
            // Password + passkey + register stay available — this is a normal
            // password-only instance, not a locked-down one.
            #expect(status.hidesPasswordAffordances == false)
        }

        @Test("IdP enabled alongside passwords — every door stays open, operator label honoured")
        func statusEnabledKeepsAllDoors() async {
            let service = makeService()
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.statusBody(enabled: true, only: false, label: "Sign in with Acme SSO")
                )
            }

            let status = await service.oidcStatus()

            #expect(status.enabled == true)
            #expect(status.only == false)
            #expect(status.buttonLabel == "Sign in with Acme SSO")
            #expect(status.hidesPasswordAffordances == false)
        }

        @Test("OIDC_ONLY — password, passkey and register must all be hidden")
        func statusOnlyHidesPasswordAffordances() async {
            let service = makeService()
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.statusBody(enabled: true, only: true, label: "Corporate login")
                )
            }

            let status = await service.oidcStatus()

            #expect(status.enabled == true)
            #expect(status.only == true)
            #expect(status.buttonLabel == "Corporate login")
            // The whole point of the item: stop offering three CTAs the server refuses.
            #expect(status.hidesPasswordAffordances == true)
        }

        // MARK: - 2) fail-soft

        @Test("an unreachable status probe shows every door rather than none")
        func statusProbeFailureFailsSoft() async {
            let service = makeService()
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }

            let status = await service.oidcStatus()

            #expect(status == OidcStatus.unknown)
            #expect(status.enabled == true)
            #expect(status.hidesPasswordAffordances == false)
        }

        // MARK: - 3) misconfiguration must not lock every door

        @Test("only=true without enabled must not hide the password form")
        func onlyWithoutEnabledKeepsPasswordForm() {
            // `only` is a bare env read server-side, independent of whether an
            // IdP actually resolved. Honouring it alone would render a login
            // screen with no doors at all.
            let bogus = OidcStatus(enabled: false, buttonLabel: nil, only: true)
            #expect(bogus.hidesPasswordAffordances == false)
        }

        @Test("an empty operator buttonLabel falls back to the generic wording")
        func blankButtonLabelIsTreatedAsAbsent() {
            #expect(OidcStatus(enabled: true, buttonLabel: "   ", only: false).buttonLabel == nil)
            #expect(OidcStatus(enabled: true, buttonLabel: "", only: false).buttonLabel == nil)
            #expect(OidcStatus(enabled: true, buttonLabel: " Acme ", only: false).buttonLabel == "Acme")
        }

        // MARK: - 4) the signup body carries the device timezone

        @Test("register posts the device timezone so new accounts are not born in the wrong zone")
        func registerBodyCarriesTimezone() async throws {
            let service = makeService()
            nonisolated(unsafe) var registerBody: Data?
            MockURLProtocol.handler = { req in
                let path = req.url?.path ?? ""
                if path == "/api/auth/register" {
                    registerBody = Self.body(of: req)
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":null}"#.utf8)
                    )
                }
                // register chains a login to obtain the Bearer bundle.
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"""
                    {
                      "data": {
                        "user": { "id": "user-new-1", "username": "newuser" },
                        "token": "hlk_bearer_NEW",
                        "tokenExpiresAt": "2026-07-01T12:00:00Z"
                      },
                      "error": null
                    }
                    """#.utf8)
                )
            }

            let session = try await service.register(
                email: "new@example.com",
                username: "newuser",
                password: "correct-horse-battery-staple"
            )

            #expect(session.token == "hlk_bearer_NEW")
            let bodyData = try #require(registerBody)
            let parsed = try JSONSerialization.jsonObject(with: bodyData)
            let json = try #require(parsed as? [String: Any])
            // Web's registration sends the browser zone (auth/register/page.tsx);
            // iOS must send the device zone or every timestamp is wrong until
            // the user notices and fixes it by hand in Profile.
            #expect(json["timezone"] as? String == TimeZone.current.identifier)
            #expect(json["email"] as? String == "new@example.com")
        }

        @Test("an explicit timezone overrides the device default")
        func registerHonoursExplicitTimezone() async throws {
            let service = makeService()
            nonisolated(unsafe) var registerBody: Data?
            MockURLProtocol.handler = { req in
                let path = req.url?.path ?? ""
                if path == "/api/auth/register" {
                    registerBody = Self.body(of: req)
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":null}"#.utf8)
                    )
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"""
                    {
                      "data": {
                        "user": { "id": "user-new-2", "username": "tzuser" },
                        "token": "hlk_bearer_TZ",
                        "tokenExpiresAt": "2026-07-01T12:00:00Z"
                      },
                      "error": null
                    }
                    """#.utf8)
                )
            }

            _ = try await service.register(
                email: "tz@example.com",
                username: "tzuser",
                password: "correct-horse-battery-staple",
                timezone: "Pacific/Auckland"
            )

            let bodyData = try #require(registerBody)
            let parsed = try JSONSerialization.jsonObject(with: bodyData)
            let json = try #require(parsed as? [String: Any])
            #expect(json["timezone"] as? String == "Pacific/Auckland")
        }
    }

#endif

// swiftlint:enable force_unwrapping
