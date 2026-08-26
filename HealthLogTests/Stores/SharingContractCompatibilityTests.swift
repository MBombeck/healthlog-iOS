import Foundation
@testable import HealthLog
import Testing

#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

// swiftlint:disable force_unwrapping

@Suite("Server v1.37 sharing compatibility", .serialized)
struct SharingContractCompatibilityTests {
    @Test("pinned /auth/me fixture decodes shared and managed access without widening")
    func pinnedFixtureDecodes() throws {
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<User>.self, from: Self.loadPinnedFixture())
        let user = try #require(envelope.data)
        let accounts = user.accountAccess.accounts

        #expect(user.accountAccessStatus == .valid)
        #expect(accounts.map(\.recordKind) == [.shared, .managed])
        #expect(accounts.map(\.level) == [.read, .manage])
        #expect(accounts[0].sections == .all)
        #expect(accounts[0].allows(section: .measurements, write: false))
        #expect(accounts[0].allows(section: .measurements, write: true) == false)
        #expect(accounts[1].sections == .none)
        #expect(accounts[1].allows(section: .profile, write: false) == false)
        #expect(accounts[1].fullName == "Fixture Person")
        #expect(accounts[1].canWrite)
        #expect(user.recordSession == nil, "native Bearer transport has no record-session fence")
    }

    @Test("sections distinguish all, none, subset and missing")
    func sectionSemanticsRemainDistinct() throws {
        let entries = try Self.decodeEntries(#"""
        [
          {"accountId":"all","username":"all","access":"read","level":"read",
           "recordKind":"shared","sections":null,"canWrite":false},
          {"accountId":"none","username":"none","access":"read","level":"read",
           "recordKind":"shared","sections":[],"canWrite":false},
          {"accountId":"subset","username":"subset","access":"write","level":"write",
           "recordKind":"shared","sections":["measurements","labs"],"canWrite":true},
          {"accountId":"missing","username":"missing","access":"write","level":"write",
           "recordKind":"shared","canWrite":true}
        ]
        """#)

        #expect(entries.map(\.sections) == [.all, .none, .subset([.measurements, .labs]), .unavailable])
        #expect(entries[2].allows(section: .measurements, write: true))
        #expect(entries[2].allows(section: .cycle, write: false) == false)
        #expect(entries[3].allows(section: .measurements, write: false) == false)
    }

    @Test("missing sharing block preserves legacy owner behavior; malformed and unknown stay refused")
    func missingAndUnknownFailClosed() throws {
        let legacy = try JSONDecoder.hlDefault.decode(User.self, from: Data(#"{"id":"owner"}"#.utf8))
        let unknown = try Self.decodeEntries(#"""
        [{"accountId":"future","username":"future","access":"write","level":"admin",
          "recordKind":"future-kind","sections":["future-section"],"canWrite":true}]
        """#).first
        let malformed = try JSONDecoder.hlDefault.decode(User.self, from: Data(#"""
        {"id":"owner","accountAccess":null}
        """#.utf8))

        #expect(legacy.accountAccessStatus == .absent)
        #expect(legacy.accountAccess == .ownerOnly)
        #expect(malformed.accountAccessStatus == .invalid)
        #expect(malformed.accountAccess == .ownerOnly)
        #expect(unknown?.level == .unknown)
        #expect(unknown?.recordKind == .unknown)
        #expect(unknown?.sections == .unavailable)
        #expect(unknown?.canWrite == false)
        #expect(unknown?.allows(section: .measurements, write: false) == false)
    }

    @Test("selected account header is applied only to admitted record surfaces")
    func selectedHeaderIsSurfaceScoped() async throws {
        let (api, entry) = try Self.makeSelectedAPI()
        let spy = RequestSpy()
        MockURLProtocol.handler = { request in
            spy.record(request)
            let body = request.url?.path == "/api/auth/me"
                ? #"{"data":{"id":"owner"},"error":null}"#
                : #"{"data":{},"error":null}"#
            return Self.response(request, status: 200, body: body)
        }

        await api.selectAccount(entry)
        let measurement: APIRequest<EmptyPayload> = .get("/api/measurements")
        _ = try await api.send(measurement)
        let authMe: APIRequest<User> = .get("/api/auth/me")
        _ = try await api.send(authMe)

        #expect(spy.header(named: "X-HealthLog-Account", at: 0) == "fixture-record")
        #expect(spy.header(named: "X-HealthLog-Account", at: 1) == nil)
        let selectedAccountID = await api.selectedAccountID()
        #expect(selectedAccountID == "fixture-record")
    }

    @Test("grant loss clears selection and caches, reconciles auth, and never retries mutation as owner")
    @MainActor
    func grantLossRecovery() async throws {
        let (api, entry) = try Self.makeSelectedAPI()
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
        let store = AuthStore(auth: auth, keychain: keychain)
        store.setPhaseForTesting(.authenticated(User(id: "owner", email: nil, username: nil, displayName: nil)))
        let cleanup = AsyncCountSpy()
        store.sharingScopeCleanupHook = { await cleanup.increment() }
        api.setSharingRecoveryHandler { event in
            await store.handleSharingRecovery(event)
        }

        let requests = RequestSpy()
        MockURLProtocol.handler = { request in
            requests.record(request)
            if request.url?.path == "/api/auth/me" {
                return Self.response(request, status: 200, body: #"{"data":{"id":"owner"},"error":null}"#)
            }
            return Self.response(
                request,
                status: 403,
                body: #"{"data":null,"error":"Account access denied","meta":{"errorCode":"sharing.access.denied"}}"#
            )
        }

        await api.selectAccount(entry)
        let mutation = APIRequest<EmptyPayload>(method: .post, path: "/api/measurements", body: Data("{}".utf8))
        do {
            try await api.sendVoid(mutation)
            Issue.record("expected sharing denial")
        } catch let error as HLError {
            #expect(error == .server(status: 403, code: "sharing.access.denied", message: "Account access denied"))
        }

        #expect(requests.count(path: "/api/measurements") == 1)
        #expect(requests.header(named: "X-HealthLog-Account", path: "/api/measurements") == "fixture-record")
        #expect(requests.count(path: "/api/auth/me") == 1)
        #expect(requests.header(named: "X-HealthLog-Account", path: "/api/auth/me") == nil)
        let selectedAccountID = await api.selectedAccountID()
        let cleanupCount = await cleanup.value
        #expect(selectedAccountID == nil)
        #expect(cleanupCount == 1)
        guard case let .authenticated(user) = store.phase else {
            Issue.record("grant loss must preserve authentication")
            return
        }
        #expect(user.id == "owner")
    }

    @Test("session change reconciles once and retries a read with the same selected account")
    func sessionChangeRecoveryIsBounded() async throws {
        let (api, entry) = try Self.makeSelectedAPI()
        let requests = RequestSpy()
        MockURLProtocol.handler = { request in
            requests.record(request)
            if request.url?.path == "/api/auth/me" {
                return Self.response(request, status: 200, body: #"{"data":{"id":"owner"},"error":null}"#)
            }
            if requests.count(path: "/api/measurements") == 1 {
                return Self.response(
                    request,
                    status: 409,
                    body: #"{"data":null,"error":"Record session changed","meta":{"errorCode":"sharing.session.changed"}}"#
                )
            }
            return Self.response(request, status: 200, body: #"{"data":{},"error":null}"#)
        }

        await api.selectAccount(entry)
        let read: APIRequest<EmptyPayload> = .get("/api/measurements")
        _ = try await api.send(read)

        #expect(requests.count(path: "/api/measurements") == 2)
        #expect(requests.headers(named: "X-HealthLog-Account", path: "/api/measurements") == [
            "fixture-record", "fixture-record"
        ])
        #expect(requests.count(path: "/api/auth/me") == 1)
        let selectedAccountID = await api.selectedAccountID()
        #expect(selectedAccountID == "fixture-record")
    }

    private static func makeSelectedAPI() throws -> (APIClient, AccountAccessEntry) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.19.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let entry = try #require(try decodeEntries(#"""
        [{"accountId":"fixture-record","username":"fixture","access":"write","level":"write",
          "recordKind":"shared","sections":["measurements"],"canWrite":true}]
        """#).first)
        return (api, entry)
    }

    private static func decodeEntries(_ json: String) throws -> [AccountAccessEntry] {
        try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(json.utf8))
    }

    private static func loadPinnedFixture(file: String = #filePath) throws -> Data {
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Stores
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
        return try Data(contentsOf: repoRoot.appendingPathComponent(
            "HealthLogTests/Fixtures/Server/v1.37.3/auth-me-sharing.json"
        ))
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }
}

private final class RequestSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func count(path: String) -> Int {
        lock.withLock { requests.count(where: { $0.url?.path == path }) }
    }

    func header(named name: String, at index: Int) -> String? {
        lock.withLock { requests[index].value(forHTTPHeaderField: name) }
    }

    func header(named name: String, path: String) -> String? {
        lock.withLock { requests.first(where: { $0.url?.path == path })?.value(forHTTPHeaderField: name) }
    }

    func headers(named name: String, path: String) -> [String] {
        lock.withLock {
            requests
                .filter { $0.url?.path == path }
                .compactMap { $0.value(forHTTPHeaderField: name) }
        }
    }
}

private actor AsyncCountSpy {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
    func register(
        challenge _: String,
        rpId _: String,
        rpName _: String,
        userID _: String,
        userName _: String,
        displayName _: String,
        anchor _: ASPresentationAnchorProvider
    ) async throws -> PasskeyRegistration {
        throw HLError.canceled
    }

    func assert(
        challenge _: String,
        rpId _: String,
        allowCredentialIDs _: [String],
        anchor _: ASPresentationAnchorProvider
    ) async throws -> PasskeyAssertion {
        throw HLError.canceled
    }
}

// swiftlint:enable force_unwrapping
