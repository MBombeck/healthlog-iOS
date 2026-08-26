import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// audit-v0162 H1 — reentrancy guard on the outbox replay entry point.
///
/// `OutboxReplayService.runOnce()` is triggered from THREE concurrent sources
/// (reachability edge, app-foreground, auth bootstrap). Its `guard !isRunning`
/// single-flight (set synchronously before the first `await`) must ensure that
/// overlapping `runOnce()` calls never double-drain the queue — each queued op
/// is dispatched (POSTed) **exactly once**, not once per concurrent trigger.
///
/// Real `APIClient` + `MockURLProtocol` (stub `URLSession`) per PROJECT_GUIDE.md — NO
/// mock server. We count POSTs per persisted `Idempotency-Key`: a missing guard
/// would let two overlapping drains each POST the same op before it is removed,
/// so the lock is "every key POSTed exactly once".
///
/// `.serialized` — this suite owns the process-global `MockURLProtocol.handler`
/// for the duration of each test (audit-v0162 H2).
@Suite("Outbox replay reentrancy guard", .serialized)
struct OutboxReplayReentrancyTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeReplay(api: APIClient, outbox: OutboxQueue) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            familyHistoryRepo: FamilyHistoryRepository(api: api, outbox: outbox)
        )
    }

    private let allergyResponse = """
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",\
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,\
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """

    /// Enqueue N create ops, then fire `runOnce()` concurrently from several
    /// tasks (simulating reachability + foreground + auth-bootstrap firing at
    /// once). Assert each op produced EXACTLY one POST and the queue drained
    /// once — the `isRunning` guard prevents a double-drain.
    @Test("Overlapping runOnce() calls dispatch each queued op exactly once")
    func concurrentRunOnceDoesNotDoubleDrain() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()

        // Three distinct create ops with distinct, byte-stable idempotency keys.
        let keys = ["reentr-key-1", "reentr-key-2", "reentr-key-3"]
        for (i, key) in keys.enumerated() {
            let payload = OutboxQueue.Payloads.CreateAllergy(
                body: AllergyCreate(substance: "Substance-\(i)")
            )
            try await outbox.enqueue(.init(
                kind: .createAllergy,
                payload: JSONEncoder.hlDefault.encode(payload),
                idempotencyKey: key
            ))
        }

        // Count POSTs per Idempotency-Key. A small artificial delay widens the
        // drain window so any missing-guard double-drain would overlap and be
        // caught — the guard itself is set before the first `await`, so the
        // exactly-once property must hold regardless of timing.
        let counter = KeyCounter()
        MockURLProtocol.handler = { [resp = allergyResponse] req in
            if req.httpMethod == "POST", req.url?.path == "/api/allergies" {
                counter.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(resp.utf8)
            )
        }

        let replay = makeReplay(api: api, outbox: outbox)

        // Fire five overlapping triggers at once.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask { await replay.runOnce() }
            }
            await group.waitForAll()
        }

        // Each op POSTed exactly once — the guard collapsed the overlapping
        // triggers into a single drain.
        for key in keys {
            #expect(counter.count(for: key) == 1)
        }
        // Total POSTs == number of ops — no op fired twice.
        #expect(counter.total == keys.count)
        // Queue fully drained.
        #expect(await outbox.snapshot.isEmpty)
    }

    /// Even a second wave of concurrent triggers fired AFTER the first drain
    /// completes must not re-POST anything (the queue is already empty). This
    /// guards against a stale in-pass snapshot re-dispatching drained rows.
    @Test("A follow-up runOnce burst after a full drain POSTs nothing")
    func followUpBurstAfterDrainIsNoop() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let payload = OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: "Once"))
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "reentr-single"
        ))

        let counter = KeyCounter()
        MockURLProtocol.handler = { [resp = allergyResponse] req in
            if req.httpMethod == "POST", req.url?.path == "/api/allergies" {
                counter.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(resp.utf8)
            )
        }

        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty)

        // Second concurrent burst — nothing left to drain.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask { await replay.runOnce() }
            }
            await group.waitForAll()
        }
        #expect(counter.total == 1)
        #expect(counter.count(for: "reentr-single") == 1)
    }
}

// MARK: - POST counter (file-private, thread-safe)

private final class KeyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ key: String?) {
        guard let key else { return }
        lock.lock()
        defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func count(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
}

// swiftlint:enable force_unwrapping
