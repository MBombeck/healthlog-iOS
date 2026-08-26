import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v1.18.6 PHI — durable-write coverage for the labs + illness outbox kinds.
/// Two halves per the established outbox idiom (`OutboxKindsV05xTests`):
///   (a) a retriable network failure ENQUEUES the write to the outbox + re-throws
///       (the optimistic store keeps its state);
///   (b) replay drains the row on a 2xx, reusing the persisted Idempotency-Key.
///
/// Real `APIClient` + `MockURLProtocol` (stub `URLSession`) per the PROJECT_GUIDE.md
/// anti-pattern guidance — NO mock server (those hide schema drift).
@Suite("Outbox labs + illness durable writes", .serialized)
struct OutboxLabsIllnessTests {
    private func makeAPI(configuration: URLSessionConfiguration = .mock()) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: configuration)
    }

    private func makeReplay(api: APIClient, outbox: OutboxQueue) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            labsRepo: LabsRepository(api: api, outbox: outbox),
            illnessRepo: IllnessRepository(api: api, outbox: outbox)
        )
    }

    /// Server-true `LabResult` envelope (`APIClient.send` strips the `data` wrap).
    private let labResponse = """
    {"data":{"id":"srv-lab-1","biomarkerId":null,"panel":null,"analyte":"HbA1c",\
    "value":5.4,"unit":"%","referenceLow":4.0,"referenceHigh":6.0,\
    "takenAt":"2026-01-01T08:30:00Z","source":"MANUAL","hasNote":false,\
    "rangeStatus":"in-range","createdAt":"2026-01-01T08:30:00Z","updatedAt":"2026-01-01T08:30:00Z"}}
    """

    /// Server-true `IllnessEpisode` envelope.
    private let episodeResponse = """
    {"data":{"id":"srv-ep-1","label":"Flu","type":"INFECTION","lifecycle":"ACUTE",\
    "onsetAt":"2026-01-01T00:00:00Z","resolvedAt":null,"parentConditionId":null,\
    "note":null,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
    """

    // MARK: - createLab

    @Test("createLab on a retriable failure enqueues to the outbox + re-throws")
    func createLabEnqueuesOnFailure() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        // 503 is retriable → shouldPersistToOutbox.
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = LabsRepository(api: api, outbox: outbox)
        await #expect(throws: (any Error).self) {
            _ = try await repo.createLab(LabResultCreate(value: 5.4, takenAt: "2026-01-01T08:30:00Z"))
        }
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.kind == .createLab)
    }

    @Test("createLab replay drains the row on 200 + reuses the Idempotency-Key")
    func createLabReplayDrains() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let key = "key-createlab-1"
        let payload = OutboxQueue.Payloads.CreateLab(body: LabResultCreate(value: 5.4, takenAt: "2026-01-01T08:30:00Z"))
        try await outbox.enqueue(.init(kind: .createLab, payload: JSONEncoder.hlDefault.encode(payload), idempotencyKey: key))

        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = labResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/labs")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    // MARK: - deleteLab

    @Test("deleteLab replay issues DELETE /api/labs/{id} on 200")
    func deleteLabReplay() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let payload = OutboxQueue.Payloads.DeleteLab(id: "srv-lab-2")
        try await outbox.enqueue(.init(
            kind: .deleteLab,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-dellab-1"
        ))

        let recorder = PathRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":true}}"#.utf8)
            )
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains("DELETE /api/labs/srv-lab-2"))
    }

    // MARK: - createIllnessEpisode

    @Test("createEpisode on a retriable failure enqueues + re-throws")
    func createEpisodeEnqueuesOnFailure() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = IllnessRepository(api: api, outbox: outbox)
        await #expect(throws: (any Error).self) {
            _ = try await repo.createEpisode(IllnessEpisodeCreate(
                label: "Flu",
                type: .infection,
                lifecycle: .acute,
                onsetAt: "2026-01-01T00:00:00Z"
            ))
        }
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.kind == .createIllnessEpisode)
    }

    @Test("createEpisode replay drains the row on 200 + reuses the Idempotency-Key")
    func createEpisodeReplayDrains() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let key = "key-createep-1"
        let body = IllnessEpisodeCreate(label: "Flu", type: .infection, lifecycle: .acute, onsetAt: "2026-01-01T00:00:00Z")
        let payload = OutboxQueue.Payloads.CreateIllnessEpisode(body: body)
        try await outbox.enqueue(.init(
            kind: .createIllnessEpisode,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: key
        ))

        let recorder = KeyRecorder()
        MockURLProtocol.handler = { [resp = episodeResponse] req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/illness/episodes")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains(key))
    }

    @Test("upsertDayLog replay POSTs to the episode day-logs route on 200")
    func upsertDayLogReplay() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let body = IllnessDayLogUpsert(date: "2026-01-02", functionalImpact: 2, feverC: 38.5)
        let payload = OutboxQueue.Payloads.UpsertIllnessDayLog(episodeId: "srv-ep-1", body: body)
        try await outbox.enqueue(.init(
            kind: .upsertIllnessDayLog,
            payload: JSONEncoder.hlDefault.encode(payload),
            idempotencyKey: "key-daylog-1"
        ))

        let recorder = PathRecorder()
        let dayLogResponse = #"{"data":{"id":"dl1","episodeId":"srv-ep-1","date":"2026-01-02","functionalImpact":2,"feverC":38.5,"symptoms":[],"updatedAt":"2026-01-02T00:00:00Z"}}"#
        MockURLProtocol.handler = { req in
            recorder.record(method: req.httpMethod ?? "", path: req.url?.path ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(dayLogResponse.utf8))
        }
        await makeReplay(api: api, outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty)
        #expect(recorder.snapshot.contains("POST /api/illness/episodes/srv-ep-1/day-logs"))
    }
}

// MARK: - Recorders (file-private)

private final class KeyRecorder: @unchecked Sendable {
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

private final class PathRecorder: @unchecked Sendable {
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
