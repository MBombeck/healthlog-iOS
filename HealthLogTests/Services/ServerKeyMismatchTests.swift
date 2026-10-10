import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// Server v1.40: a server whose encryption key does not
/// match its data answers `503` with `meta.errorCode: "encryption.key_mismatch"`
/// on every route except `/api/health` and `/api/version`; `/api/health`
/// answers `503 { status: "degraded", reason: "encryption_key_mismatch" }`.
///
/// Shapes from `MBombeck/HealthLog` `release/v1.42.0` (`402c50378`):
/// `src/lib/__tests__/api-handler-key-mismatch.test.ts` (body
/// `{ data: null, meta: { errorCode } }`, `Retry-After: 300`) and
/// `src/app/api/health/__tests__/route.test.ts`; `HealthReason` in
/// `docs/api/openapi.yaml`.
///
/// Before this build the app read it as any 503: "Server error. We're looking
/// into it.", three in-request retries per call, and an outbox pass that sent
/// every queued row into the same refusal.
@Suite("503 encryption.key_mismatch (server v1.40)", .serialized, .mockURLSession)
struct ServerKeyMismatchTests {
    static let owner = "account-km"

    static let keyMismatchBody = Data(#"{"data":null,"error":"Service unavailable","meta":{"errorCode":"encryption.key_mismatch"}}"#.utf8)

    static let mismatch = HLError.server(status: 503, code: "encryption.key_mismatch", message: "Service unavailable")

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data) -> (HTTPURLResponse, Data?) {
        let headers = ["Content-Type": "application/json", "Retry-After": "300"]
        return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
    }

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.2.0",
            buildNumber: "300"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-km", forKey: KeychainKey.authToken)
        try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    // MARK: - The error itself

    @Test("it reads as a server configuration problem, not as an outage or offline")
    func userFacingCopy() {
        let text = Self.mismatch.userFacingDescription
        #expect(text == String(localized: "error.server.keyMismatch"))
        #expect(text != HLError.server(status: 503, code: nil, message: "x").userFacingDescription)
        #expect(text != HLError.offline.userFacingDescription)
        #expect(Self.mismatch.localizedDescription == text)
        #expect(Self.mismatch.isServerKeyMismatch)
        #expect(!HLError.server(status: 503, code: nil, message: "x").isServerKeyMismatch)
        #expect(!HLError.server(status: 500, code: "encryption.key_mismatch", message: "x").isServerKeyMismatch)
    }

    @Test("it is not retried in the request, but a write is kept for later")
    func retryAndPersistence() {
        #expect(!Self.mismatch.isRetriable)
        #expect(Self.mismatch.shouldPersistToOutbox)
        // Any other 503 keeps its retry.
        #expect(HLError.server(status: 503, code: nil, message: "x").isRetriable)
    }

    @Test("the manual sync button shows the same sentence")
    func manualSync() {
        #expect(ManualSyncState.classify(Self.mismatch) == .failed(String(localized: "error.server.keyMismatch")))
    }

    // MARK: - APIClient

    @Test("APIClient answers at once instead of spinning its 5xx backoff")
    func noInRequestRetry() async {
        let api = makeAPI()
        let attempts = Mutex(0)
        MockURLProtocol.install { req in
            attempts.withLock { $0 += 1 }
            return Self.reply(req, 503, Self.keyMismatchBody)
        }
        let req = APIRequest<EmptyPayload>(method: .get, path: "/api/measurements", maxRetries: 2)
        do {
            _ = try await api.send(req)
            Issue.record("expected the key mismatch to throw")
        } catch let error as HLError {
            #expect(error == Self.mismatch)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    // MARK: - Health probe

    @Test("the health probe names the mismatch apart from a plain outage")
    func healthProbe() {
        let mismatch = APIClient.healthOutcome(
            data: Data(#"{"status":"degraded","reason":"encryption_key_mismatch"}"#.utf8),
            statusCode: 503
        )
        #expect(mismatch.reachable)
        #expect(mismatch.degraded)
        #expect(mismatch.serverKeyMismatch)

        let outage = APIClient.healthOutcome(data: Data(#"{"status":"degraded"}"#.utf8), statusCode: 503)
        #expect(outage.degraded)
        #expect(!outage.serverKeyMismatch)

        // `ENCRYPTION_KEY_CHECK=warn`: the server stays ok and only warns.
        let warned = APIClient.healthOutcome(
            data: Data(#"{"status":"ok","warning":"encryption_key_mismatch"}"#.utf8),
            statusCode: 200
        )
        #expect(!warned.degraded)
        #expect(!warned.serverKeyMismatch)
    }

    // MARK: - Outbox replay

    static let allergyCreated = Data(#"""
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """#.utf8)

    private func enqueueAllergy(_ outbox: OutboxQueue, _ substance: String) async throws {
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: substance, category: .medication))
            ),
            idempotencyKey: "km-\(substance)",
            clientEntityId: "optimistic-\(substance)"
        ))
    }

    @Test("the outbox holds the whole queue, counts nothing, and resumes once the key is fixed")
    func outboxHolds() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await enqueueAllergy(outbox, "Penicillin")
        try await enqueueAllergy(outbox, "Latex")
        let requests = Mutex(0)
        let keyFixed = Mutex(false)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            if keyFixed.withLock({ $0 }) { return Self.reply(req, 201, Self.allergyCreated) }
            return Self.reply(req, 503, Self.keyMismatchBody)
        }
        let clock = KeyMismatchClock()
        let api = makeAPI()
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            currentUserProvider: { Self.owner },
            maxAttempts: 1,
            deadLetterMinAge: 0,
            attemptBackoff: 0,
            clock: { clock.now }
        )

        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1, "one request: no in-request retry, no second row into the same refusal")
        let rows = await outbox.snapshot
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.attempts == 0 }, "never the write's fault, so never counted")
        #expect(await outbox.deadLetterCount == 0, "a budget of one attempt would have dead-lettered a counted failure")

        clock.advance(by: 10 * 60)
        await replay.runOnce()
        #expect(requests.withLock { $0 } == 1, "inside the hold nothing is sent")

        clock.advance(by: 6 * 60)
        keyFixed.withLock { $0 = true }
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty, "after the hold the same rows go out")
    }
}

/// A pinned, advanceable clock for the replay.
private final class KeyMismatchClock: Sendable {
    private let value = Mutex(Date())
    var now: Date {
        value.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

// swiftlint:enable force_unwrapping
