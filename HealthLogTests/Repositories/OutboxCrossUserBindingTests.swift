import Foundation
import SwiftData
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// **v0.13 WS Item 1 — cross-user outbox binding (Medium security).**
///
/// On a shared device a queued write owned by User A survives A's sign-out
/// (the `.userInitiated`/`.tokenExpired` paths keep the outbox + cipher key).
/// Before this wave, when User B signed in, the replay loop fired A's row under
/// B's bearer token → A's health data POSTed into B's account. The fix stamps
/// each row with its owning `KeychainKey.userID` at enqueue and replays ONLY
/// rows whose owner matches the current signed-in user; a foreign row is
/// dead-lettered, never replayed.
@Suite("Outbox cross-user binding", .serialized)
struct OutboxCrossUserBindingTests {
    private static let measurementSuccessBody = Data(
        #"""
        {
          "data": {
            "id": "srv-x", "type": "WEIGHT", "value": 81.0, "unit": "kg",
            "measuredAt": "2026-05-01T10:00:00Z", "createdAt": "2026-05-01T10:00:00Z",
            "source": "MANUAL", "externalId": null, "note": null
          }
        }
        """#.utf8
    )

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

    private func makeReplay(
        api: APIClient,
        outbox: OutboxQueue,
        workoutsRepo: WorkoutsRepository? = nil,
        currentUser: @escaping @Sendable () -> String?
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            workoutsRepo: workoutsRepo,
            currentUserProvider: currentUser,
            maxAttempts: 8
        )
    }

    private func encodeMeasurement() throws -> Data {
        let m = Measurement(
            id: "local-x",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
            value: .scalar(81.0)
        )
        return try JSONEncoder.hlDefault.encode(m)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: - The leak: A's row must NOT replay under B

    @Test("Row enqueued under user A is dead-lettered (never POSTed) when user B is current")
    func foreignOwnedRowDeadLettered() async throws {
        let api = makeAPI()
        // Enqueue under user A: the queue stamps its owner from the provider.
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-A" })
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-A"
        ))
        // Sanity: the row carries A's owner.
        #expect(await outbox.snapshot.first?.ownerUserID == "user-A")

        // Now user B is signed in and the replay loop fires.
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox, currentUser: { "user-B" })
        await replay.runOnce()

        // The leak is closed: the server was NEVER hit for A's row under B,
        // and the foreign row is removed (dead-lettered), not stuck forever.
        #expect(attempts.current == 0, "A's row must never POST under B's token")
        #expect(await outbox.snapshot.isEmpty, "foreign-owned row must be dead-lettered")
    }

    @Test("Foreign-owned workout replay is dead-lettered before acceptance dispatch")
    func foreignOwnedWorkoutRowDeadLettered() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-A" })
        let workout = WorkoutIngestDTO(
            sportType: "running",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            endedAt: Date(timeIntervalSince1970: 1_750_001_800),
            externalId: "hk:foreign-owner"
        )
        let payload = try JSONEncoder.hlDefault.encode(
            OutboxQueue.Payloads.UploadWorkoutBatch(workouts: [workout])
        )
        try await outbox.enqueue(.init(
            kind: .uploadWorkoutBatch,
            payload: payload,
            idempotencyKey: "key-workout-A"
        ))

        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            let body = #"{"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted"}]},"error":null}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let workoutsRepo = WorkoutsRepository(api: api, outbox: outbox)
        let replay = makeReplay(
            api: api,
            outbox: outbox,
            workoutsRepo: workoutsRepo,
            currentUser: { "user-B" }
        )
        await replay.runOnce()

        #expect(attempts.current == 0, "owner mismatch must stop workout replay before the wire")
        #expect(await outbox.snapshot.isEmpty, "foreign workout row keeps the established dead-letter behavior")
    }

    // MARK: - No regression: same-user offline replay still works

    @Test("Same-user enqueue + replay still drains (no regression to legit offline path)")
    func sameUserReplayStillWorks() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-A" })
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-A-same"
        ))
        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.measurementSuccessBody
            )
        }
        // Same user A is signed in at replay time → row replays for real.
        let replay = makeReplay(api: api, outbox: outbox, currentUser: { "user-A" })
        await replay.runOnce()

        #expect(attempts.current == 1, "same-user row must replay exactly once")
        #expect(await outbox.snapshot.isEmpty, "successful same-user replay removes the row")
    }

    // MARK: - Legacy nil-owner is quarantined, not adopted (Phase 07)

    /// **Phase 07 inverts the v0.13 transitional rule this test used to pin.**
    ///
    /// Until now a row with no recorded owner replayed as if the signed-in user
    /// had written it. That was the pragmatic choice while the owner stamp was
    /// brand new and the only alternative was dropping the write — but it is
    /// adoption: the account that happens to be signed in becomes the author of
    /// health data whose provenance nobody established. On a shared device that
    /// files one person's measurements into another person's record.
    ///
    /// The row is now quarantined instead: retained on disk, never transmitted,
    /// never deleted, never re-stamped. Nothing is lost — the write is still
    /// there and still inspectable — but nobody inherits it by accident.
    @Test("Legacy nil-owner row is quarantined while a named account is signed in")
    func legacyNilOwnerIsQuarantinedUnderSignedInAccount() async throws {
        let api = makeAPI()
        // Pre-WS row: explicitly nil owner (the queue won't override a caller's
        // value only when set; here we bypass the stamp by enqueuing directly
        // through the store with a nil owner, mimicking an on-disk legacy row).
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        try await store.enqueue(
            id: UUID(),
            kindRaw: "createMeasurement",
            payload: encodeMeasurement(),
            idempotencyKey: "key-legacy",
            createdAt: .now,
            ownerUserID: nil
        )
        let outbox = OutboxQueue(testContainer: container, currentOwnerProvider: { "user-current" })
        #expect(await outbox.snapshot.first?.ownerUserID == nil)

        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.measurementSuccessBody
            )
        }
        let replay = makeReplay(api: api, outbox: outbox, currentUser: { "user-current" })
        await replay.runOnce()

        #expect(attempts.current == 0, "an unowned row must never POST under the ambient account")
        let remaining = await outbox.snapshot
        #expect(remaining.count == 1, "the write is retained, not deleted")
        #expect(remaining.first?.ownerUserID == nil, "the row must never be re-stamped with the signed-in owner")
    }

    /// The other half of the same rule. While nobody is signed in there is no
    /// account to adopt the row into and no bearer to send it under, so the
    /// established signed-out drain is untouched: an unowned row still replays.
    @Test("Legacy nil-owner row still drains while no account is signed in")
    func legacyNilOwnerStillDrainsWhileSignedOut() async throws {
        let api = makeAPI()
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        try await store.enqueue(
            id: UUID(),
            kindRaw: "createMeasurement",
            payload: encodeMeasurement(),
            idempotencyKey: "key-legacy-signed-out",
            createdAt: .now,
            ownerUserID: nil
        )
        let outbox = OutboxQueue(testContainer: container, currentOwnerProvider: { nil })

        let attempts = Counter()
        MockURLProtocol.handler = { req in
            _ = attempts.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.measurementSuccessBody
            )
        }
        let replay = makeReplay(api: api, outbox: outbox, currentUser: { nil })
        await replay.runOnce()

        #expect(attempts.current == 1, "no ambient account means no adoption hazard")
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - The chokepoint stamps the live signed-in user

    @Test("Enqueue chokepoint stamps the live signed-in userID from Keychain")
    func enqueueStampsLiveUser() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("kc-user-42", forKey: KeychainKey.userID)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: {
            keychain.getString(forKey: KeychainKey.userID)
        })
        try await outbox.enqueue(.init(
            id: UUID(),
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "key-kc"
        ))
        #expect(await outbox.snapshot.first?.ownerUserID == "kc-user-42")
    }

    @Test("Explicit owner enqueue rejects a stale auth lease")
    func explicitOwnerRejectsStaleLease() async throws {
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-B" },
            currentAuthTokenProvider: { "token-B" }
        )
        let operation = OutboxQueue.Operation(
            kind: .uploadWorkoutBatch,
            payload: Data(),
            idempotencyKey: "stale-owner",
            ownerUserID: "user-A"
        )

        await #expect(throws: OutboxQueue.OwnerLeaseError.self) {
            try await outbox.enqueue(operation, requiringCurrentOwner: "user-A")
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("Explicit owner enqueue rejects a signed-out lease even while userID remains")
    func explicitOwnerRejectsRemovedToken() async throws {
        let outbox = try OutboxQueue(
            inMemory: true,
            currentOwnerProvider: { "user-A" },
            currentAuthTokenProvider: { nil }
        )
        let operation = OutboxQueue.Operation(
            kind: .uploadWorkoutBatch,
            payload: Data(),
            idempotencyKey: "removed-token",
            ownerUserID: "user-A"
        )

        await #expect(throws: OutboxQueue.OwnerLeaseError.self) {
            try await outbox.enqueue(operation, requiringCurrentOwner: "user-A")
        }
        #expect(await outbox.snapshot.isEmpty)
    }
}

// swiftlint:enable force_unwrapping force_try
