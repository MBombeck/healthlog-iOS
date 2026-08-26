import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// Phase 07 Wave 1 — `syncHealthKitSample` is a durable, owner-bound replay path.
///
/// Before this wave the kind was enqueued but never drained: the dispatcher
/// threw a non-retriable error and the row was deleted, so every transient
/// failure of a measurement batch cost the samples permanently while the anchor
/// had already moved past them. These tests pin the four properties that make
/// the row a real retry: exact wire bytes, one stable identity across restart,
/// exact indexed acceptance, and an owner gate ahead of the wire.
@Suite("Outbox HealthKit batch replay", .serialized)
struct OutboxHealthKitBatchReplayTests {
    private static let acceptedBody = Data(
        #"""
        {"data":{"processed":2,"inserted":2,"duplicates":0,"skipped":[],
        "entries":[{"index":0,"status":"inserted"},{"index":1,"status":"inserted"}]},"error":null}
        """#.utf8
    )

    /// HTTP 200 with only one of two posted indexes accounted for.
    private static let partialBody = Data(
        #"""
        {"data":{"processed":2,"inserted":1,"duplicates":0,"skipped":[],
        "entries":[{"index":0,"status":"inserted"}]},"error":null}
        """#.utf8
    )

    private static let entries: [HealthKitBatchEntryDTO] = [
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierBodyMass",
            value: 81.0,
            unit: "kg",
            startDate: Date(timeIntervalSince1970: 1_755_000_000),
            endDate: Date(timeIntervalSince1970: 1_755_000_000),
            externalId: "hk:sample-1"
        ),
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierBodyMass",
            value: 81.5,
            unit: "kg",
            startDate: Date(timeIntervalSince1970: 1_755_003_600),
            endDate: Date(timeIntervalSince1970: 1_755_003_600),
            externalId: "hk:sample-2"
        )
    ]

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String] = []
        private var bodies: [Data] = []

        func record(key: String?, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            if let key { keys.append(key) }
            if let body { bodies.append(body) }
        }

        var recordedKeys: [String] {
            lock.lock()
            defer { lock.unlock() }
            return keys
        }

        var recordedBodies: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodies
        }
    }

    private func makeAPI() -> APIClient {
        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: environment, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeReplay(
        api: APIClient,
        outbox: OutboxQueue,
        currentUser: @escaping @Sendable () -> String?
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: currentUser,
            maxAttempts: 8,
            attemptBackoff: 0
        )
    }

    private func stableKey(owner: String, identity: String) throws -> String {
        try #require(
            HealthSyncRetryEnvelope(ownerID: owner, source: .speziSamples, stableIdentity: identity)
        ).idempotencyKey
    }

    // MARK: - Enqueue

    @Test("the importer overload persists the exact wire bytes, the owner, and a derived key")
    func enqueuePersistsBytesOwnerAndDerivedKey() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        let key = try stableKey(owner: "user-a", identity: "hk:sample-1")

        try await outbox.enqueueHealthKitBatch(
            Self.entries,
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: "user-a"
        )

        let rebuiltAfterRelaunch = try stableKey(owner: "user-a", identity: "hk:sample-1")
        let op = try #require(await outbox.snapshot.first)
        #expect(op.kind == .syncHealthKitSample)
        #expect(op.ownerUserID == "user-a")
        #expect(op.idempotencyKey == key)
        #expect(op.idempotencyKey == rebuiltAfterRelaunch, "the key is derived, so a relaunch rebuilds it")

        let decoded = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: op.payload)
        #expect(decoded.entries.map(\.externalId) == ["hk:sample-1", "hk:sample-2"])
        #expect(decoded.syncTrigger == nil)
    }

    @Test("an importer enqueue is refused once the captured owner is no longer live")
    func enqueueRefusesStaleOwner() async throws {
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-b" },
            currentAuthTokenProvider: { "token-b" }
        )
        let key = try stableKey(owner: "user-a", identity: "hk:sample-1")

        await #expect(throws: OutboxQueue.OwnerLeaseError.self) {
            try await outbox.enqueueHealthKitBatch(
                Self.entries,
                encoder: .hlBatch,
                idempotencyKey: key,
                requiringCurrentOwner: "user-a"
            )
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Replay

    @Test("replay re-POSTs under the persisted key and drains on exact acceptance")
    func replayDrainsOnExactAcceptance() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        let key = try stableKey(owner: "user-a", identity: "hk:sample-1")
        try await outbox.enqueueHealthKitBatch(
            Self.entries,
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: "user-a"
        )

        let recorder = Recorder()
        MockURLProtocol.handler = { request in
            if request.targets("/api/measurements/batch") {
                recorder.record(
                    key: request.value(forHTTPHeaderField: "Idempotency-Key"),
                    body: request.healthKitBatchBodyBytes()
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.acceptedBody
            )
        }
        let api = makeAPI()
        await makeReplay(api: api, outbox: outbox, currentUser: { "user-a" }).runOnce()

        #expect(recorder.recordedKeys == [key], "replay reuses the persisted idempotency key")
        let body = try #require(recorder.recordedBodies.first)
        let sent = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: body)
        #expect(sent.entries.map(\.externalId) == ["hk:sample-1", "hk:sample-2"])
        #expect(await outbox.snapshot.isEmpty, "exact acceptance drains the row")
    }

    @Test("an HTTP-200 response that does not cover every posted index stays retryable")
    func ambiguousAcceptanceStaysRetryable() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        let key = try stableKey(owner: "user-a", identity: "hk:sample-1")
        try await outbox.enqueueHealthKitBatch(
            Self.entries,
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: "user-a"
        )

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.partialBody
            )
        }
        let api = makeAPI()
        await makeReplay(api: api, outbox: outbox, currentUser: { "user-a" }).runOnce()

        let remaining = try #require(await outbox.snapshot.first)
        #expect(remaining.idempotencyKey == key, "the row keeps its identity for the next attempt")
        #expect(remaining.attempts == 1)
    }

    @Test("a foreign-owned batch never reaches the wire")
    func foreignOwnedBatchNeverTransmits() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        let key = try stableKey(owner: "user-a", identity: "hk:sample-1")
        try await outbox.enqueueHealthKitBatch(
            Self.entries,
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: "user-a"
        )

        let recorder = Recorder()
        MockURLProtocol.handler = { request in
            recorder.record(key: request.value(forHTTPHeaderField: "Idempotency-Key"), body: nil)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.acceptedBody
            )
        }
        let api = makeAPI()
        await makeReplay(api: api, outbox: outbox, currentUser: { "user-b" }).runOnce()

        #expect(recorder.recordedKeys.isEmpty, "the owner gate stops the batch before the wire")
    }

    // MARK: - Restart

    @Test("a restart drains the same operation exactly once under the same identity")
    func restartDrainsTheSameOperationOnce() async throws {
        let container = try OutboxStore.makeInMemory()
        let key = try stableKey(owner: "user-a", identity: "hk:sample-1")

        // D-13-04-A. `OutboxQueue(testContainer:)` is also a production
        // recovery path, so it correctly sets `allowsUnauthenticatedTestLease`
        // to `false` and correctly defaults `currentAuthTokenProvider` to the
        // real Keychain. Both are right, and neither may be weakened to make a
        // test pass. What was wrong was HERE: this case established an owner
        // but no bearer, so `captureAuthLease`'s `!bearer.isEmpty` guard read
        // whatever the gate simulator's Keychain happened to hold. It was green
        // exactly when a preceding run had left an auth token behind and red
        // otherwise — measured both ways at plan 14-07 on one tree, one
        // selector and one simulator: 6/7 with `.staleOwner` after
        // `simctl keychain reset`, 7/7 after a run that seeded a token.
        //
        // The fixture now establishes the credential generation it needs, the
        // same way every other lease-taking suite in this target already does.
        // A constant is exactly right: both processes model the SAME signed-in
        // session across a restart, so the lease captured by A must still
        // validate under B, and `validateAuthLease` compares the live token to
        // the captured one after every suspension.
        let sessionToken: @Sendable () -> String? = { "token-a" }

        // Process A enqueues, then dies before the drain.
        let queueA = OutboxQueue(
            testContainer: container,
            currentOwnerProvider: { "user-a" },
            currentAuthTokenProvider: sessionToken
        )
        try await queueA.enqueueHealthKitBatch(
            Self.entries,
            encoder: .hlBatch,
            idempotencyKey: key,
            requiringCurrentOwner: "user-a"
        )

        // Process B opens the same store and drains it, under the same session.
        let queueB = OutboxQueue(
            testContainer: container,
            currentOwnerProvider: { "user-a" },
            currentAuthTokenProvider: sessionToken
        )
        let recorder = Recorder()
        MockURLProtocol.handler = { request in
            if request.targets("/api/measurements/batch") {
                recorder.record(key: request.value(forHTTPHeaderField: "Idempotency-Key"), body: nil)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.acceptedBody
            )
        }
        let api = makeAPI()
        let replay = makeReplay(api: api, outbox: queueB, currentUser: { "user-a" })
        await replay.runOnce()
        await replay.runOnce()

        #expect(recorder.recordedKeys == [key], "the restarted drain posts once, under the identity A minted")
        #expect(await queueB.snapshot.isEmpty)
    }

    // MARK: - Device-forwarder compatibility

    @Test("the device-forwarder conformance still enqueues the same payload shape")
    func deviceForwarderConformanceIsUnchanged() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })

        try await outbox.enqueueBatch(Self.entries, encoder: .hlBatch)

        let op = try #require(await outbox.snapshot.first)
        #expect(op.kind == .syncHealthKitSample)
        #expect(op.ownerUserID == "user-a", "the enqueue chokepoint still stamps the live owner")
        let decoded = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: op.payload)
        #expect(decoded.entries.count == 2)
    }
}

private extension URLRequest {
    /// Reads either `httpBody` or `httpBodyStream` (URLSession converts POST
    /// bodies to upload streams depending on session config). File-local twin of
    /// the same helper in `WorkoutOutboxTests`, which is `fileprivate` there.
    func healthKitBatchBodyBytes() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping
