import Foundation
@testable import HealthLog
import Synchronization
import Testing

// One serialized real-API wire harness intentionally keeps enrollment, replay,
// partial acceptance, and auth-lease regressions together.
// swiftlint:disable force_unwrapping type_body_length

/// **Audit v0.14.8 Wave A (C4.1)** — locks the Outbox-Mandate compliance of the
/// workout batch upload: a retriably-failed `POST /api/workouts/batch` enrolls
/// as `.uploadWorkoutBatch` carrying the SAME idempotency key that was used on
/// the wire; replay re-issues the POST under that persisted key; success
/// dequeues; a retriable replay failure keeps the row (attempts incremented).
///
/// Repo rule: real `APIClient` + stub `URLProtocol` — NO mock server on outbox
/// replay paths (schema drift would otherwise go unnoticed, `0.2.0` audit).
///
/// Failure stubs answer **408** (not 5xx): a 5xx exercises `APIClient.execute`'s
/// in-request retry loop with real backoff sleeps, while a 408 surfaces as a
/// retriable `HLError.server` immediately — same `shouldPersistToOutbox` arm,
/// deterministic single wire call.
@Suite("Workout batch upload — Outbox-Mandate (C4.1)", .serialized)
struct WorkoutOutboxTests {
    enum IncompleteAcceptance: String, CaseIterable, Sendable {
        case partial
        case skipped
        case missing
        case duplicateIndex
        case outOfRangeIndex
        case unknownStatus

        var responseBody: Data {
            let entries = switch self {
            case .partial:
                #"[{"index":0,"status":"inserted"},{"index":1,"status":"skipped"}]"#
            case .skipped:
                #"[{"index":0,"status":"skipped"},{"index":1,"status":"skipped"}]"#
            case .missing:
                #"[{"index":0,"status":"inserted"}]"#
            case .duplicateIndex:
                #"[{"index":0,"status":"inserted"},{"index":0,"status":"duplicate"}]"#
            case .outOfRangeIndex:
                #"[{"index":0,"status":"inserted"},{"index":2,"status":"inserted"}]"#
            case .unknownStatus:
                #"[{"index":0,"status":"inserted"},{"index":1,"status":"deferred"}]"#
            }
            return Data(
                #"{"data":{"processed":2,"inserted":1,"duplicates":0,"entries":\#(entries)},"error":null}"#.utf8
            )
        }
    }

    private func makeAPI(
        keychain: InMemoryKeychain? = nil,
        onUnauthorized: (@Sendable () async -> Void)? = nil,
        refreshHandler: (@Sendable () async -> RefreshOutcome)? = nil
    ) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let kc = keychain ?? InMemoryKeychain()
        if kc.getString(forKey: KeychainKey.authToken) == nil {
            try? kc.setString("token", forKey: KeychainKey.authToken)
        }
        return APIClient(
            environment: env,
            keychain: kc,
            sessionConfiguration: .mock(),
            onUnauthorized: onUnauthorized,
            refreshHandler: refreshHandler
        )
    }

    private func makeWorkouts() -> [WorkoutIngestDTO] {
        [
            WorkoutIngestDTO(
                sportType: "running",
                startedAt: Date(timeIntervalSince1970: 1_750_000_000),
                endedAt: Date(timeIntervalSince1970: 1_750_001_800),
                totalEnergyKcal: 320,
                totalDistanceM: 5000,
                avgHeartRate: 150,
                externalId: "hk:wo-1"
            ),
            WorkoutIngestDTO(
                sportType: "cycling",
                startedAt: Date(timeIntervalSince1970: 1_750_100_000),
                endedAt: Date(timeIntervalSince1970: 1_750_103_600),
                externalId: "hk:wo-2"
            )
        ]
    }

    private static let successBody = Data(
        #"{"data":{"processed":2,"inserted":2,"duplicates":0,"entries":[{"index":0,"status":"inserted"},{"index":1,"status":"inserted"}]},"error":null}"#
            .utf8
    )

    private static let mixedAcceptanceBody = Data(
        #"{"data":{"processed":3,"inserted":1,"duplicates":1,"entries":[{"index":2,"status":"enriched"},{"index":0,"status":"inserted"},{"index":1,"status":"duplicate"}]},"error":null}"#
            .utf8
    )

    // MARK: - Enrollment

    @Test("retriable failure enrolls .uploadWorkoutBatch with the wire idempotency key")
    func retriableFailureEnrollsWithStableKey() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        nonisolated(unsafe) var wireKey: String?
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — record only OUR route.
            if req.targets("/api/workouts/batch") {
                wireKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 408, httpVersion: nil, headerFields: nil)!, Data())
        }
        let workouts = makeWorkouts()
        await #expect(throws: HLError.self) {
            try await repo.uploadBatch(workouts)
        }
        let snap = await outbox.snapshot
        #expect(snap.count == 1, "retriable upload failure must enroll exactly one op")
        let op = try #require(snap.first)
        #expect(op.kind == .uploadWorkoutBatch)
        #expect(wireKey?.isEmpty == false)
        #expect(op.idempotencyKey == wireKey, "persisted key must be the SAME key already used on the wire")
        // Payload survives the encode→persist→decode roundtrip intact.
        let decoded = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.UploadWorkoutBatch.self, from: op.payload)
        #expect(decoded.workouts == workouts)
    }

    @Test("captured workout owner is persisted instead of being resolved after failure")
    func capturedOwnerIsPersisted() async throws {
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-A" },
            currentAuthTokenProvider: { "token-A" }
        )
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 408, httpVersion: nil, headerFields: nil)!, Data())
        }

        await #expect(throws: HLError.self) {
            try await repo.uploadBatch(makeWorkouts(), ownerUserID: "user-A")
        }

        let operation = try #require(await outbox.snapshot.first)
        #expect(operation.ownerUserID == "user-A")
    }

    @Test("logout and login as B during A's failed upload rejects stale enqueue")
    func accountSwitchDuringFailedUploadRejectsEnqueue() async throws {
        let currentOwner = Mutex("user-A")
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: {
                currentOwner.withLock { $0 }
            },
            currentAuthTokenProvider: { "token-A" }
        )
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        MockURLProtocol.handler = { req in
            currentOwner.withLock { $0 = "user-B" }
            return (HTTPURLResponse(url: req.url!, statusCode: 408, httpVersion: nil, headerFields: nil)!, Data())
        }

        await #expect(throws: OutboxQueue.OwnerLeaseError.self) {
            try await repo.uploadBatch(makeWorkouts(), ownerUserID: "user-A")
        }

        #expect(await outbox.snapshot.isEmpty, "A's failed write must never be stamped as B")
    }

    @Test("Account-bound upload rejects before wire when its bearer was removed")
    func removedBearerRejectsBeforeWire() async throws {
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-A" },
            currentAuthTokenProvider: { nil }
        )
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        let calls = Mutex(0)
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch") {
                calls.withLock { $0 += 1 }
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.successBody)
        }

        await #expect(throws: OutboxQueue.OwnerLeaseError.self) {
            try await repo.uploadBatch(makeWorkouts(), ownerUserID: "user-A")
        }

        #expect(calls.withLock { $0 } == 0)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("non-retriable 422 does NOT enroll")
    func nonRetriableFailureDoesNotEnroll() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"workout.batch.too_large"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        await #expect(throws: HLError.self) {
            try await repo.uploadBatch(makeWorkouts())
        }
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "a request the server understood and rejected must not replay forever")
    }

    @Test("success posts the batch once and leaves the outbox empty")
    func successDoesNotEnroll() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.successBody)
        }
        let response = try await repo.uploadBatch(makeWorkouts())
        #expect(response.inserted == 2)
        #expect(calls == 1)
        let snap = await outbox.snapshot
        #expect(snap.isEmpty)
    }

    // MARK: - Replay

    private func makeReplay(outbox: OutboxQueue, repo: WorkoutsRepository, api: APIClient) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            workoutsRepo: repo,
            currentUserProvider: { nil },
            attemptBackoff: 0
        )
    }

    private func enqueueReplayBatch(
        _ workouts: [WorkoutIngestDTO],
        key: String,
        in outbox: OutboxQueue
    ) async throws {
        let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UploadWorkoutBatch(workouts: workouts))
        try await outbox.enqueue(.init(kind: .uploadWorkoutBatch, payload: payload, idempotencyKey: key))
    }

    @Test("replay re-POSTs under the persisted key; success dequeues")
    func replayUsesPersistedKeyAndDequeues() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let workouts = makeWorkouts()
        let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UploadWorkoutBatch(workouts: workouts))
        try await outbox.enqueue(.init(kind: .uploadWorkoutBatch, payload: payload, idempotencyKey: "idem-workout-1"))

        nonisolated(unsafe) var hitBatch = false
        nonisolated(unsafe) var replayKey: String?
        nonisolated(unsafe) var bodyData: Data?
        MockURLProtocol.handler = { req in
            // CU-07: a parallel suite's request must not clear `hitBatch` again
            // nor overwrite the recorded key/body.
            if req.targets("/api/workouts/batch") {
                hitBatch = true
                replayKey = req.value(forHTTPHeaderField: "Idempotency-Key")
                bodyData = req.bodyBytes()
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.successBody)
        }
        let api = makeAPI()
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        await makeReplay(outbox: outbox, repo: repo, api: api).runOnce()

        #expect(hitBatch, "workout replay must drain through POST /api/workouts/batch")
        #expect(replayKey == "idem-workout-1", "replay reuses the persisted idempotency key")
        let json = try #require(bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let sent = try #require(json["workouts"] as? [[String: Any]])
        #expect(sent.count == 2)
        #expect(sent.first?["externalId"] as? String == "hk:wo-1")
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "successful replay removes the op")
    }

    @Test("Bearer rotation after replay owner gate causes zero wire calls and retains the row")
    func replayBearerRotationBeforeWireRetainsRow() async throws {
        let tokenReads = Mutex(0)
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-A" },
            currentAuthTokenProvider: {
                tokenReads.withLock { reads in
                    reads += 1
                    return reads == 1 ? "token-A" : "token-B"
                }
            }
        )
        let payload = try JSONEncoder.hlDefault.encode(
            OutboxQueue.Payloads.UploadWorkoutBatch(workouts: makeWorkouts())
        )
        try await outbox.enqueue(.init(
            kind: .uploadWorkoutBatch,
            payload: payload,
            idempotencyKey: "idem-token-switch",
            ownerUserID: "user-A"
        ))
        let calls = Mutex(0)
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch") {
                calls.withLock { $0 += 1 }
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.successBody)
        }
        let api = makeAPI()
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            workoutsRepo: repo,
            currentUserProvider: { "user-A" },
            attemptBackoff: 0
        )

        await replay.runOnce()

        #expect(calls.withLock { $0 } == 0)
        #expect(await outbox.snapshot.first?.idempotencyKey == "idem-token-switch")
    }

    @Test("401 replay never refreshes or adopts a replacement account bearer")
    func replay401NeverTouchesGlobalRefreshBridge() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("token-A", forKey: KeychainKey.authToken)
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-A" },
            currentAuthTokenProvider: {
                keychain.getString(forKey: KeychainKey.authToken)
            }
        )
        let payload = try JSONEncoder.hlDefault.encode(
            OutboxQueue.Payloads.UploadWorkoutBatch(workouts: makeWorkouts())
        )
        try await outbox.enqueue(.init(
            kind: .uploadWorkoutBatch,
            payload: payload,
            idempotencyKey: "idem-401-token-switch",
            ownerUserID: "user-A"
        ))
        let authHeaders = Mutex<[String]>([])
        let refreshCalls = Mutex(0)
        let unauthorizedCalls = Mutex(0)
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch") {
                authHeaders.withLock { $0.append(req.value(forHTTPHeaderField: "Authorization") ?? "") }
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"unauthorized"}"#.utf8)
            )
        }
        let api = makeAPI(
            keychain: keychain,
            onUnauthorized: {
                unauthorizedCalls.withLock { $0 += 1 }
            },
            refreshHandler: {
                refreshCalls.withLock { $0 += 1 }
                try? keychain.setString("token-B", forKey: KeychainKey.authToken)
                return .refreshed
            }
        )
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            workoutsRepo: repo,
            currentUserProvider: { "user-A" },
            attemptBackoff: 0
        )

        await replay.runOnce()

        #expect(authHeaders.withLock { $0 } == ["Bearer token-A"])
        #expect(refreshCalls.withLock { $0 } == 0)
        #expect(unauthorizedCalls.withLock { $0 } == 0)
        #expect(keychain.getString(forKey: KeychainKey.authToken) == "token-A")
        #expect(await outbox.snapshot.first?.idempotencyKey == "idem-401-token-switch")
    }

    @Test("retriable replay failure keeps the op with the same key, attempts incremented")
    func replayRetriableFailureKeepsOp() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UploadWorkoutBatch(workouts: makeWorkouts()))
        try await outbox.enqueue(.init(kind: .uploadWorkoutBatch, payload: payload, idempotencyKey: "idem-workout-2"))

        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 408, httpVersion: nil, headerFields: nil)!, Data())
        }
        let api = makeAPI()
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        await makeReplay(outbox: outbox, repo: repo, api: api).runOnce()

        let snap = await outbox.snapshot
        #expect(snap.count == 1, "a retriable replay failure must keep the row for the next pass")
        #expect(snap.first?.idempotencyKey == "idem-workout-2", "the key survives across replay attempts")
        #expect(snap.first?.attempts == 1)
    }

    @Test(
        "partial, skipped, missing, duplicate-indexed, out-of-range and unknown 2xx responses retain replay",
        arguments: IncompleteAcceptance.allCases
    )
    func incomplete2xxAcceptanceRetainsReplay(fixture: IncompleteAcceptance) async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let key = "idem-incomplete-\(fixture.rawValue)"
        try await enqueueReplayBatch(makeWorkouts(), key: key, in: outbox)

        nonisolated(unsafe) var replayKey: String?
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch") {
                replayKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                fixture.responseBody
            )
        }
        let api = makeAPI()
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        await makeReplay(outbox: outbox, repo: repo, api: api).runOnce()

        let snap = await outbox.snapshot
        #expect(snap.count == 1, "ambiguous 2xx acceptance must retain the durable row")
        #expect(snap.first?.idempotencyKey == key)
        #expect(snap.first?.attempts == 1, "incomplete acceptance remains retryable")
        #expect(replayKey == key)
    }

    @Test("incomplete 2xx retries reuse the original idempotency key")
    func incomplete2xxRetryReusesOriginalKey() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let key = "idem-incomplete-retry"
        try await enqueueReplayBatch(makeWorkouts(), key: key, in: outbox)

        nonisolated(unsafe) var replayKeys: [String] = []
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch"),
               let key = req.value(forHTTPHeaderField: "Idempotency-Key")
            {
                replayKeys.append(key)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                IncompleteAcceptance.partial.responseBody
            )
        }
        let api = makeAPI()
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        let replay = makeReplay(outbox: outbox, repo: repo, api: api)
        await replay.runOnce()
        await replay.runOnce()

        let snap = await outbox.snapshot
        #expect(replayKeys == [key, key])
        #expect(snap.first?.idempotencyKey == key)
        #expect(snap.first?.attempts == 2)
    }

    @Test("complete inserted, duplicate and enriched replay coverage dequeues")
    func completeMixedAcceptanceDequeues() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        var workouts = makeWorkouts()
        workouts.append(
            WorkoutIngestDTO(
                sportType: "swimming",
                startedAt: Date(timeIntervalSince1970: 1_750_200_000),
                endedAt: Date(timeIntervalSince1970: 1_750_201_200),
                externalId: "hk:wo-3"
            )
        )
        try await enqueueReplayBatch(workouts, key: "idem-complete-mixed", in: outbox)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.mixedAcceptanceBody
            )
        }
        let api = makeAPI()
        let repo = WorkoutsRepository(api: api, outbox: outbox)
        await makeReplay(outbox: outbox, repo: repo, api: api).runOnce()

        #expect(await outbox.snapshot.isEmpty, "complete terminal coverage permits durable dequeue")
    }

    @Test("unwired workoutsRepo dead-letters the op instead of wedging the queue")
    func unwiredRepoDeadLetters() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.UploadWorkoutBatch(workouts: makeWorkouts()))
        try await outbox.enqueue(.init(kind: .uploadWorkoutBatch, payload: payload, idempotencyKey: "idem-workout-3"))

        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/workouts/batch") { calls += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.successBody)
        }
        let api = makeAPI()
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: { nil }
        )
        await replay.runOnce()
        #expect(calls == 0, "an unwired arm must never hit the wire")
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "non-retriable drop keeps the queue unwedged")
    }
}

private extension URLRequest {
    /// Reads either `httpBody` or `httpBodyStream` (URLSession converts POST
    /// bodies to upload streams depending on session config).
    func bodyBytes() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping type_body_length
