import Foundation

// swiftlint:disable force_unwrapping force_try
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Regression-Suite für Audit-Befund H-1 (Idempotency-Key-Persistierung).
///
/// Server keyed `(userId, key, method, path)` mit 24h TTL — wenn der Client pro
/// HTTP-Versuch einen **neuen** Key generiert, ist die Server-seitige Dedup
/// wirkungslos und Doppelschreibungen sind möglich. Diese Tests stellen sicher,
/// dass:
///
///   (a) APIClient-internes Retry (5xx) denselben Key auf allen Versuchen sendet,
///   (b) Outbox-Replay nach retriable Fehler denselben Key wie der Erstversuch nutzt,
///   (c) erfolgreicher Pfad genau einen Server-Hit erzeugt mit genau einem Key.
@Suite("Idempotency-Key persistence (H-1 regression)", .serialized)
struct IdempotencyKeyPersistenceTests {
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

    /// Thread-safe collector für Idempotency-Key-Header — `MockURLProtocol` ruft
    /// den Handler aus URLSession-eigenen Threads, also brauchen wir eine Lock.
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

    /// Thread-safe Int-Phase-Holder für Tests, die ihre Antwort während
    /// der Laufzeit umschalten müssen (Erstversuch fehl → Replay erfolgreich).
    /// Strict-Concurrency erlaubt kein `nonisolated(unsafe) var phase = 0` mehr,
    /// wenn der Wert später mutiert wird.
    private final class Phase: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ new: Int) {
            lock.lock()
            defer { lock.unlock() }
            value = new
        }
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
    }

    // MARK: - MeasurementsRepository

    @Test("Measurements: APIClient-internes 5xx-Retry behält denselben Idempotency-Key")
    func measurementsRetainsKeyAcrossInternalRetry() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            let n = attempts.increment()
            if n < 3 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            let body = #"{"data":{"id":"srv-1","type":"WEIGHT","value":80.5,"unit":"kg","measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"note":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let measurement = Measurement(
            id: "local-1",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
            value: .scalar(80.5)
        )
        _ = try await repo.create(measurement)

        let keys = recorder.snapshot
        #expect(keys.count == 3, "expected 3 attempts (initial + 2 retries), got \(keys.count)")
        #expect(Set(keys).count == 1, "all attempts must share the same Idempotency-Key, got \(keys)")
        await #expect(outbox.snapshot.isEmpty, "successful create must not enqueue to outbox")
    }

    @Test("Measurements: Outbox-Replay sendet denselben Key wie der Erstversuch")
    func measurementsOutboxReplayUsesOriginalKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let phase = Phase() // 0 = first call (always fails), 1 = replay (succeeds)
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            if phase.current == 0 {
                // Server-Fehler 503 → mapped to .server(503,...) → isRetriable
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            let body = #"{"data":{"id":"srv-2","type":"WEIGHT","value":80.5,"unit":"kg","measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"note":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let measurement = Measurement(
            id: "local-2",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
            value: .scalar(80.5)
        )

        // Erstversuch: alle Versuche schlagen fehl → Outbox bekommt Operation
        await #expect(throws: HLError.self) {
            _ = try await repo.create(measurement)
        }
        let queued = await outbox.snapshot
        #expect(queued.count == 1, "retriable failure must enqueue to outbox")
        let firstAttemptKeys = recorder.snapshot
        #expect(Set(firstAttemptKeys).count == 1, "all initial attempts must share one key, got \(firstAttemptKeys)")
        #expect(queued.first?.idempotencyKey == firstAttemptKeys.first, "outbox must persist the same key it was attempted with")

        // Replay-Phase: Server antwortet 200, Replay-Pipeline triggern.
        phase.set(1)
        let replayService = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: repo,
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            maxAttempts: 8
        )
        await replayService.runOnce()

        let allKeys = recorder.snapshot
        #expect(Set(allKeys).count == 1, "outbox replay must reuse the original Idempotency-Key, got \(allKeys)")
        await #expect(outbox.snapshot.isEmpty, "successful replay must remove the operation")
    }

    // MARK: - MoodRepository

    @Test("Mood: APIClient-internes 5xx-Retry behält denselben Idempotency-Key")
    func moodRetainsKeyAcrossInternalRetry() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            let n = attempts.increment()
            if n < 2 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            let body = #"{"data":{"id":"srv-mood-1","mood":"GUT","tags":[],"moodLoggedAt":"2026-05-01T10:00:00Z","source":"MANUAL"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        _ = try await repo.log(score: 4, tags: [], note: nil)

        let keys = recorder.snapshot
        #expect(keys.count == 2)
        #expect(Set(keys).count == 1, "Mood: alle Attempts müssen denselben Key tragen, got \(keys)")
    }

    @Test("Mood: Outbox-Replay sendet denselben Key wie der Erstversuch")
    func moodOutboxReplayUsesOriginalKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let phase = Phase()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            if phase.current == 0 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            let body = #"{"data":{"id":"srv-mood-2","mood":"GUT","tags":[],"moodLoggedAt":"2026-05-01T10:00:00Z","source":"MANUAL"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        await #expect(throws: HLError.self) {
            _ = try await repo.log(score: 4, tags: [], note: nil)
        }
        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        let originalKey = queued.first?.idempotencyKey
        #expect(originalKey != nil)

        phase.set(1)
        let replayService = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: repo,
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            maxAttempts: 8
        )
        await replayService.runOnce()

        let allKeys = recorder.snapshot
        #expect(Set(allKeys).count == 1, "Mood replay must reuse the original key, got \(allKeys)")
        #expect(try allKeys.contains(#require(originalKey)), "replay key must equal the persisted outbox key")
        await #expect(outbox.snapshot.isEmpty)
    }

    // MARK: - MedicationsRepository (H-1 primary regression — was missing key persistence entirely)

    @Test("Medications: APIClient-internes 5xx-Retry behält denselben Idempotency-Key")
    func medicationsRetainsKeyAcrossInternalRetry() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            let n = attempts.increment()
            if n < 3 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            // Server `POST /api/medications/intake` returns the raw Prisma row
            // (`scheduledFor` not `scheduledAt`, `skipped` flag, no synthesised
            // status). A4-Audit row 4 — locked in v0.4.0.
            let body = #"{"data":{"id":"intake-1","medicationId":"med-1","scheduledFor":"2026-05-01T08:00:00Z","takenAt":"2026-05-01T08:05:00Z","skipped":false,"snoozedUntil":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        _ = try await repo.record(intake: "intake-1", status: .taken, takenAt: Date(timeIntervalSince1970: 1_714_550_700))

        let keys = recorder.snapshot
        #expect(keys.count == 3)
        #expect(Set(keys).count == 1, "Medications: alle Attempts müssen denselben Key tragen, got \(keys)")
        await #expect(outbox.snapshot.isEmpty)
    }

    @Test("Medications: Outbox-Replay sendet denselben Key wie der Erstversuch")
    func medicationsOutboxReplayUsesOriginalKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let phase = Phase()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            if phase.current == 0 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            let body = #"{"data":{"id":"intake-2","medicationId":"med-1","scheduledFor":"2026-05-01T08:00:00Z","takenAt":"2026-05-01T08:05:00Z","skipped":false,"snoozedUntil":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        await #expect(throws: HLError.self) {
            _ = try await repo.record(intake: "intake-2", status: .taken)
        }
        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .takeMedication)
        let originalKey = queued.first?.idempotencyKey
        #expect(originalKey != nil)

        phase.set(1)
        let replayService = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: repo,
            maxAttempts: 8
        )
        await replayService.runOnce()

        let allKeys = recorder.snapshot
        #expect(Set(allKeys).count == 1, "Medications replay must reuse the original key, got \(allKeys)")
        #expect(try allKeys.contains(#require(originalKey)), "replay key must equal the persisted outbox key")
        await #expect(outbox.snapshot.isEmpty)
    }

    // MARK: - Erfolgs-Pfad: Server sieht den Key genau einmal

    @Test("Erfolgs-Pfad: ein 200 → genau ein Server-Hit, ein Key")
    func happyPathSingleHit() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            let body = #"{"data":{"id":"srv-3","type":"WEIGHT","value":80.5,"unit":"kg","measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z","source":"MANUAL","externalId":null,"note":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let measurement = Measurement(
            id: "local-3",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
            value: .scalar(80.5)
        )
        _ = try await repo.create(measurement)

        let keys = recorder.snapshot
        #expect(keys.count == 1, "happy path must hit server exactly once, got \(keys.count)")
    }
}

// swiftlint:enable force_unwrapping force_try
