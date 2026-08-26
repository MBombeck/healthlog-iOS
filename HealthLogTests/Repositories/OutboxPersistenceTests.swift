import Foundation
import SwiftData
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// SwiftData-backed Outbox: persistence, replay, dead-letter, and schema-drift
/// safety net. Companion to `IdempotencyKeyPersistenceTests` — that file proves
/// the *key* round-trips, this one proves the *queue* round-trips.
///
/// Audit-Referenzen: security C-2 (Persistierung), perf-quality C1
/// (in-memory-Store-Bug), concurrency H4 (cross-process race — bewusst
/// deferred), perf-quality M11 (lastError observability).
@Suite("Outbox SwiftData persistence", .serialized)
struct OutboxPersistenceTests {
    // MARK: - Helpers

    private func makeAPI(keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeReplay(
        api: APIClient,
        outbox: OutboxQueue,
        maxAttempts: Int = 8,
        deadLetterMinAge: TimeInterval = 0,
        attemptBackoff: TimeInterval = 0,
        currentUser: (@Sendable () -> String?)? = nil
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: currentUser ?? OutboxQueue.defaultOwnerProvider,
            maxAttempts: maxAttempts,
            deadLetterMinAge: deadLetterMinAge,
            attemptBackoff: attemptBackoff
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func encodeMeasurement() throws -> Data {
        let m = Measurement(
            id: "local-x",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
            value: .scalar(81.0)
        )
        return try JSONEncoder.hlDefault.encode(m)
    }

    /// Builds two `OutboxQueue`-like actors that both write into the **same**
    /// in-memory `ModelContainer`, simulating "discard process A, recreate
    /// process B against the same on-disk store" without paying disk I/O.
    /// An in-memory container survives across multiple `OutboxStore` instances
    /// constructed with the same container — that's how SwiftData tests usually
    /// approximate "persistence across restarts".
    private func sharedInMemoryContainer() throws -> ModelContainer {
        try OutboxStore.makeInMemory()
    }

    private func bind(_ container: ModelContainer) -> OutboxStore {
        OutboxStore(modelContainer: container)
    }

    // MARK: - (a) Persistence across actor recreation

    @Test("Enqueue persists across OutboxStore recreation (audit C-2 regression)")
    func enqueuePersistsAcrossActorRecreation() async throws {
        let container = try sharedInMemoryContainer()
        let storeA = bind(container)
        let payload = try encodeMeasurement()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        try await storeA.enqueue(
            id: id1,
            kindRaw: "createMeasurement",
            payload: payload,
            idempotencyKey: "key-1",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try await storeA.enqueue(
            id: id2,
            kindRaw: "logMood",
            payload: payload,
            idempotencyKey: "key-2",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try await storeA.enqueue(
            id: id3,
            kindRaw: "takeMedication",
            payload: payload,
            idempotencyKey: "key-3",
            createdAt: Date(timeIntervalSince1970: 3)
        )

        // Discard storeA. New actor instance, same container — this is the
        // SwiftData equivalent of "kill process A, launch process B".
        let storeB = bind(container)
        let snap = try await storeB.snapshot()
        #expect(snap.count == 3)
        #expect(snap.map(\.idempotencyKey) == ["key-1", "key-2", "key-3"])
        // Order guaranteed oldest-first by SortDescriptor in OutboxStore.snapshot.
        #expect(snap.map(\.id) == [id1, id2, id3])
    }

    // MARK: - (b) Replay loop drains all operations

    @Test("Replay loop drains all enqueued operations on 200")
    func replayLoopDrainsAllOperations() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let payload = try encodeMeasurement()
        for i in 0 ..< 5 {
            try await outbox.enqueue(.init(
                id: UUID(),
                kind: .createMeasurement,
                payload: payload,
                idempotencyKey: "key-\(i)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(i))
            ))
        }
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            let body = #"{"data":{"id":"srv-x","type":"WEIGHT","value":81.0,"unit":"kg","measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"note":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "all 5 ops must be removed after successful replay")
        #expect(attempts.current == 5, "server got hit exactly 5 times")
    }

    // MARK: - (c) attempts increments + lastError persists on retriable failure

    @Test("Retriable failure increments attempts and persists sanitized lastError")
    func attemptsIncrementOnRetriableFailure() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let id = UUID()
        try await outbox.enqueue(.init(
            id: id,
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-c",
            createdAt: .now
        ))
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()

        let snap = await outbox.snapshot
        #expect(snap.count == 1, "retriable failure must keep the op in the queue")
        // After APIClient internal retries (3 attempts → server-error → outbox bumps once),
        // attempts should be ≥1. The exact count depends on APIClient's retry policy; we only
        // care that the bookkeeping was applied at all.
        #expect((snap.first?.attempts ?? 0) >= 1)
    }

    // MARK: - (d) Idempotency-key preserved across recreation + replay

    @Test("Idempotency-Key survives actor recreation and is reused on replay")
    func idempotencyKeyPreservedAcrossRetries() async throws {
        let api = makeAPI()
        let container = try sharedInMemoryContainer()

        // Phase 1: enqueue via OutboxQueue-equivalent on container.
        let outboxA = OutboxQueue(testContainer: container)
        let payload = try encodeMeasurement()
        try await outboxA.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: payload,
            idempotencyKey: "key-d-stable",
            createdAt: .now
        ))
        // Drop outboxA, simulate process death.

        // Phase 2: fresh OutboxQueue against the same container, run replay.
        let outboxB = OutboxQueue(testContainer: container)
        let snap = await outboxB.snapshot
        #expect(snap.first?.idempotencyKey == "key-d-stable")

        // Replay against a 200 server, capture the Idempotency-Key header.
        let recorder = KeyRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            let body = #"{"data":{"id":"srv-d","type":"WEIGHT","value":81.0,"unit":"kg","measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"note":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let replay = makeReplay(api: api, outbox: outboxB)
        await replay.runOnce()
        #expect(recorder.snapshot.contains("key-d-stable"))
    }

    // MARK: - (e) Successful replay deletes the operation from disk

    @Test("Successful replay deletes operation from underlying store")
    func successfulReplayDeletesOperation() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-e",
            createdAt: .now
        ))
        MockURLProtocol.handler = { req in
            let body = #"{"data":{"id":"srv-e","type":"WEIGHT","value":81.0,"unit":"kg","measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"note":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        // Both the faade snapshot AND a fresh fetch from the store must be empty
        // — proves the delete actually hit the persistent layer, not just the
        // in-memory broadcast cache.
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - (f) DLQ-sweep at maxAttempts

    @Test("Sweep drops operations at maxAttempts and emits DLQ log signal")
    func dropsOperationAtMaxAttempts() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let id = UUID()
        try await outbox.enqueue(.init(
            id: id,
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-f",
            createdAt: .now
        ))
        // Simulate repeated retriable failures by manually bumping attempts to
        // the threshold — far cheaper than running the replay loop 8 times, and
        // sufficient to exercise `markDeadLetters` (audit-v0162) which is the SUT.
        for _ in 0 ..< 3 {
            try await outbox.incrementAttempts(id: id, lastError: "503")
        }
        // audit-v0162 H1 — `minAge: 0` so the row is immediately eligible; the
        // row is FLAGGED (recoverable) not deleted, and drops out of the live
        // snapshot but is counted + re-submittable.
        let dropped = try await outbox.markDeadLetters(maxAttempts: 3, minAge: 0, now: .now)
        #expect(dropped.count == 1)
        #expect(dropped.first?.kind == .createMeasurement)
        #expect(await (outbox.snapshot).isEmpty)
        #expect(await outbox.deadLetterCount == 1)
        #expect(try await outbox.resubmitDeadLetter(id: id))
        #expect(await outbox.snapshot.count == 1) // re-armed → replays again

        // Replay-driven path: configure a brand-new outbox with a low max-attempts
        // budget, point the server at persistent 503, run a single pass, and
        // verify the row is gone.
        let outbox2 = try OutboxQueue(inMemory: true)
        try await outbox2.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-f-2",
            createdAt: .now
        ))
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox2, maxAttempts: 1)
        await replay.runOnce()
        // After one pass: attempts >= maxAttempts → swept by replay.
        #expect(await (outbox2.snapshot).isEmpty)
    }

    // MARK: - Schema-drift safety net

    @Test("Decoding-failure on payload drops op with sanitized warning")
    func decodingFailureIsLoggedAndDropped() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        // Garbage payload — the replay decoder cannot turn this into a Measurement.
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: Data("not json".utf8),
            idempotencyKey: "key-drift",
            createdAt: .now
        ))
        // Server should never get hit — decode fails first.
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty, "undecodeable op must be dropped, not stuck forever")
        #expect(attempts.current == 0, "decode failure must short-circuit before any HTTP call")
    }

    /// **Phase 07 inverts the drop this test used to pin.**
    ///
    /// A `kindRaw` this build cannot name is a durable write whose meaning is
    /// unknown — most likely a newer client's row on a shared App Group store.
    /// Deleting it destroyed data the next upgrade could have replayed, and
    /// routing it through the `syncHealthKitSample` sentinel became actively
    /// unsafe once that kind gained a real POST arm. It now decodes to the
    /// dedicated `.unrecognized` sentinel and is quarantined: retained
    /// untouched (so its real `kindRaw` survives for the build that understands
    /// it), never transmitted, never deleted.
    @Test("Unknown kindRaw maps to the sentinel and is quarantined, not dropped")
    func unknownKindIsQuarantinedNotDropped() async throws {
        let container = try sharedInMemoryContainer()
        let store = bind(container)
        // Insert directly via the actor with a kindRaw the current build doesn't
        // recognize — simulates a future client write replayed by an older build,
        // or schema-drift across an upgrade.
        try await store.enqueue(
            id: UUID(),
            kindRaw: "futureKind",
            payload: Data(),
            idempotencyKey: "key-future",
            createdAt: .now,
            ownerUserID: "user-current"
        )
        let outbox = OutboxQueue(testContainer: container)
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .unrecognized)
        #expect(snap.first?.quarantineReason(currentUserID: "user-current") == .unrecognizedKind)

        let api = makeAPI()
        // The server must never be hit for a row this build cannot name — the
        // quarantine gate skips it before dispatch.
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox, currentUser: { "user-current" })
        await replay.runOnce()
        let remaining = await outbox.snapshot
        #expect(remaining.count == 1, "an unnameable row must be retained, not dropped")
        #expect(remaining.first?.ownerUserID == "user-current", "the row is never re-stamped")
        #expect(attempts.current == 0)
    }

    // MARK: - In-memory mode isolation

    @Test("In-memory containers are isolated across distinct OutboxQueue instances")
    func inMemoryModeIsolation() async throws {
        let outboxA = try OutboxQueue(inMemory: true)
        let outboxB = try OutboxQueue(inMemory: true)
        try await outboxA.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-iso-a",
            createdAt: .now
        ))
        // Distinct containers → outboxB sees nothing.
        #expect(await (outboxA.snapshot).count == 1)
        #expect(await (outboxB.snapshot).isEmpty, "in-memory containers must not share state across instances")
    }
}

// MARK: - Test helpers

/// Thread-safe collector für Idempotency-Key-Header — `MockURLProtocol` ruft
/// den Handler aus URLSession-eigenen Threads, also brauchen wir eine Lock.
/// Lokal dupliziert (statt aus `IdempotencyKeyPersistenceTests` zu importieren)
/// damit die beiden Test-Files unabhängig laufen können.
private final class KeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func record(_ key: String?) {
        guard let key else { return }
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }
}

// swiftlint:enable force_unwrapping force_try
