import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Phase 07 / plan 07-05 — `MoodRepository.logDurable`.**
///
/// The shipped `log(...)` swallowed a failed outbox enqueue behind the transport
/// error it was already about to throw, so "we queued it" and "we dropped it"
/// reached the caller as one event — which is how the State-of-Mind anchor could
/// advance past a sample whose only durable copy never existed.
///
/// These drive the real `APIClient` over `MockURLProtocol` and a real
/// `OutboxQueue` (PROJECT_GUIDE.md — no mock server on the write paths).
@Suite("Mood durable write", .serialized)
struct MoodDurableWriteTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-abc", forKey: KeychainKey.authToken)
        try? keychain.setString("account-a", forKey: KeychainKey.userID)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func envelope(_ identity: String = "hk-mood-1") throws -> HealthSyncRetryEnvelope {
        try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: identity)
        )
    }

    private static let serverEntry = """
    {"id":"srv-mood-1","mood":"GUT","tags":[],"moodLoggedAt":"2026-05-01T10:00:00Z","source":"MANUAL","note":null}
    """

    @Test("A stored write is accepted and carries the server row")
    func acceptedWriteReturnsTheServerRow() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(Self.serverEntry.utf8)
            )
        }
        let repo = MoodRepository(api: api, outbox: outbox)

        let outcome = try await repo.logDurable(
            score: 4,
            tags: [],
            note: nil,
            recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
            retryIdentity: envelope()
        )

        guard case let .accepted(entry) = outcome else {
            Issue.record("expected .accepted, got \(outcome)")
            return
        }
        #expect(entry.id == "srv-mood-1")
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("A retriable failure is queued under the DERIVED key, and says so")
    func retriableFailureQueuesUnderTheDerivedKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = MoodRepository(api: api, outbox: outbox)
        let identity = try envelope()

        let outcome = await repo.logDurable(
            score: 2,
            tags: [],
            note: nil,
            recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
            retryIdentity: identity
        )

        guard case let .queued(entry, transport) = outcome else {
            Issue.record("expected .queued, got \(outcome)")
            return
        }
        // `queued` is terminal for a cursor precisely because the row is there.
        #expect(outcome.isDurable)
        #expect(transport.shouldPersistToOutbox)
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.idempotencyKey == identity.idempotencyKey)
        #expect(snapshot.first?.kind == .logMood)
        // The optimistic local id is derived too, so the queued payload and a
        // relaunched attempt name the same row.
        #expect(entry.id == "local-" + identity.idempotencyKey)
    }

    @Test("The same HealthKit sample replays as the same operation after a relaunch")
    func derivedIdentityIsStableAcrossAttempts() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let identity = try envelope()

        // Two independent repositories over two independent queues: the second
        // stands in for the process that relaunched and re-read the same sample.
        var keys: [String] = []
        var localIDs: [String] = []
        for _ in 0 ..< 2 {
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MoodRepository(api: api, outbox: outbox)
            let outcome = await repo.logDurable(
                score: 3,
                tags: [],
                note: nil,
                recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
                retryIdentity: identity
            )
            guard case let .queued(entry, _) = outcome else {
                Issue.record("expected .queued, got \(outcome)")
                return
            }
            localIDs.append(entry.id)
            try keys.append(#require(await outbox.snapshot.first?.idempotencyKey))
        }

        #expect(Set(keys).count == 1, "a rebuilt envelope must produce one idempotency key")
        #expect(Set(localIDs).count == 1, "a rebuilt envelope must produce one optimistic local id")
    }

    @Test("A non-retriable refusal is rejected and never queued")
    func nonRetriableRefusalIsRejected() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Validation failed"}"#.utf8)
            )
        }
        let repo = MoodRepository(api: api, outbox: outbox)

        let outcome = try await repo.logDurable(
            score: 1,
            tags: [],
            note: nil,
            recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
            retryIdentity: envelope()
        )

        guard case .rejected = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(!outcome.isDurable)
        #expect(await outbox.snapshot.isEmpty, "a refusal a retry cannot fix must not occupy the queue")
    }

    @Test("A manual write without a stable identity still mints one, per attempt")
    func manualWriteMintsItsOwnIdentity() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        var ids: Set<String> = []
        for _ in 0 ..< 2 {
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MoodRepository(api: api, outbox: outbox)
            let outcome = await repo.logDurable(
                score: 5,
                tags: [],
                note: nil,
                recordedAt: nil,
                retryIdentity: nil
            )
            guard case let .queued(entry, _) = outcome else {
                Issue.record("expected .queued, got \(outcome)")
                return
            }
            ids.insert(entry.id)
        }
        // A hand-typed mood has no external identity to derive from, and the
        // queued payload carries the minted one — which is what makes the
        // *replay* stable even though a second capture is a second entry.
        #expect(ids.count == 2)
    }

    @Test("log(...) still throws the transport error the UI contract expects")
    func logProjectsTheDurableOutcome() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = MoodRepository(api: api, outbox: outbox)

        await #expect(throws: HLError.self) {
            _ = try await repo.log(score: 3, tags: [], note: nil)
        }
        #expect(await outbox.snapshot.count == 1, "the throw must not have skipped the durable write")
    }
}

// swiftlint:enable force_unwrapping
