import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Audit B-3 / B-11 / B-2 (client half) — the replay may not lose a write in
/// silence, may not read an idempotency conflict as a verdict, may not swallow a
/// failed entity remap, and may not resend an operation the server already took.
///
/// Real `APIClient` + `MockURLProtocol` stub `URLSession` per PROJECT_GUIDE.md —
/// no mock server. Each test encodes the FIXED contract and fails by
/// construction on the pre-fix code (which deleted every non-retriable reply
/// with a log line, deleted a payload it could no longer decode, treated any 409
/// as permanent, dropped a remap error, and resent an op whose remove failed).
@Suite("Outbox replay visibility (audit B-3 / B-11 / B-2)", .serialized)
struct OutboxReplayVisibilityTests {
    // MARK: - Fixtures

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
        onDiscarded: (@Sendable ([OutboxDiscardNotice]) async -> Void)? = nil
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            familyHistoryRepo: FamilyHistoryRepository(api: api, outbox: outbox),
            maxAttempts: 8,
            deadLetterMinAge: 7 * 24 * 3600,
            attemptBackoff: 0,
            onDiscarded: onDiscarded
        )
    }

    private static let allergyResponse = """
    {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",\
    "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,\
    "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """

    @discardableResult
    private func enqueueAllergyCreate(
        _ outbox: OutboxQueue,
        clientEntityId: String? = nil
    ) async throws -> UUID {
        let id = UUID()
        let payload = OutboxQueue.Payloads.CreateAllergy(
            body: AllergyCreate(substance: "Penicillin", category: .medication)
        )
        try await outbox.enqueue(.init(
            id: id,
            kind: .createAllergy,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-\(id.uuidString)",
            createdAt: Date(timeIntervalSince1970: 1000),
            clientEntityId: clientEntityId
        ))
        return id
    }

    // MARK: - B-3 — a non-retriable server verdict is visible, not silent

    @Test("A 422 on a create removes the row AND reports kind + machine reason")
    func nonRetriableRejectionIsReported() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        try await enqueueAllergyCreate(outbox)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, nil)
        }
        let notices = NoticeRecorder()
        await makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) }).runOnce()

        #expect(await outbox.snapshot.isEmpty)
        let reported = await notices.all
        #expect(reported.count == 1)
        #expect(reported.first?.kind == "createAllergy")
        #expect(reported.first?.reason == .serverRejected)
    }

    @MainActor
    @Test("A reported discard raises the same honest failure surface as a dead-letter")
    func discardRaisesTheFailedDropSurface() {
        let store = SyncStateStore(repo: SyncStateRepository(api: makeAPI()))
        store.noteOutboxPending(1)
        store.noteDiscarded([.init(kind: "createAllergy", reason: .serverRejected)])
        store.noteOutboxPending(0)

        #expect(!store.showsDrainConfirmation)
        #expect(store.showsFailedDrop)
        #expect(store.failedDropCount == 1)
        #expect(store.failedDropCaption != nil)
        #expect(store.discardedWrites.first?.kind == "createAllergy")
        #expect(store.discardedWrites.first?.reason == .serverRejected)
    }

    // MARK: - B-3 — our OWN payload is not a server verdict

    @Test("A stored payload this build cannot decode is dead-lettered, not deleted")
    func undecodablePayloadIsDeadLettered() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let id = UUID()
        try await outbox.enqueue(.init(
            id: id,
            kind: .createAllergy,
            payload: Data("{ not json at all".utf8),
            idempotencyKey: "key-undecodable",
            createdAt: Date(timeIntervalSince1970: 1000)
        ))
        let recorder = MethodPathRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }
        let notices = NoticeRecorder()
        let replay = makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) })
        await replay.runOnce()

        // Retained + recoverable, never transmitted, and out of the live queue …
        #expect(await outbox.deadLetterCount == 1)
        #expect(await outbox.deadLetteredOperations.first?.id == id)
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.isEmpty)
        // … and counted with the reason that says whose fault it is.
        #expect(await notices.all.first?.reason == .payloadUnreadable)

        // A second drain must not resend it either.
        await replay.runOnce()
        #expect(recorder.snapshot.isEmpty)
    }

    // MARK: - B-2 — the idempotency signals

    @Test("A 2xx carrying X-Idempotent-Replay: true is delivery, not a second write")
    func idempotentReplayHitCountsAsDelivered() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        try await enqueueAllergyCreate(outbox)
        let recorder = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.allergyResponse] req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 201, httpVersion: nil,
                headerFields: ["X-Idempotent-Replay": "true"]
            )!
            return (http, Data(resp.utf8))
        }
        let notices = NoticeRecorder()
        let replay = makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) })
        await replay.runOnce()
        await replay.runOnce()

        #expect(await outbox.snapshot.isEmpty)
        #expect(await outbox.deadLetterCount == 0)
        #expect(await notices.all.isEmpty)
        #expect(recorder.snapshot.count == 1) // exactly one write, no duplicate
    }

    @Test("A 409 with X-Idempotent-Replay: false is retriable, never a discard")
    func idempotencyInFlightConflictIsRetriable() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        try await enqueueAllergyCreate(outbox)
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 409, httpVersion: nil,
                headerFields: ["X-Idempotent-Replay": "false"]
            )!
            return (http, Data(#"{"error":"Request with this Idempotency-Key is in flight"}"#.utf8))
        }
        let notices = NoticeRecorder()
        await makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) }).runOnce()

        let row = await outbox.snapshot.first
        #expect(row?.kind == .createAllergy) // kept for the next pass
        #expect(row?.attempts == 1) // budget-counted
        #expect(await notices.all.isEmpty) // not a verdict → not a discard
    }

    @Test("A 409 without the replay header stays non-retriable but visible")
    func plainConflictIsDiscardedVisibly() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        try await enqueueAllergyCreate(outbox)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, nil)
        }
        let notices = NoticeRecorder()
        await makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) }).runOnce()

        #expect(await outbox.snapshot.isEmpty)
        #expect(await notices.all.first?.reason == .serverRejected)
    }

    // MARK: - B-11 — a failed remap is a replay failure

    @Test("A failed entity remap keeps the operation queued and counts the attempt")
    func failedRemapIsAReplayFailure() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let optimisticId = "optimistic-\(UUID().uuidString)"
        try await enqueueAllergyCreate(outbox, clientEntityId: optimisticId)
        await outbox.injectFault(.entityRemap)
        MockURLProtocol.handler = { [resp = Self.allergyResponse] req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let notices = NoticeRecorder()
        await makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) }).runOnce()

        let row = await outbox.snapshot.first
        #expect(row?.kind == .createAllergy) // not dropped
        #expect(row?.attempts == 1) // budget-counted
        #expect(await notices.all.isEmpty)
    }

    // MARK: - B-2 — delivered is marked before the local remove can fail

    @Test("An operation whose remove fails is not sent a second time")
    func failedRemoveDoesNotResend() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let id = try await enqueueAllergyCreate(outbox)
        await outbox.injectFault(.remove)
        let recorder = MethodPathRecorder()
        MockURLProtocol.handler = { [resp = Self.allergyResponse] req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let notices = NoticeRecorder()
        let replay = makeReplay(api: makeAPI(), outbox: outbox, onDiscarded: { await notices.record($0) })
        await replay.runOnce()

        // The row survived the failed remove — but it is stamped delivered.
        let row = await outbox.snapshot.first
        #expect(row?.id == id)
        #expect(row?.delivered == true)

        // A second drain must not put it back on the wire …
        await replay.runOnce()
        #expect(recorder.snapshot.count == 1)
        #expect(await notices.all.isEmpty)

        // … and once the local store recovers, the row finally drains.
        await outbox.clearFaults()
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.count == 1)
    }
}

// MARK: - Recorders (file-private)

private actor NoticeRecorder {
    private var notices: [OutboxDiscardNotice] = []
    func record(_ batch: [OutboxDiscardNotice]) {
        notices.append(contentsOf: batch)
    }

    var all: [OutboxDiscardNotice] {
        notices
    }
}

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
