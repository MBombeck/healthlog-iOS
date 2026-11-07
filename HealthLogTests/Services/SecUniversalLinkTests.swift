// SEC (1.5, #151) — the native SSO return: `https` for a host the build
// associates with and whose server announced the path, the custom scheme with
// PKCE for every other host (every released server today).
//
// Server contract, read at v1.47.0:
// - `src/lib/auth/oidc-native-handoff.ts` — `NATIVE_OIDC_REDIRECT_URI =
//   "healthlog://oidc-callback"`, compiled in; no `https` native return.
// - `src/app/.well-known/apple-app-site-association/route.ts` — the same AASA
//   on every host: `applinks` `paths: ["*"]` and `webcredentials`, appID
//   `S8WDX4W5KX.dev.healthlog.app`.
//
// Every code and token below is a fixture shape, not a credential.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE && canImport(AuthenticationServices) && canImport(UIKit)

    import AuthenticationServices
    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("SEC: SSO return over Universal Links", .serialized, .mockURLSession)
    struct SecUniversalLinkTests {
        private static let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        private static let associated = "healthlog.example.com"
        private static let returnPath = "/api/auth/oidc/native/return"

        // MARK: - The decision

        @Test("an associated host whose server names the path returns over https")
        func associatedHostTakesHTTPS() {
            let route = OidcReturnRoute.resolve(
                serverURL: URL(string: "https://HealthLog.Example.com/"),
                appLinkHosts: [Self.associated],
                serverReturnPath: Self.returnPath
            )
            #expect(route == .https(host: Self.associated, path: Self.returnPath))
            #expect(route.customScheme == nil)
        }

        @Test("a foreign host stays on the scheme, even when its server names a path")
        func foreignHostTakesScheme() {
            let route = OidcReturnRoute.resolve(
                serverURL: URL(string: "https://health.someone-else.org"),
                appLinkHosts: [Self.associated],
                serverReturnPath: Self.returnPath
            )
            #expect(route == .customScheme("healthlog"))
        }

        @Test("without the server naming a path every host stays on the scheme (every released server)")
        func noServerPathTakesScheme() {
            let route = OidcReturnRoute.resolve(
                serverURL: URL(string: "https://\(Self.associated)"),
                appLinkHosts: [Self.associated],
                serverReturnPath: nil
            )
            #expect(route == .scheme)
        }

        @Test("http, another port, a look-alike host or a bent path fall back to the scheme", arguments: [
            ("http://healthlog.example.com", "/api/auth/oidc/native/return"),
            ("https://healthlog.example.com:8443", "/api/auth/oidc/native/return"),
            ("https://healthlog.example.com.evil.test", "/api/auth/oidc/native/return"),
            ("https://evilhealthlog.example.com", "/api/auth/oidc/native/return"),
            ("https://healthlog.example.com", "api/auth/return"),
            ("https://healthlog.example.com", "//evil.test/return"),
            ("https://healthlog.example.com", "/api/../evil"),
            ("https://healthlog.example.com", "/return?next=https://evil.test"),
            ("https://healthlog.example.com", "/return#frag"),
            ("https://healthlog.example.com", "/rückweg"),
            ("https://healthlog.example.com", "/return/\(String(repeating: "a", count: 130))")
        ])
        func unsafeInputsTakeScheme(_ server: String, _ path: String) {
            let route = OidcReturnRoute.resolve(
                serverURL: URL(string: server),
                appLinkHosts: [Self.associated],
                serverReturnPath: path
            )
            #expect(route == .scheme)
        }

        @Test("the shipped build associates with no host, so it always takes the scheme")
        func shippedBuildHasNoHosts() {
            #expect(OidcReturnRoute.bundleHosts().isEmpty)
            #expect(Bundle.main.object(forInfoDictionaryKey: OidcReturnRoute.infoPlistKey) == nil)
            let route = OidcReturnRoute.resolve(
                serverURL: URL(string: "https://\(Self.associated)"),
                serverReturnPath: Self.returnPath
            )
            #expect(route == .scheme)
        }

        @Test("release configuration: no Associated Domains, no app-link hosts, overlay documents both")
        func releaseEntitlements() throws {
            let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
            #expect(!project.contains("com.apple.developer.associated-domains"))
            #expect(!project.contains("HLAppLinkHosts:"))
            let entitlementsURL = Self.root.appendingPathComponent("HealthLog/Resources/HealthLog.entitlements")
            let data = try Data(contentsOf: entitlementsURL)
            let entitlements = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            #expect(entitlements["com.apple.developer.associated-domains"] == nil)
            let info = try Data(contentsOf: Self.root.appendingPathComponent("HealthLog/Resources/Info.plist"))
            let plist = try #require(PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
            #expect(plist[OidcReturnRoute.infoPlistKey] == nil)
            let overlay = try String(
                contentsOf: Self.root.appendingPathComponent("Config/local.example.yml"),
                encoding: .utf8
            )
            #expect(overlay.contains("HLAppLinkHosts:"))
            #expect(overlay.contains("applinks:healthlog.example.com"))
        }

        // MARK: - The authorize URL

        @Test("the scheme return sends exactly the 1.4 authorize URL; https adds return=https")
        func loginURL() throws {
            let base = try #require(URL(string: "https://\(Self.associated)"))
            let scheme = try #require(OidcNativeFlow.loginURL(baseURL: base, codeChallenge: "challenge"))
            #expect(scheme.absoluteString
                == "https://healthlog.example.com/api/auth/oidc/login?client=native&code_challenge=challenge")
            let https = try #require(OidcNativeFlow.loginURL(
                baseURL: base,
                codeChallenge: "challenge",
                returnRoute: .https(host: Self.associated, path: Self.returnPath)
            ))
            #expect(https.query == "client=native&code_challenge=challenge&return=https")
        }

        // MARK: - The real session callback (iOS 17.4 API, on the simulator)

        @Test("the https callback matches only its own host and path; the scheme callback only the scheme")
        func callbackMatching() throws {
            let https = OidcReturnRoute.https(host: Self.associated, path: Self.returnPath).sessionCallback
            let ours = try #require(URL(string: "https://\(Self.associated)\(Self.returnPath)?code=hlh_fixture"))
            #expect(https.matchesURL(ours))
            #expect(try !https.matchesURL(#require(URL(string: "https://evil.test\(Self.returnPath)?code=hlh_fixture"))))
            #expect(try !https.matchesURL(#require(URL(string: "https://\(Self.associated)/elsewhere?code=hlh_fixture"))))
            #expect(try !https.matchesURL(#require(URL(string: "healthlog://oidc-callback?code=hlh_fixture"))))

            let scheme = OidcReturnRoute.scheme.sessionCallback
            #expect(try scheme.matchesURL(#require(URL(string: "healthlog://oidc-callback?code=hlh_fixture"))))
            #expect(!scheme.matchesURL(ours))
        }

        // MARK: - The driver seam

        @MainActor
        private final class RecordingSession: WebAuthenticationSession {
            var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
            var prefersEphemeralWebBrowserSession = true
            private(set) var started = false
            func start() -> Bool {
                started = true
                return true
            }

            func cancel() {}
        }

        @MainActor
        private final class RecordingFactory: WebAuthenticationSessionCreating {
            let session = RecordingSession()
            private(set) var route: OidcReturnRoute?
            private(set) var scheme: String?
            private(set) var callback: ((URL?, Error?) -> Void)?

            func makeSession(
                url _: URL,
                callbackURLScheme: String?,
                completionHandler: @escaping (URL?, Error?) -> Void
            ) -> any WebAuthenticationSession {
                scheme = callbackURLScheme
                callback = completionHandler
                return session
            }

            func makeSession(
                url _: URL,
                returnRoute: OidcReturnRoute,
                completionHandler: @escaping (URL?, Error?) -> Void
            ) -> any WebAuthenticationSession {
                route = returnRoute
                callback = completionHandler
                return session
            }
        }

        @MainActor
        private final class StubAnchor: ASPresentationAnchorProvider {
            func anchor() -> ASPresentationAnchor {
                ASPresentationAnchor()
            }
        }

        @Test("the driver hands the session the https return for the associated host, the scheme otherwise", arguments: [
            OidcReturnRoute.https(host: "healthlog.example.com", path: "/api/auth/oidc/native/return"),
            OidcReturnRoute.customScheme("healthlog")
        ])
        func driverForwardsRoute(_ route: OidcReturnRoute) async throws {
            let factory = RecordingFactory()
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: factory)
            let login = try #require(URL(string: "https://healthlog.example.com/api/auth/oidc/login"))
            let task = Task { @MainActor in
                await driver.authenticate(loginURL: login, returnRoute: route, anchor: StubAnchor())
            }
            while !factory.session.started {
                await Task.yield()
            }
            #expect(factory.route == route)
            let back = try #require(URL(string: "https://healthlog.example.com/api/auth/oidc/native/return?code=hlh_fixture"))
            factory.callback?(back, nil)
            guard case let .callback(url) = await task.value else {
                Issue.record("expected the callback outcome")
                return
            }
            #expect(url == back)
        }

        @Test("the old scheme entry point still builds the scheme session")
        func schemeEntryPointUnchanged() async throws {
            let factory = RecordingFactory()
            let driver = OidcWebAuthenticationSessionDriver(sessionFactory: factory)
            let login = try #require(URL(string: "https://healthlog.example.com/api/auth/oidc/login"))
            let task = Task { @MainActor in
                await driver.authenticate(loginURL: login, callbackScheme: "healthlog", anchor: StubAnchor())
            }
            while !factory.session.started {
                await Task.yield()
            }
            #expect(factory.route == .customScheme("healthlog"))
            factory.callback?(nil, nil)
            _ = await task.value
        }

        @Test("a stub that only knows the scheme fails closed on the https return")
        func stubFailsClosedOnHTTPS() async throws {
            @MainActor final class SchemeOnly: OidcAuthenticating {
                func authenticate(
                    loginURL _: URL,
                    callbackScheme _: String,
                    anchor _: ASPresentationAnchorProvider
                ) async -> OidcAuthOutcome {
                    .callback(URL(string: "healthlog://oidc-callback?code=hlh_fixture")!)
                }
            }
            let login = try #require(URL(string: "https://healthlog.example.com/api/auth/oidc/login"))
            let https = await SchemeOnly().authenticate(
                loginURL: login,
                returnRoute: .https(host: Self.associated, path: Self.returnPath),
                anchor: StubAnchor()
            )
            guard case .failed = https else {
                Issue.record("expected .failed")
                return
            }
        }

        // MARK: - The SSO start in the store

        @MainActor
        private final class RouteRecorder: OidcAuthenticating {
            private(set) var route: OidcReturnRoute?
            private(set) var loginURL: URL?
            func authenticate(
                loginURL _: URL,
                callbackScheme _: String,
                anchor _: ASPresentationAnchorProvider
            ) async -> OidcAuthOutcome {
                .canceled
            }

            func authenticate(
                loginURL: URL,
                returnRoute: OidcReturnRoute,
                anchor _: ASPresentationAnchorProvider
            ) async -> OidcAuthOutcome {
                self.loginURL = loginURL
                route = returnRoute
                return .canceled
            }
        }

        @Test("sign-in against a server this build does not associate with keeps the scheme, with PKCE")
        func storeKeepsSchemeForForeignHost() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("https://test.healthlog.local", forKey: KeychainKey.serverURL)
            let base = try #require(URL(string: "https://test.healthlog.local"))
            let env = AppEnvironment(
                baseURL: base,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            let store = AuthStore(auth: AuthService(api: api, keychain: keychain, passkey: NoopPasskey()), keychain: keychain)
            let recorder = RouteRecorder()
            store.oidcAuthenticator = recorder

            await store.loginWithSSO(anchor: StubAnchor(), returnPath: Self.returnPath)

            #expect(recorder.route == .customScheme("healthlog"))
            let query = recorder.loginURL?.query ?? ""
            #expect(query.contains("client=native"))
            #expect(query.contains("code_challenge="))
            #expect(!query.contains("return="))
            #expect(store.lastError == nil)
        }

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

        // MARK: - What arrives outside the session

        @Test("the invite universal link is unchanged")
        func inviteUnchanged() throws {
            let token = "hlv_" + String(repeating: "0a", count: 32)
            let link = try #require(URL(string: "https://test.healthlog.local/auth/register?invite=\(token)"))
            #expect(DeepLinkRoute.universalLink(link, expectedHost: "test.healthlog.local") == .invite(token: token))
            let scheme = try #require(URL(string: "healthlog://invite?token=\(token)"))
            #expect(DeepLinkRoute(url: scheme) == .invite(token: token))
            let foreign = try #require(URL(string: "https://elsewhere.test/auth/register?invite=\(token)"))
            #expect(DeepLinkRoute.universalLink(foreign, expectedHost: "test.healthlog.local") == nil)
        }

        @Test("a replayed or stray SSO return outside the session is never routed or exchanged")
        func strayReturnIsDropped() throws {
            let scheme = try #require(URL(string: "healthlog://oidc-callback?code=hlh_fixture"))
            #expect(DeepLinkRoute(url: scheme) == .unknown(scheme))
            let https = try #require(URL(string: "https://test.healthlog.local\(Self.returnPath)?code=hlh_fixture"))
            #expect(DeepLinkRoute.universalLink(https, expectedHost: "test.healthlog.local") == nil)
        }

        @Test("the https return parses like the scheme, purgeAt included (HealthLog#1341)")
        func httpsReturnParsesLikeScheme() throws {
            let code = try #require(URL(string: "https://\(Self.associated)\(Self.returnPath)?code=hlh_fixture"))
            #expect(OidcCallback.parse(code) == .code("hlh_fixture"))
            let pending = try #require(URL(
                string: "https://\(Self.associated)\(Self.returnPath)?error=account_deletion_pending&purgeAt=2026-11-18T09:30:00.000Z"
            ))
            guard case let .error(.accountDeletionPending(purgeAt)) = OidcCallback.parse(pending) else {
                Issue.record("expected account_deletion_pending")
                return
            }
            #expect(purgeAt != nil)
            let withoutDate = try #require(URL(string: "healthlog://oidc-callback?error=account_deletion_pending"))
            #expect(OidcCallback.parse(withoutDate) == .error(.accountDeletionPending(purgeAt: nil)))
        }
    }

#endif
