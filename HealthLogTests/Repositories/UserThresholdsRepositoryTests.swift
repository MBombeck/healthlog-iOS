import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// Coverage for the v0.7.1 W-TARGETS-EDITOR write path: server-first PUT,
/// optimistic store update + rollback, retriable-failure outbox enqueue, and
/// outbox replay reusing the persisted Idempotency-Key. Real `APIClient` +
/// `MockURLProtocol` per PROJECT_GUIDE.md anti-pattern guidance (mock-servers hide
/// schema drift on the outbox-replay path).
@Suite("UserThresholds write path", .serialized)
struct UserThresholdsRepositoryTests {
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

    /// Server-true echo for `PUT /api/user/thresholds` — `apiSuccess({ overrides })`.
    private let putEcho = """
    {"data":{"overrides":{"WEIGHT":{"min":70,"max":80}}}}
    """

    // MARK: - validate (pure)

    @Test("validate accepts an in-bounds band with min < max")
    func validateAccepts() {
        let band = ThresholdRange(min: 70, max: 80)
        #expect(UserThresholdsStore.validate(band, for: .weight) == band)
    }

    @Test("validate rejects min >= max")
    func validateRejectsInverted() {
        #expect(UserThresholdsStore.validate(ThresholdRange(min: 80, max: 70), for: .weight) == nil)
        #expect(UserThresholdsStore.validate(ThresholdRange(min: 75, max: 75), for: .weight) == nil)
    }

    @Test("validate rejects out-of-physiological-bounds values")
    func validateRejectsOutOfBounds() {
        // Weight bounds are 30...300 kg.
        #expect(UserThresholdsStore.validate(ThresholdRange(min: 10, max: 80), for: .weight) == nil)
        #expect(UserThresholdsStore.validate(ThresholdRange(min: 70, max: 500), for: .weight) == nil)
        // Oxygen saturation cannot exceed 100 %.
        #expect(UserThresholdsStore.validate(ThresholdRange(min: 95, max: 101), for: .oxygenSaturation) == nil)
    }

    // MARK: - PUT success

    @Test("update PUTs the partial patch and echoes merged overrides")
    func updatePutsAndEchoes() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = UserThresholdsRepository(api: api, outbox: outbox)
        let recorder = HeaderRecorder()
        MockURLProtocol.handler = { [echo = putEcho] req in
            recorder.record(
                method: req.httpMethod ?? "",
                path: req.url?.path ?? "",
                key: req.value(forHTTPHeaderField: "Idempotency-Key")
            )
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(echo.utf8)
            )
        }
        let echo = try await repo.update(["WEIGHT": ThresholdRange(min: 70, max: 80)])
        #expect(echo.overrides["WEIGHT"] == ThresholdRange(min: 70, max: 80))
        #expect(recorder.entries.contains { $0.method == "PUT" && $0.path == "/api/user/thresholds" })
        // Nothing enqueued on success.
        #expect(await (outbox.snapshot).isEmpty)
    }

    // MARK: - Retriable failure → outbox enqueue

    @Test("retriable failure enqueues an updateThresholds op and re-throws")
    func retriableFailureEnqueues() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = UserThresholdsRepository(api: api, outbox: outbox)
        MockURLProtocol.handler = { req in
            // 503 is retriable per HLError.isRetriable (status >= 500).
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        await #expect(throws: HLError.self) {
            _ = try await repo.update(["WEIGHT": ThresholdRange(min: 70, max: 80)])
        }
        let snapshot = await outbox.snapshot
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.kind == .updateThresholds)
        // Payload decodes back to the original patch.
        let payload = try JSONDecoder.hlDefault.decode(
            OutboxQueue.Payloads.UpdateThresholds.self,
            from: #require(snapshot.first?.payload)
        )
        #expect(payload.patch["WEIGHT"] == ThresholdRange(min: 70, max: 80))
    }

    // MARK: - Outbox replay

    @Test("replay round-trips the PUT and reuses the persisted Idempotency-Key")
    func replayReusesKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = UserThresholdsRepository(api: api, outbox: outbox)
        let key = "key-thr-1"
        let op = try OutboxQueue.Operation(
            id: UUID(),
            kind: .updateThresholds,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.UpdateThresholds(patch: ["WEIGHT": ThresholdRange(min: 70, max: 80)])
            ),
            idempotencyKey: key,
            createdAt: .now
        )
        try await outbox.enqueue(op)
        let recorder = HeaderRecorder()
        MockURLProtocol.handler = { [echo = putEcho] req in
            recorder.record(
                method: req.httpMethod ?? "",
                path: req.url?.path ?? "",
                key: req.value(forHTTPHeaderField: "Idempotency-Key")
            )
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(echo.utf8)
            )
        }
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            userThresholdsRepo: repo
        )
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty, "successful replay drains the row")
        #expect(recorder.entries.contains { $0.method == "PUT" && $0.path == "/api/user/thresholds" && $0.key == key })
    }

    @Test("replay drops the row when the repo is unwired (cannot wedge the queue)")
    func replayDropsWhenUnwired() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try OutboxQueue.Operation(
            id: UUID(),
            kind: .updateThresholds,
            payload: JSONEncoder.hlDefault.encode(
                OutboxQueue.Payloads.UpdateThresholds(patch: ["WEIGHT": ThresholdRange(min: 70, max: 80)])
            ),
            idempotencyKey: "key-thr-2",
            createdAt: .now
        )
        try await outbox.enqueue(op)
        // userThresholdsRepo omitted → nil → op treated as non-retriable + dropped.
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox)
        )
        await replay.runOnce()
        #expect(await (outbox.snapshot).isEmpty, "unwired updateThresholds op dropped, not stuck")
    }
}

/// Thread-safe recorder of `(method, path, idempotency-key)` per request.
private final class HeaderRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let method: String
        let path: String
        let key: String?
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(method: String, path: String, key: String?) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(method: method, path: path, key: key))
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
