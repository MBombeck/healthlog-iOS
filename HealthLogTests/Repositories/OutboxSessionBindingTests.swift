import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// #2 and #6 — the replay and the session its rows go out under.
///
/// Real `APIClient` over `MockURLProtocol`. Account A queues writes, signs out,
/// and account B signs in while a pass still works through A's rows (here:
/// while it sits out a 429 pause). No row of A may reach the server with B's
/// bearer, neither from the pass nor from `APIClient`'s rotated-bearer retry.
/// And a failure that is about the session only never costs a row an attempt.
@Suite("Outbox replay — rows stay with their account (#2, #6)", .serialized, .mockURLSession)
struct OutboxSessionBindingTests {
    static let ownerA = "account-a"
    static let ownerB = "account-b"

    static let recordWriteRefusal = Data(#"""
    {"data":null,"error":"Too many writes, try again later","meta":{"errorCode":"record_write.rate_limited"}}
    """#.utf8)

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data, headers: [String: String] = [:]) -> (HTTPURLResponse, Data?) {
        var fields = ["Content-Type": "application/json"]
        fields.merge(headers) { _, new in new }
        return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!, body)
    }

    /// The signed-in session, switchable mid-test like a sign-out of A and a
    /// sign-in of B.
    final class Session: Sendable {
        let keychain = InMemoryKeychain()

        init(owner: String, bearer: String) {
            signIn(owner: owner, bearer: bearer)
        }

        func signIn(owner: String, bearer: String) {
            try? keychain.setString(bearer, forKey: KeychainKey.authToken)
            try? keychain.setString(owner, forKey: KeychainKey.userID)
        }

        var owner: String? {
            keychain.getString(forKey: KeychainKey.userID)
        }
    }

    private static func makeAPI(_ session: Session) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: session.keychain, sessionConfiguration: .mock())
    }

    private static func makeReplay(
        _ outbox: OutboxQueue,
        _ session: Session,
        sessionGate: OutboxReplaySessionGate? = nil
    ) -> OutboxReplayService {
        let api = makeAPI(session)
        return OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            currentUserProvider: { session.owner },
            attemptBackoff: 0,
            sessionGate: sessionGate
        )
    }

    private static func enqueueAllergy(_ outbox: OutboxQueue, owner: String, _ substance: String) async throws {
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: substance, category: .medication))
            ),
            idempotencyKey: "binding-\(substance)",
            ownerUserID: owner,
            clientEntityId: "optimistic-\(substance)"
        ))
    }

    // MARK: - #2

    @Test("an account switch during a 429 pause stops the row of A from going out under B's bearer")
    func switchDuringPauseKeepsTheRow() async throws {
        let session = Session(owner: Self.ownerA, bearer: "bearer-a")
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { session.owner })
        try await Self.enqueueAllergy(outbox, owner: Self.ownerA, "Penicillin")
        let bearers = Mutex<[String]>([])
        MockURLProtocol.install { req in
            bearers.withLock { $0.append(req.value(forHTTPHeaderField: "Authorization") ?? "") }
            return Self.reply(req, 429, Self.recordWriteRefusal, headers: ["Retry-After": "1"])
        }
        // The pause is where B signs in.
        let sleeper: @Sendable (TimeInterval) async throws -> Void = { _ in
            session.signIn(owner: Self.ownerB, bearer: "bearer-b")
        }

        await OutboxReplayPause.$sleep.withValue(sleeper) {
            await Self.makeReplay(outbox, session).runOnce()
        }

        let sent = bearers.withLock { $0 }
        #expect(!sent.isEmpty)
        #expect(!sent.contains("Bearer bearer-b"), "A's row must never carry B's bearer")
        let row = try #require(await outbox.snapshot.first)
        #expect(row.ownerUserID == Self.ownerA, "the row stays queued for its owner")
        #expect(row.attempts == 0, "a session change costs no attempt")
    }

    @Test("a request bound to A is not built while B is signed in")
    func boundRequestRefusesAnotherAccount() async throws {
        let session = Session(owner: Self.ownerB, bearer: "bearer-b")
        let api = Self.makeAPI(session)
        let request: APIRequest<EmptyPayload> = .get("/api/medications")
        await #expect(throws: HLError.authenticatedSessionChanged) {
            try await RequestOwnerBinding.$owner.withValue(Self.ownerA) {
                _ = try await api.buildURLRequest(request)
            }
        }
        // The same account, and nobody bound, both build.
        _ = try await RequestOwnerBinding.$owner.withValue(Self.ownerB) { try await api.buildURLRequest(request) }
        _ = try await api.buildURLRequest(request)
    }

    @Test("a 401 for A's bearer is not re-sent with B's after an account switch on the wire")
    func rotatedBearerRetryStaysWithTheAccount() async throws {
        let session = Session(owner: Self.ownerA, bearer: "bearer-a")
        let api = Self.makeAPI(session)
        let bearers = Mutex<[String]>([])
        MockURLProtocol.install { req in
            let count = bearers.withLock { list in
                list.append(req.value(forHTTPHeaderField: "Authorization") ?? "")
                return list.count
            }
            // While A's request is on the wire, A signs out and B signs in.
            if count == 1 { session.signIn(owner: Self.ownerB, bearer: "bearer-b") }
            return Self.reply(req, 401, Data(#"{"data":null,"error":"Unauthorized"}"#.utf8))
        }

        await #expect(throws: HLError.unauthorized) {
            try await api.sendVoid(.post("/api/allergies", body: ["substance": "Latex"], idempotencyKey: IdempotencyKey()))
        }
        #expect(bearers.withLock { $0 } == ["Bearer bearer-a"], "one request, with A's bearer only")
    }

    // MARK: - #6

    @Test("a 401 in the replay stamps the row and keeps its attempt budget")
    func unauthorizedIsNotCounted() async throws {
        let session = Session(owner: Self.ownerA, bearer: "bearer-a")
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { session.owner })
        try await Self.enqueueAllergy(outbox, owner: Self.ownerA, "Latex")
        MockURLProtocol.install { req in
            Self.reply(req, 401, Data(#"{"data":null,"error":"Unauthorized"}"#.utf8))
        }

        await Self.makeReplay(outbox, session).runOnce()

        let row = try #require(await outbox.snapshot.first)
        #expect(row.attempts == 0, "a 401 says nothing about the write")
        #expect(row.lastAttemptAt != nil, "the back-off still applies")
        #expect(await outbox.deadLetterCount == 0)
    }

    @Test("without a stored bearer the pass sends nothing")
    func noSessionNoPass() async throws {
        let session = Session(owner: Self.ownerA, bearer: "bearer-a")
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { session.owner })
        try await Self.enqueueAllergy(outbox, owner: Self.ownerA, "Latex")
        let requests = Mutex(0)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            return Self.reply(req, 401, Data())
        }
        let signedOut = InMemoryKeychain()
        let gate = OutboxReplaySessionGate.live(keychain: signedOut, refresh: {})

        await Self.makeReplay(outbox, session, sessionGate: gate).runOnce()

        #expect(requests.withLock { $0 } == 0)
        let row = try #require(await outbox.snapshot.first)
        #expect(row.attempts == 0 && row.lastAttemptAt == nil, "the row is untouched")
    }

    @Test("an access token past its expiry is renewed before the pass")
    func expiredTokenIsRenewedFirst() async {
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-a", forKey: KeychainKey.authToken)
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        try? keychain.setString(past, forKey: KeychainKey.accessTokenExpiresAt)
        let refreshed = Mutex(0)
        let gate = OutboxReplaySessionGate.live(keychain: keychain) { refreshed.withLock { $0 += 1 } }

        #expect(await gate.admitsPass())
        #expect(refreshed.withLock { $0 } == 1)

        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try? keychain.setString(future, forKey: KeychainKey.accessTokenExpiresAt)
        #expect(await gate.admitsPass())
        #expect(refreshed.withLock { $0 } == 1, "a valid token is not renewed")
    }

    @Test("a sign-in gives the account's own rows their attempt budget back, and only those")
    func signInResetsOwnAttempts() async throws {
        let session = Session(owner: Self.ownerA, bearer: "bearer-a")
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { session.owner })
        try await Self.enqueueAllergy(outbox, owner: Self.ownerA, "Mine")
        try await Self.enqueueAllergy(outbox, owner: Self.ownerB, "Theirs")
        for row in await outbox.snapshot {
            for _ in 0 ..< 8 {
                try await outbox.incrementAttempts(id: row.id, lastError: "401")
            }
        }

        let reset = try await outbox.resetAttempts(ownedBy: Self.ownerA)

        #expect(reset == 1)
        let rows = await outbox.snapshot
        #expect(rows.first { $0.ownerUserID == Self.ownerA }?.attempts == 0)
        #expect(rows.first { $0.ownerUserID == Self.ownerB }?.attempts == 8)
    }
}

// swiftlint:enable force_unwrapping
