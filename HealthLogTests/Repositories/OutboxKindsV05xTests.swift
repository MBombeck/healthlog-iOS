import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try type_body_length file_length

/// Round-trip + retry coverage for the v0.5.x edit/delete kinds. Two tests
/// per kind: (a) 2xx success drains the row + reuses the persisted
/// Idempotency-Key, (b) 4xx non-retryable drops the row without infinite
/// retry. Real `APIClient` + `MockURLProtocol` per PROJECT_GUIDE.md anti-pattern
/// guidance (mock-servers hide schema drift).
@Suite("Outbox v0.5.x edit/delete kinds", .serialized)
struct OutboxKindsV05xTests {
    // MARK: - Helpers

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeReplay(api: APIClient, outbox: OutboxQueue, maxAttempts: Int = 8) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            maxAttempts: maxAttempts
        )
    }

    /// Server-true wire envelope for `PUT /api/measurements/[id]` —
    /// mirrors what `MeasurementWireDTO` decodes.
    private let measurementPatchResponse = """
    {"data":{"id":"srv-m-1","type":"WEIGHT","value":82.5,"unit":"kg",\
    "measuredAt":"2026-05-01T10:00:00Z","createdAt":"2026-05-01T10:00:00Z",\
    "source":"MANUAL","externalId":null,"note":"updated"}}
    """

    /// Server-true wire envelope for `PUT /api/mood-entries/[id]` —
    /// returns the full `MoodEntry` shape.
    private let moodPatchResponse = """
    {"id":"srv-mood-1","mood":"GUT","tags":["happy"],\
    "moodLoggedAt":"2026-05-01T10:00:00Z","source":"MANUAL","note":"updated"}
    """

    /// Server-true wire envelope for `POST/PUT /api/medications` — returns
    /// the `MedicationWireDTO` shape with the `schedules` array.
    private let medicationResponse = """
    {"id":"srv-med-1","name":"Ozempic","dose":"1.0 mg","treatmentClass":"GLP-1",\
    "dosesPerUnit":4,"category":"PRESCRIPTION","active":true,\
    "notificationsEnabled":true,"schedules":[],"lastTakenAt":null,\
    "todayEventCount":0}
    """

    /// Server-true wire envelope for `POST/PUT /api/medications/[id]/intake/[eventId]`
    /// — returns the raw Prisma row (`MedicationIntakeWireDTO`).
    private let intakeResponse =
        #"{"id":"srv-intake-1","medicationId":"srv-med-1","scheduledFor":"2026-05-01T10:00:00Z","takenAt":"2026-05-01T10:30:00Z","skipped":false,"snoozedUntil":null}"#

    /// Encodes one payload-of-kind and returns a ready-to-enqueue
    /// `OutboxQueue.Operation`. Centralizing this keeps each test body
    /// focused on the dispatch behaviour, not on payload trivia.
    private func makeOp(kind: OutboxQueue.Operation.Kind, payload: some Encodable, key: String) throws -> OutboxQueue.Operation {
        let data = try JSONEncoder.hlDefault.encode(payload)
        return OutboxQueue.Operation(
            id: UUID(),
            kind: kind,
            payload: data,
            idempotencyKey: key,
            createdAt: .now
        )
    }

    // MARK: - updateMeasurement

    @Test("updateMeasurement round-trip drains the row on 200 and reuses Idempotency-Key")
    func updateMeasurementRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-um-1"
        let op = try makeOp(
            kind: .updateMeasurement,
            payload: OutboxQueue.Payloads.UpdateMeasurement(
                id: "srv-m-1",
                patch: MeasurementPatch(value: 82.5, measuredAt: nil, notes: "updated"),
                kind: .weight
            ),
            key: key
        )
        try await outbox.enqueue(op)
        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = measurementPatchResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            // PUT (not PATCH): the server item route exports GET/PUT/DELETE
            // only — a PATCH would 405 and the edit would be silently lost.
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path == "/api/measurements/srv-m-1")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("updateMeasurement on non-retryable 404 drops the row")
    func updateMeasurementNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .updateMeasurement,
            payload: OutboxQueue.Payloads.UpdateMeasurement(
                id: "deleted-by-someone-else",
                patch: MeasurementPatch(value: 1.0),
                kind: .weight
            ),
            key: "key-um-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty, "404 is non-retryable → row dropped, not stuck")
    }

    // MARK: - deleteMeasurement

    @Test("deleteMeasurement round-trip issues DELETE and removes the row on 204")
    func deleteMeasurementRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMeasurement,
            payload: OutboxQueue.Payloads.DeleteMeasurement(id: "srv-m-2"),
            key: "key-dm-1"
        )
        try await outbox.enqueue(op)
        let pathRecorder = PathRecorder()
        MockURLProtocol.handler = { req in
            pathRecorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            // `EmptyResponse` contract: 2xx + `{}` body decodes cleanly via the
            // envelope-fallback path in `APIClient.decodePayload`. Bare 204 with
            // an empty body would trip the JSON-parser's `dataCorrupted` arm.
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(pathRecorder.entries.contains(where: { $0.method == "DELETE" && $0.path == "/api/measurements/srv-m-2" }))
    }

    @Test("deleteMeasurement non-retryable 403 drops without retry storm")
    func deleteMeasurementNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMeasurement,
            payload: OutboxQueue.Payloads.DeleteMeasurement(id: "not-mine"),
            key: "key-dm-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - updateMood

    @Test("updateMood round-trip PUTs /api/mood-entries/[id] and clears the row")
    func updateMoodRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-umood-1"
        let op = try makeOp(
            kind: .updateMood,
            payload: OutboxQueue.Payloads.UpdateMood(
                id: "srv-mood-1",
                patch: MoodEntryPatch(score: 4, tags: ["happy"], recordedAt: nil, note: "updated")
            ),
            key: key
        )
        try await outbox.enqueue(op)
        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = moodPatchResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            // PUT (not PATCH): the server item route exports GET/PUT/DELETE only.
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path == "/api/mood-entries/srv-mood-1")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("updateMood non-retryable 422 drops the row")
    func updateMoodNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .updateMood,
            payload: OutboxQueue.Payloads.UpdateMood(
                id: "srv-mood-1",
                patch: MoodEntryPatch()
            ),
            key: "key-umood-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - deleteMood

    @Test("deleteMood round-trip DELETEs /api/mood-entries/[id]")
    func deleteMoodRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMood,
            payload: OutboxQueue.Payloads.DeleteMood(id: "srv-mood-1"),
            key: "key-dmood-1"
        )
        try await outbox.enqueue(op)
        let pathRecorder = PathRecorder()
        MockURLProtocol.handler = { req in
            pathRecorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(pathRecorder.entries.contains(where: { $0.method == "DELETE" && $0.path == "/api/mood-entries/srv-mood-1" }))
    }

    @Test("deleteMood non-retryable 404 drops")
    func deleteMoodNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMood,
            payload: OutboxQueue.Payloads.DeleteMood(id: "ghost"),
            key: "key-dmood-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - createMedication

    @Test("createMedication round-trip POSTs /api/medications and drains the row")
    func createMedicationRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-cmed-1"
        let op = try makeOp(
            kind: .createMedication,
            payload: OutboxQueue.Payloads.CreateMedication(
                body: MedicationsRepository.MedicationCreate(name: "Ozempic", dose: "1.0 mg")
            ),
            key: key
        )
        try await outbox.enqueue(op)
        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = medicationResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/medications")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("createMedication non-retryable 422 drops the row")
    func createMedicationNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .createMedication,
            payload: OutboxQueue.Payloads.CreateMedication(
                body: MedicationsRepository.MedicationCreate(name: "", dose: "")
            ),
            key: "key-cmed-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - updateMedication

    @Test("updateMedication round-trip PUTs /api/medications/[id]")
    func updateMedicationRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-umed-1"
        let op = try makeOp(
            kind: .updateMedication,
            payload: OutboxQueue.Payloads.UpdateMedication(
                id: "srv-med-1",
                patch: MedicationsRepository.MedicationPatch(active: false)
            ),
            key: key
        )
        try await outbox.enqueue(op)
        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = medicationResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path == "/api/medications/srv-med-1")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("updateMedication non-retryable 422 drops")
    func updateMedicationNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .updateMedication,
            payload: OutboxQueue.Payloads.UpdateMedication(
                id: "srv-med-1",
                patch: MedicationsRepository.MedicationPatch()
            ),
            key: "key-umed-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - deleteMedication

    @Test("deleteMedication round-trip DELETEs /api/medications/[id]")
    func deleteMedicationRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMedication,
            payload: OutboxQueue.Payloads.DeleteMedication(id: "srv-med-1"),
            key: "key-dmed-1"
        )
        try await outbox.enqueue(op)
        let pathRecorder = PathRecorder()
        MockURLProtocol.handler = { req in
            pathRecorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(pathRecorder.entries.contains(where: { $0.method == "DELETE" && $0.path == "/api/medications/srv-med-1" }))
    }

    @Test("deleteMedication non-retryable 404 drops")
    func deleteMedicationNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMedication,
            payload: OutboxQueue.Payloads.DeleteMedication(id: "ghost"),
            key: "key-dmed-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - updateIntake

    @Test("updateIntake round-trip PUTs the nested intake route")
    func updateIntakeRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let key = "key-uintake-1"
        let op = try makeOp(
            kind: .updateIntake,
            payload: OutboxQueue.Payloads.UpdateIntake(
                medicationId: "srv-med-1",
                eventId: "srv-intake-1",
                patch: MedicationsRepository.IntakePatch(status: "taken", takenAt: Date(timeIntervalSince1970: 1_714_550_400))
            ),
            key: key
        )
        try await outbox.enqueue(op)
        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = intakeResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path == "/api/medications/srv-med-1/intake/srv-intake-1")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("updateIntake non-retryable 422 drops")
    func updateIntakeNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .updateIntake,
            payload: OutboxQueue.Payloads.UpdateIntake(
                medicationId: "srv-med-1",
                eventId: "srv-intake-1",
                patch: MedicationsRepository.IntakePatch(status: "bogus", takenAt: nil)
            ),
            key: "key-uintake-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - deleteIntake

    @Test("deleteIntake round-trip DELETEs the nested intake route")
    func deleteIntakeRoundTrip() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteIntake,
            payload: OutboxQueue.Payloads.DeleteIntake(
                medicationId: "srv-med-1",
                eventId: "srv-intake-1"
            ),
            key: "key-dintake-1"
        )
        try await outbox.enqueue(op)
        let pathRecorder = PathRecorder()
        MockURLProtocol.handler = { req in
            pathRecorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
        #expect(
            pathRecorder.entries.contains(where: {
                $0.method == "DELETE" && $0.path == "/api/medications/srv-med-1/intake/srv-intake-1"
            })
        )
    }

    @Test("deleteIntake non-retryable 404 drops")
    func deleteIntakeNonRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteIntake,
            payload: OutboxQueue.Payloads.DeleteIntake(
                medicationId: "srv-med-1",
                eventId: "ghost"
            ),
            key: "key-dintake-2"
        )
        try await outbox.enqueue(op)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox)
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - Cross-kind: persistence + forward-compat

    @Test("All 9 new kinds round-trip the persistent store under one container")
    func allNewKindsPersistAcrossInstance() async throws {
        // Persist one operation per new kind through OutboxStore + recreate the
        // faade — proves `kindRaw: String` is forward-compatible (no schema
        // migration needed for the v0.5.x kinds).
        let container = try OutboxStore.makeInMemory()
        let outboxA = OutboxQueue(testContainer: container)

        let kinds: [(OutboxQueue.Operation.Kind, Data)] = try [
            (.updateMeasurement, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UpdateMeasurement(
                id: "m", patch: MeasurementPatch(value: 1), kind: .weight
            ))),
            (.deleteMeasurement, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.DeleteMeasurement(id: "m"))),
            (.updateMood, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UpdateMood(id: "m", patch: MoodEntryPatch()))),
            (.deleteMood, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.DeleteMood(id: "m"))),
            (.createMedication, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.CreateMedication(
                body: MedicationsRepository.MedicationCreate(name: "X", dose: "1mg")
            ))),
            (.updateMedication, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UpdateMedication(
                id: "m", patch: MedicationsRepository.MedicationPatch(name: "Y")
            ))),
            (.deleteMedication, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.DeleteMedication(id: "m"))),
            (.updateIntake, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UpdateIntake(
                medicationId: "m", eventId: "e", patch: MedicationsRepository.IntakePatch(status: "taken")
            ))),
            (.deleteIntake, JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.DeleteIntake(
                medicationId: "m", eventId: "e"
            )))
        ]
        for (i, pair) in kinds.enumerated() {
            try await outboxA.enqueue(.init(
                id: UUID(),
                kind: pair.0,
                payload: pair.1,
                idempotencyKey: "key-cross-\(i)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(i))
            ))
        }
        // Discard outboxA, fresh actor against the same container — simulates
        // "kill process A, launch process B".
        let outboxB = OutboxQueue(testContainer: container)
        let snap = await outboxB.snapshot
        #expect(snap.count == kinds.count, "all 9 new kinds must round-trip the persistent store")
        let observedKinds = Set(snap.map(\.kind))
        for expected in kinds.map(\.0) {
            #expect(observedKinds.contains(expected), "expected \(expected.rawValue) to survive process restart")
        }
    }
}

// MARK: - Test helpers

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

/// Thread-safe collector for (method, path) tuples. Used by the DELETE
/// round-trip tests since `Idempotency-Key` is not sent on DELETE requests
/// (see `HTTPMethod.requiresIdempotency`), so the existing `KeyRecorder`
/// is not applicable.
private final class PathRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let method: String
        let path: String
    }

    private let lock = NSLock()
    private var rows: [Entry] = []

    func record(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        rows.append(Entry(method: method, path: path))
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }
}

// swiftlint:enable force_unwrapping force_try type_body_length
