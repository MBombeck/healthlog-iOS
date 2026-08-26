import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v1.25 PHI — durable-write coverage for the structured-records (allergy +
/// family-history) outbox kinds. Two halves per the established outbox idiom:
///   (a) a retriable network failure ENQUEUES the write + re-throws;
///   (b) replay drains the row on a 2xx, reusing the persisted Idempotency-Key.
///
/// Real `APIClient` + `MockURLProtocol` (stub `URLSession`) per PROJECT_GUIDE.md — NO
/// mock server.
@Suite("Outbox structured-records durable writes", .serialized)
struct OutboxRecordsTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
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

    // MARK: - createAllergy

    @Test("createAllergy on a retriable failure enqueues to the outbox + re-throws")
    func createAllergyEnqueues() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = AllergiesRepository(api: api, outbox: outbox)
        await #expect(throws: (any Error).self) {
            _ = try await repo.create(AllergyCreate(substance: "Penicillin", category: .medication))
        }
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.kind == .createAllergy)
    }

    @Test("createAllergy replay drains the row on 200 + reuses the Idempotency-Key")
    func createAllergyReplayDrains() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let key = "key-createallergy-1"
        let payload = OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: "Penicillin"))
        try await outbox.enqueue(.init(kind: .createAllergy, payload: JSONEncoder.hlDefault.encode(payload), idempotencyKey: key))

        let recorder = OutboxRecordsKeyRecorder()
        MockURLProtocol.handler = { [resp = allergyResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/allergies")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("updateAllergy replay re-issues PATCH /api/allergies/{id} with the tri-state body")
    func updateAllergyReplay() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let payload = OutboxQueue.Payloads.UpdateAllergy(id: "srv-a-1", patch: AllergyPatch(note: .clear))
        try await outbox.enqueue(.init(kind: .updateAllergy, payload: JSONEncoder.hlDefault.encode(payload), idempotencyKey: "key-up-1"))

        let recorder = OutboxRecordsPathRecorder()
        MockURLProtocol.handler = { [resp = allergyResponse] req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains("PATCH /api/allergies/srv-a-1"))
    }

    // MARK: - family history

    @Test("deleteFamilyHistory replay issues DELETE on 200 (soft, idempotent)")
    func deleteFamilyReplay() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let payload = OutboxQueue.Payloads.DeleteFamilyHistory(id: "srv-f-2")
        try await outbox.enqueue(.init(
            kind: .deleteFamilyHistory,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-delfam-1"
        ))

        let recorder = OutboxRecordsPathRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":true}}"#.utf8)
            )
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains("DELETE /api/family-history/srv-f-2"))
    }

    @Test("createFamilyHistory on a retriable failure enqueues + re-throws")
    func createFamilyEnqueues() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = FamilyHistoryRepository(api: api, outbox: outbox)
        await #expect(throws: (any Error).self) {
            _ = try await repo.create(FamilyHistoryCreate(relationship: .mother, condition: "Diabetes"))
        }
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.kind == .createFamilyHistory)
    }
}

// MARK: - Recorders (file-private)

private final class OutboxRecordsKeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String?] = []
    func record(_ key: String?) {
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys.compactMap(\.self)
    }
}

private final class OutboxRecordsPathRecorder: @unchecked Sendable {
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
