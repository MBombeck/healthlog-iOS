// 13-02 — `webLoginAvailable` must be a statement about the login route, not
// about the server's version number.
//
// The shipped gate is `AuthService.swift:931-934`: `GET /api/version` ≥
// 1.32.11 and nothing else. The operator's instance is comfortably past that
// floor and its login route still dead-ends (#96), so build 266 showed a
// brand-new user a CTA into a browser error page and called it available.
//
// Drives the REAL `AuthService` over the REAL `APIClient` on a session-scoped
// `MockURLProtocolSession` (09-13), so the probe is measured through the
// transport it actually uses.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Web-login availability is reachability (13-02)", .serialized)
    struct WebLoginAvailabilityProbeTests {
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

        /// A version comfortably past the frozen web-handoff floor — the
        /// operator's own instance is here, and its login route still
        /// dead-ends.
        private static let currentVersion = "1.37.20"

        private static func versionBody(_ version: String) -> Data {
            Data(#"{"data":{"version":"\#(version)"},"error":null}"#.utf8)
        }

        /// The address the operator's instance redirects to (#96) — a bind
        /// address, not a routable host.
        private static let bindAddressRedirect = "https://0.0.0.0:3000/auth/login?flow=native"

        private func makeService(_ session: MockURLProtocolSession) -> AuthService {
            let keychain = InMemoryKeychain()
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            try? keychain.setString(session.baseURL.absoluteString, forKey: KeychainKey.serverURL)
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
            return AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
        }

        // MARK: - the lie

        /// `/api/version` says 1.37.20; the login route redirects to the
        /// server's own bind address, which no client can follow. `URLSession`
        /// follows the redirect and fails on the address it landed on — this
        /// handler throws exactly the error the loading system delivers, with
        /// the failing URL in the userInfo slot it uses.
        @Test("Eine aktuelle Version allein rechtfertigt den Browser-Knopf nicht")
        func versionAloneDoesNotGrantTheCTA() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let deadEnd = try #require(URL(string: Self.bindAddressRedirect))
            session.install { request in
                if request.targets("/api/version") {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.versionBody(Self.currentVersion)
                    )
                }
                throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: deadEnd])
            }

            let available = await makeService(session).webLoginAvailable()

            #expect(
                available == false,
                "EXPECTED_RED: webLoginAvailable is a version statement, not a reachability statement"
            )
        }

        // MARK: - controls (green before and after)

        @Test("Ein Server unter der eingefrorenen Vertragsversion bleibt aus")
        func belowTheContractFloorStaysUnavailable() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.versionBody("1.32.10")
                )
            }
            let available = await makeService(session).webLoginAvailable()
            #expect(available == false)
        }

        @Test("Offline ist kein Absturz, sondern ein Nein")
        func offlineFailsClosedWithoutCrashing() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { _ in throw URLError(.notConnectedToInternet) }
            let available = await makeService(session).webLoginAvailable()
            #expect(available == false)
        }

        @Test("Ein gesunder Server mit erreichbarer Anmelde-Route bekommt den Knopf")
        func healthyServerKeepsTheCTA() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                if request.targets("/api/version") {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.versionBody(Self.currentVersion)
                    )
                }
                // The login route answers on its own origin — a well-configured
                // instance behind a proxy that forwards the host.
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 307,
                        httpVersion: nil,
                        headerFields: ["Location": "/auth/login?flow=native"]
                    )!,
                    Data()
                )
            }
            let available = await makeService(session).webLoginAvailable()
            #expect(available == true)
        }

        // MARK: - the gate names its reason

        @Test("Die Sackgasse wird benannt, nicht in ein stilles Nein gefaltet")
        func deadEndIsNamedNotSwallowed() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let deadEnd = try #require(URL(string: Self.bindAddressRedirect))
            session.install { request in
                if request.targets("/api/version") {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.versionBody(Self.currentVersion)
                    )
                }
                // The unfollowed form of the same defect: the 307 itself.
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 307,
                        httpVersion: nil,
                        headerFields: ["Location": deadEnd.absoluteString]
                    )!,
                    Data()
                )
            }

            let status = await makeService(session).webLoginRouteStatus()

            #expect(status == .deadEndRedirect(host: "0.0.0.0"))
            #expect(status.logLabel == "dead_end_redirect")
        }

        @Test("Ein Server unter der Vertragsversion sagt warum")
        func versionFloorIsNamed() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.versionBody("1.32.10")
                )
            }
            #expect(await makeService(session).webLoginRouteStatus() == .versionTooOld)
        }

        @Test("Eine fehlende Route ist keine Sackgasse, sondern eine fehlende Route")
        func missingRouteIsNamed() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                if request.targets("/api/version") {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.versionBody(Self.currentVersion)
                    )
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            #expect(await makeService(session).webLoginRouteStatus() == .routeMissing)
        }

        // MARK: - the probe is asked once per host

        /// The auth step must never probe per render. Two consecutive asks hit
        /// the network once.
        @Test("Die Probe läuft einmal pro Host, nicht pro Frage")
        func theProbeIsCachedPerHost() async {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let counter = RequestCounter()
            session.install { request in
                if request.targets("/api/version") { counter.increment() }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.versionBody(Self.currentVersion)
                )
            }
            let service = makeService(session)

            _ = await service.webLoginRouteStatus()
            _ = await service.webLoginRouteStatus()

            #expect(counter.value == 1)
        }

        // MARK: - the classifier

        /// The exemption that keeps a `localhost` self-hoster — and this very
        /// test transport, addressed at a `.invalid` host — working.
        @Test("Die eigene Origin ist nie eine Sackgasse, auch wenn sie loopback heißt")
        func theConfiguredOriginIsNeverADeadEnd() throws {
            let loopback = try #require(URL(string: "http://localhost:3000/auth/login?flow=native"))
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: loopback, configuredHost: "localhost") == false)
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: loopback, configuredHost: "meinserver.example.com"))

            let mockHost = try #require(URL(string: "https://abc.mock.invalid/auth/login"))
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: mockHost, configuredHost: "abc.mock.invalid") == false)
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: mockHost, configuredHost: "def.mock.invalid"))

            let idp = try #require(URL(string: "https://idp.example.com/authorize"))
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: idp, configuredHost: "meinserver.example.com") == false)

            let bind = try #require(URL(string: "https://0.0.0.0:3000/auth/login"))
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: bind, configuredHost: "meinserver.example.com"))
            #expect(WebLoginRedirectPolicy.isDeadEnd(target: nil, configuredHost: "meinserver.example.com") == false)
        }

        /// The probe and the browser must open the same address. They share one
        /// builder now; this is the pin that keeps them sharing it.
        @Test("Probe und Browser bauen dieselbe Anmelde-URL")
        func probeAndBrowserAgreeOnTheURL() throws {
            let base = try #require(URL(string: "https://meinserver.example.com"))
            let fromFlow = WebLoginNativeFlow.loginURL(baseURL: base, codeChallenge: "abc")
            let fromRoute = WebLoginRoute.loginURL(baseURL: base, codeChallenge: "abc")
            #expect(fromFlow == fromRoute)
            #expect(fromFlow?.path == WebLoginRoute.path)
        }
    }

    /// Handler-side counter. The handler is `@Sendable`, so the count lives
    /// behind a lock rather than in a captured `var`.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

#endif
