import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// audit-v0162 reliability fixes — H1 (dead-letter STAGED: age+attempts gate,
/// degraded-server attempt-suppression, persisted recoverable DLQ + honest
/// footer), M2 (causal ordering — dependent op not dropped before its create),
/// and H-4 (optimistic→server id remap keeps an offline edit).
///
/// Real `APIClient` + `MockURLProtocol` stub `URLSession` per PROJECT_GUIDE.md — NO
/// mock server. Each test encodes the FIXED contract and fails by construction
/// on the pre-fix code (which dead-lettered on attempts alone, counted degraded
/// 5xx, permanently deleted swept rows, flashed false success, dropped a
/// dependent update on a 404, and lost an offline edit to a stale optimistic id).
@Suite("Outbox reliability audit-v0162 (H1 / M2 / H-4)", .serialized)
struct OutboxDeadLetterV0162Tests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.16.2",
            buildNumber: "206"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeReplay(
        api: APIClient,
        outbox: OutboxQueue,
        maxAttempts: Int = 8,
        deadLetterMinAge: TimeInterval = 0,
        serverHealthDegraded: (@Sendable () async -> Bool)? = nil,
        onDeadLettered: (@Sendable (Int) async -> Void)? = nil
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            familyHistoryRepo: FamilyHistoryRepository(api: api, outbox: outbox),
            maxAttempts: maxAttempts,
            deadLetterMinAge: deadLetterMinAge,
            attemptBackoff: 0,
            serverHealthDegraded: serverHealthDegraded,
            onDeadLettered: onDeadLettered
        )
    }

    private static let allergyResponse = """
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",\
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,\
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """

    private func enqueueAllergyCreate(_ outbox: OutboxQueue, clientEntityId: String, at date: Date) async throws {
        let payload = OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: "Penicillin", category: .medication))
        try await outbox.enqueue(.init(
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-create-\(clientEntityId)",
            createdAt: date,
            clientEntityId: clientEntityId
        ))
    }

    private func enqueueAllergyUpdate(_ outbox: OutboxQueue, targetId: String, clientEntityId: String, at date: Date) async throws {
        let payload = OutboxQueue.Payloads.UpdateAllergy(id: targetId, patch: AllergyPatch(note: .clear))
        try await outbox.enqueue(.init(
            kind: .updateAllergy,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-update-\(clientEntityId)",
            createdAt: date,
            clientEntityId: clientEntityId
        ))
    }

    // MARK: - H1 (Opt 3) — age gate: attempt-burn alone does NOT dead-letter

    @Test("Dead-letter is NOT triggered by attempt-burn within the age window")
    func attemptBurnWithinAgeWindowDoesNotDeadLetter() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await outbox.enqueue(.init(
            id: id,
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: "X"))
            ),
            idempotencyKey: "key-age",
            createdAt: now
        ))
        // Burn the whole retry budget — but the row is fresh (age 0).
        for _ in 0 ..< 8 {
            try await outbox.incrementAttempts(id: id, lastError: "503")
        }
        // attempts >= max, BUT age < 7d → must NOT dead-letter.
        let sweptFresh = try await outbox.markDeadLetters(maxAttempts: 8, minAge: 7 * 24 * 3600, now: now)
        #expect(sweptFresh.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
        #expect(await outbox.snapshot.count == 1) // still live/recoverable

        // Same row, evaluated 8 days later → now BOTH gates pass → dead-lettered.
        let eightDaysLater = now.addingTimeInterval(8 * 24 * 3600)
        let sweptAged = try await outbox.markDeadLetters(maxAttempts: 8, minAge: 7 * 24 * 3600, now: eightDaysLater)
        #expect(sweptAged.count == 1)
        #expect(await outbox.deadLetterCount == 1)
    }

    // MARK: - H1 (Opt 3) — degraded-server 5xx does NOT count an attempt

    @Test("A 5xx while the server is known-degraded does not increment attempts")
    func degraded5xxDoesNotIncrementAttempts() async throws {
        // Control: server 503 but NOT degraded → attempt is counted.
        let control = try OutboxQueue(inMemory: true)
        try await enqueueAllergyCreate(control, clientEntityId: "c1", at: .now)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        await makeReplay(api: makeAPI(), outbox: control, deadLetterMinAge: 7 * 24 * 3600, serverHealthDegraded: { false })
            .runOnce()
        #expect(await control.snapshot.first?.attempts == 1)

        // Degraded: identical 503, but the health probe reports degraded → the
        // attempt is stamped (lastAttemptAt) but NOT counted toward dead-letter.
        let degraded = try OutboxQueue(inMemory: true)
        try await enqueueAllergyCreate(degraded, clientEntityId: "d1", at: .now)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        await makeReplay(api: makeAPI(), outbox: degraded, deadLetterMinAge: 7 * 24 * 3600, serverHealthDegraded: { true })
            .runOnce()
        let row = await degraded.snapshot.first
        #expect(row?.attempts == 0) // budget preserved during the outage
        #expect(row != nil) // write is kept, not lost
    }

    // MARK: - H1 (Opt 2) — honest footer state on a dead-letter DROP

    @MainActor
    @Test("Sync footer surfaces the honest failed state on a dead-letter drop, not success")
    func footerHonestOnDeadLetterDrop() {
        let store = SyncStateStore(repo: SyncStateRepository(api: makeAPI()))

        // Sanity — a genuine drain (>0 → 0 with no dead-letter) DOES confirm.
        store.noteOutboxPending(2)
        store.noteOutboxPending(0)
        #expect(store.showsDrainConfirmation)
        #expect(!store.showsFailedDrop)

        // Now the dead-letter path: backlog present, a DLQ sweep flags failures,
        // and the resulting >0 → 0 backlog drop must NOT read as success.
        store.noteOutboxPending(3)
        store.noteDeadLettered(3)
        store.noteOutboxPending(0)
        #expect(!store.showsDrainConfirmation)
        #expect(store.showsFailedDrop)
        #expect(store.failedDropCount == 3)
        #expect(store.failedDropCaption != nil)
    }

    // MARK: - H1 (Opt 1) — dead-lettered op is persisted + re-submittable

    @Test("A dead-lettered op is persisted (recoverable) and re-submittable")
    func deadLetteredOpIsPersistedAndResubmittable() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let id = UUID()
        try await outbox.enqueue(.init(
            id: id,
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: "X"))
            ),
            idempotencyKey: "key-recover",
            createdAt: .now,
            attempts: 8
        ))
        _ = try await outbox.markDeadLetters(maxAttempts: 8, minAge: 0, now: .now)
        // Dropped from the live queue but NOT gone — counted + listed.
        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 1)
        #expect(await outbox.deadLetteredOperations.first?.id == id)

        // Manual re-submit re-arms it (flag cleared + retry budget reset).
        #expect(try await outbox.resubmitDeadLetter(id: id))
        #expect(await outbox.deadLetterCount == 0)
        let resurrected = await outbox.snapshot.first
        #expect(resurrected?.id == id)
        #expect(resurrected?.attempts == 0)
    }

    // MARK: - M2 — a dependent update is NOT dropped before its create lands

    @Test("M2: a retriable create failure skips (does not drop) the dependent update")
    func dependentUpdateNotDroppedOnRetriableCreateFailure() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let optimisticId = "optimistic-\(UUID().uuidString)"
        try await enqueueAllergyCreate(outbox, clientEntityId: optimisticId, at: Date(timeIntervalSince1970: 1000))
        try await enqueueAllergyUpdate(
            outbox, targetId: optimisticId, clientEntityId: optimisticId, at: Date(timeIntervalSince1970: 2000)
        )

        let recorder = MethodPathRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            // The create POST fails retriably; a PATCH (if it were attempted with
            // the stale optimistic id) would 404 and be DROPPED — the bug M2 fixes.
            if req.httpMethod == "POST" {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        await makeReplay(api: makeAPI(), outbox: outbox, deadLetterMinAge: 7 * 24 * 3600).runOnce()

        // The dependent PATCH must never have been attempted this pass …
        #expect(!recorder.snapshot.contains(where: { $0.hasPrefix("PATCH") }))
        // … and BOTH ops survive (the update was skipped, not 404-dropped).
        let kinds = await Set(outbox.snapshot.map(\.kind))
        #expect(kinds.contains(.createAllergy))
        #expect(kinds.contains(.updateAllergy))
    }

    // MARK: - H-4 — optimistic→server id remap keeps an offline edit

    @Test("H-4: an offline edit of an offline-created record is remapped to the server id")
    func offlineEditRemappedToServerId() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let optimisticId = "optimistic-\(UUID().uuidString)"
        try await enqueueAllergyCreate(outbox, clientEntityId: optimisticId, at: Date(timeIntervalSince1970: 1000))
        try await enqueueAllergyUpdate(
            outbox, targetId: optimisticId, clientEntityId: optimisticId, at: Date(timeIntervalSince1970: 2000)
        )

        let recorder = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.allergyResponse] req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            // The create lands with server id "srv-a-1"; the PATCH must be
            // retargeted to /api/allergies/srv-a-1, NOT the optimistic id.
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        await makeReplay(api: makeAPI(), outbox: outbox, deadLetterMinAge: 7 * 24 * 3600).runOnce()

        #expect(await outbox.snapshot.isEmpty) // both drained
        #expect(recorder.snapshot.contains("PATCH /api/allergies/srv-a-1"))
        // The stale optimistic id must NEVER be addressed by the edit.
        #expect(!recorder.snapshot.contains("PATCH /api/allergies/\(optimisticId)"))
    }
}

// MARK: - Recorder (file-private)

private final class MethodPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append("\(method) \(path)")
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

// swiftlint:enable force_unwrapping
