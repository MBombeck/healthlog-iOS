// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Synchronization
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    /// One signed-in session over the real client and the real refresh, with a
    /// stub server behind it: the protected route answers by bearer, the
    /// refresh route answers whatever the test says.
    struct RVSession: Sendable {
        static let oldBearer = "bearer-old"
        static let newBearer = "bearer-new"
        static let oldRefresh = "refresh-old"

        let api: APIClient
        let keychain: InMemoryKeychain
        let signOuts: RVCounter

        private final class NoPasskey: PasskeyServiceProtocol, @unchecked Sendable {
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

        static func signedIn() async throws -> RVSession {
            let keychain = InMemoryKeychain()
            try keychain.setString(oldBearer, forKey: KeychainKey.authToken)
            try keychain.setString(oldRefresh, forKey: KeychainKey.refreshToken)
            try keychain.setString("usr_1", forKey: KeychainKey.userID)
            try keychain.setString("device-1", forKey: KeychainKey.deviceID)
            let signOuts = RVCounter()
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.1",
                buildNumber: "303"
            )
            let api = APIClient(
                environment: env,
                keychain: keychain,
                sessionConfiguration: .mock(),
                onUnauthorized: { signOuts.bump() },
                retryClock: APIRetryClock(now: { Date() }, sleep: { _ in })
            )
            let auth = AuthService(api: api, keychain: keychain, passkey: NoPasskey())
            await api.setRefreshHandler { await auth.refresh() }
            return RVSession(api: api, keychain: keychain, signOuts: signOuts)
        }

        var stillSignedIn: Bool {
            signOuts.value == 0
                && keychain.getString(forKey: KeychainKey.authToken) == Self.oldBearer
                && keychain.getString(forKey: KeychainKey.refreshToken) == Self.oldRefresh
        }
    }

    final class RVCounter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func bump() {
            count.withLock { $0 += 1 }
        }
    }

    /// What reached the stub server, in order: the path and the bearer.
    final class RVWire: Sendable {
        struct Call: Sendable, Equatable {
            let path: String
            let bearer: String
        }

        private let calls = Mutex<[Call]>([])

        var all: [Call] {
            calls.withLock { $0 }
        }

        func record(_ req: URLRequest) {
            let bearer = (req.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
            calls.withLock { $0.append(Call(path: req.url?.path ?? "", bearer: bearer)) }
        }
    }

    enum RVServer {
        typealias Answer = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

        static let refreshPath = "/api/auth/refresh"

        /// `401 auth.refresh.invalid`, the route's answer to a token it no
        /// longer accepts (server v1.47.2, `src/app/api/auth/refresh/route.ts`).
        static let deadToken: Answer = { req in
            RVServer.reply(req, 401, #"{"data":null,"error":"Invalid refresh token","meta":{"errorCode":"auth.refresh.invalid"}}"#)
        }

        static let rotated: Answer = { req in
            RVServer.reply(req, 200, """
            {"data":{"token":"\(RVSession.newBearer)","tokenExpiresAt":"2026-12-01T00:00:00.000Z",\
            "refreshToken":"refresh-new","refreshTokenExpiresAt":"2027-01-01T00:00:00.000Z"},"error":null}
            """)
        }

        static func status(_ code: Int) -> Answer {
            { req in reply(req, code, #"{"data":null,"error":"not the app server's verdict"}"#) }
        }

        static func reply(_ req: URLRequest, _ status: Int, _ body: String, type: String = "application/json") -> (HTTPURLResponse, Data?) {
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": type]
            )!
            return (response, Data(body.utf8))
        }

        /// The protected route knows only the rotated bearer. `protected` is
        /// what it sends once the bearer is right.
        static func install(
            refresh: @escaping Answer,
            wire: RVWire,
            protected: @escaping Answer = { reply($0, 200, #"{"data":{},"error":null}"#) }
        ) {
            MockURLProtocol.install { req in
                wire.record(req)
                if req.url?.path == refreshPath { return try refresh(req) }
                guard req.value(forHTTPHeaderField: "Authorization") == "Bearer \(RVSession.newBearer)" else {
                    return reply(req, 401, #"{"data":null,"error":"Unauthorized"}"#)
                }
                return try protected(req)
            }
        }
    }

    /// The app signs a person out when the server says the refresh token is
    /// dead, and at no other answer. Every other failure of the refresh route
    /// costs this one request and leaves the session where it was.
    @Suite("Only the server's verdict on the refresh token signs out", .serialized, .mockURLSession)
    struct RefreshVerdictTests {
        private static let protectedPath = "/api/measurements"

        private func protectedRead(_ session: RVSession) async throws {
            let request: APIRequest<EmptyPayload> = .get(Self.protectedPath)
            try await session.api.sendVoid(request)
        }

        @Test("a dead refresh token signs out")
        func deadTokenSignsOut() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.deadToken, wire: wire)

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }

            #expect(session.signOuts.value >= 1)
            #expect(wire.all.count(where: { $0.path == RVServer.refreshPath }) == 1, "a refused token is not offered twice")
        }

        @Test(
            "an answer that is no verdict on the token keeps the session",
            arguments: [400, 403, 404, 409, 413, 422, 429, 500, 502, 503]
        )
        func otherStatusKeepsTheSession(status: Int) async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.status(status), wire: wire)

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }

            #expect(session.stillSignedIn, "status \(status) on the refresh route is not a dead token")
            #expect(wire.all.count(where: { $0.path == RVServer.refreshPath }) == 1, "the single-use token went out once")
        }

        @Test("a proxy page in place of the server keeps the session")
        func proxyPageKeepsTheSession() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(
                refresh: { RVServer.reply($0, 403, "<html><body>Access denied</body></html>", type: "text/html") },
                wire: wire
            )

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }

            #expect(session.stillSignedIn)
        }

        @Test(
            "a refresh that never reaches the server keeps the session",
            arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost]
        )
        func networkErrorKeepsTheSession(code: URLError.Code) async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: { _ in throw URLError(code) }, wire: wire)

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }

            #expect(session.stillSignedIn)
        }

        @Test("a refresh that works re-sends the request with the new bearer and signs nobody out")
        func rotationResendsTheRequest() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.rotated, wire: wire)

            try await protectedRead(session)

            #expect(session.signOuts.value == 0)
            #expect(wire.all == [
                .init(path: Self.protectedPath, bearer: RVSession.oldBearer),
                .init(path: RVServer.refreshPath, bearer: RVSession.oldBearer),
                .init(path: Self.protectedPath, bearer: RVSession.newBearer)
            ])
            #expect(session.keychain.getString(forKey: KeychainKey.authToken) == RVSession.newBearer)
        }

        @Test("the session survives a failed refresh and the next request refreshes again")
        func nextRequestTriesAgain() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            let serverIsBack = Mutex(false)
            RVServer.install(
                refresh: { req in
                    try serverIsBack.withLock { $0 } ? RVServer.rotated(req) : RVServer.status(502)(req)
                },
                wire: wire
            )

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }
            #expect(session.stillSignedIn)

            serverIsBack.withLock { $0 = true }
            try await protectedRead(session)
            #expect(session.signOuts.value == 0)
        }
    }

    /// The coach reply arrives as a stream. A 401 on it comes before the first
    /// line, so it takes the same road as every other request: one refresh,
    /// then the stream is opened again.
    @Suite("A 401 on the coach stream refreshes the session once", .serialized, .mockURLSession)
    struct CoachStreamRefreshTests {
        private static let chatPath = "/api/insights/chat"
        private static let sse = "data: {\"type\":\"token\",\"text\":\"Hallo\"}\n\ndata: {\"type\":\"done\"}\n\n"

        private func chat(recovers: Bool = true) -> APIRequest<Data> {
            APIRequest(
                method: .post,
                path: Self.chatPath,
                body: Data(#"{"message":"Hallo"}"#.utf8),
                extraHeaders: ["Accept": "text/event-stream"],
                maxRetries: 0,
                streaming: true,
                allowsAuthenticationRecovery: recovers
            )
        }

        private func lines(_ session: RVSession, _ request: APIRequest<Data>) async throws -> [String] {
            var seen: [String] = []
            for try await line in try await session.api.streamLines(request) where !line.isEmpty {
                seen.append(line)
            }
            return seen
        }

        private static let stream: RVServer.Answer = { req in
            RVServer.reply(req, 200, CoachStreamRefreshTests.sse, type: "text/event-stream")
        }

        @Test("an expired bearer is renewed and the reply streams")
        func expiredBearerIsRenewed() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.rotated, wire: wire, protected: Self.stream)

            let seen = try await lines(session, chat())

            #expect(seen.count == 2)
            #expect(seen.first?.contains("Hallo") == true)
            #expect(session.signOuts.value == 0)
            #expect(wire.all == [
                .init(path: Self.chatPath, bearer: RVSession.oldBearer),
                .init(path: RVServer.refreshPath, bearer: RVSession.oldBearer),
                .init(path: Self.chatPath, bearer: RVSession.newBearer)
            ])
        }

        @Test("a dead refresh token ends the turn and signs out")
        func deadTokenSignsOut() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.deadToken, wire: wire, protected: Self.stream)

            await #expect(throws: HLError.unauthorized) { _ = try await lines(session, chat()) }

            #expect(session.signOuts.value >= 1)
            #expect(wire.all.count(where: { $0.path == Self.chatPath }) == 1)
        }

        @Test("a refresh that fails for another reason ends the turn and keeps the session")
        func failedRefreshKeepsTheSession() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.status(503), wire: wire, protected: Self.stream)

            await #expect(throws: HLError.unauthorized) { _ = try await lines(session, chat()) }

            #expect(session.stillSignedIn)
        }

        @Test("a second 401 after the refresh ends the turn without a second refresh")
        func secondUnauthorizedGivesUp() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(
                refresh: RVServer.rotated,
                wire: wire,
                protected: { RVServer.reply($0, 401, #"{"data":null,"error":"Unauthorized"}"#) }
            )

            await #expect(throws: HLError.unauthorized) { _ = try await lines(session, chat()) }

            #expect(wire.all.count(where: { $0.path == RVServer.refreshPath }) == 1)
            #expect(wire.all.count(where: { $0.path == Self.chatPath }) == 2)
        }

        @Test("a request pinned to its own credential is neither refreshed nor signed out")
        func pinnedRequestIsLeftAlone() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: RVServer.rotated, wire: wire, protected: Self.stream)

            await #expect(throws: HLError.unauthorized) { _ = try await lines(session, chat(recovers: false)) }

            #expect(session.stillSignedIn)
            #expect(wire.all == [.init(path: Self.chatPath, bearer: RVSession.oldBearer)])
        }
    }

#endif

// swiftlint:enable force_unwrapping
