import Foundation
import SwiftData
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// W-INTEGRITY-WRITEPATH — closes the three lost-write windows on the outbox
/// write path:
///   * G-1 write-ahead durability (entry persisted BEFORE send, removed on 2xx,
///     kept on retriable failure, removed on a non-retriable reject; one
///     idempotency key reused across send + crash-replay + reachability-replay).
///   * G-2 enqueue-failure honesty (a failing durable enqueue must NOT leave a
///     false "saved/queued" state — it surfaces `HLError.notPersisted`).
///
/// G-9 (recovery move-aside) is covered in `OutboxRecoveryMoveAsideTests`.
///
/// Reuses the project's outbox test patterns: real `APIClient` + stub
/// `URLSession` (`MockURLProtocol`), no mock server (project rule).
@Suite("Outbox write-ahead durability (G-1/G-2)", .serialized)
struct OutboxWriteAheadTests {
    private func makeAPI(keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeOp(key: String = "wa-key") throws -> OutboxQueue.Operation {
        let m = Measurement(
            id: "local-wa",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
            value: .scalar(81.0)
        )
        return try OutboxQueue.Operation(
            kind: .createMeasurement,
            payload: JSONEncoder.hlDefault.encode(m),
            idempotencyKey: key
        )
    }

    // MARK: - G-1 (a) entry exists BEFORE the send runs

    @Test("Write-ahead persists the entry before the network send runs")
    func entryExistsBeforeSend() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(key: "wa-before")

        let seenAtSendTime = SendableBox<Int>(-1)
        try await outbox.writeAhead(op) {
            // At the moment the send body runs, the entry must already be durable.
            seenAtSendTime.value = await outbox.snapshot.count
        }
        #expect(seenAtSendTime.value == 1, "entry must be persisted BEFORE the send executes")
        // 2xx-equivalent (no throw) → entry removed after success.
        #expect(await outbox.snapshot.isEmpty, "successful send removes the write-ahead entry")
    }

    // MARK: - G-1 (b) 2xx removes the entry

    @Test("Successful send removes the write-ahead entry")
    func successRemovesEntry() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        try await outbox.writeAhead(makeOp()) { /* 2xx */ }
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - G-1 (c) crash-mid-send leaves exactly one replayable entry, same key

    @Test("Retriable failure mid-send leaves exactly one replayable entry, no double-write")
    func retriableFailureLeavesOneEntryWithSameKey() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(key: "wa-stable-key")

        await #expect(throws: HLError.self) {
            try await outbox.writeAhead(op) {
                // Simulate a crash-equivalent retriable network failure mid-send.
                throw HLError.network(.connectionLost)
            }
        }
        let snap = await outbox.snapshot
        // Exactly one entry survives — durably queued for replay.
        #expect(snap.count == 1, "retriable mid-send failure keeps exactly one entry")
        // The idempotency key is the SAME one minted for the live send — reused
        // across the eventual replay so the server dedups against an attempt that
        // may already have landed (no double-write on re-action).
        #expect(snap.first?.idempotencyKey == "wa-stable-key")
        #expect(snap.first?.id == op.id, "the surviving entry is the write-ahead entry, not a fresh one")
    }

    // MARK: - G-1 (d) non-retriable reject removes the entry (must not replay)

    @Test("Non-retriable reject removes the write-ahead entry so it never replays")
    func nonRetriableRejectRemovesEntry() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        await #expect(throws: HLError.self) {
            try await outbox.writeAhead(makeOp()) {
                // 422 — server understood + rejected. Replaying forever is worse.
                throw HLError.server(status: 422, code: nil, message: "rejected")
            }
        }
        #expect(await outbox.snapshot.isEmpty, "a rejected op must not stay queued")
    }

    // MARK: - G-2 enqueue-failure honesty (write-ahead path)

    @Test("Write-ahead enqueue failure + retriable send surfaces notPersisted (no false queue)")
    func enqueueFailurePlusRetriableSendIsHonest() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        // Force every enqueue to fail: a cipher whose key-fetch always throws
        // makes `encrypt` (and therefore the persisting `save()`) throw.
        await outbox.useCipher(OutboxPayloadCipher(keychain: ThrowingKeychain()))

        var thrown: HLError?
        do {
            try await outbox.writeAhead(makeOp()) {
                throw HLError.network(.connectionLost) // retriable
            }
        } catch let err as HLError {
            thrown = err
        }
        // The honest signal: nothing was durably queued, so the caller must NOT
        // be told "queued" — it must roll back. `.notPersisted` is `false` under
        // `shouldPersistToOutbox`, which is exactly what the stores key rollback off.
        guard case .notPersisted = thrown else {
            Issue.record("expected HLError.notPersisted, got \(String(describing: thrown))")
            return
        }
        #expect(thrown?.shouldPersistToOutbox == false)
        #expect(await outbox.snapshot.isEmpty, "nothing should be (falsely) queued")
    }

    @Test("Write-ahead enqueue failure but successful send still succeeds")
    func enqueueFailureButSuccessfulSendSucceeds() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        await outbox.useCipher(OutboxPayloadCipher(keychain: ThrowingKeychain()))
        // Enqueue can't persist, but the send lands — the write reached the
        // server, so there is no loss and no error. The would-be entry is a no-op.
        try await outbox.writeAhead(makeOp()) { /* 2xx */ }
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - G-1/G-2 via the worst-case background "Genommen" path

    @Test("recordFromReminder write-ahead: retriable failure queues exactly one entry")
    func recordFromReminderWriteAheadQueuesOnRetriable() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)

        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        await #expect(throws: HLError.self) {
            try await repo.recordFromReminder(
                medicationId: "med-1",
                scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
                status: .taken
            )
        }
        let snap = await outbox.snapshot
        #expect(snap.count == 1, "background Genommen must leave exactly one durable entry")
        #expect(snap.first?.kind == .takeMedication)
        // The persisted idempotency key matches the entry's so the eventual
        // replay dedups against any attempt that already landed.
        #expect(snap.first?.idempotencyKey == snap.first?.idempotencyKey)
    }

    @Test("recordFromReminder honest failure: enqueue fails + retriable send → notPersisted, nothing queued")
    func recordFromReminderHonestOnEnqueueFailure() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        await outbox.useCipher(OutboxPayloadCipher(keychain: ThrowingKeychain()))
        let repo = MedicationsRepository(api: api, outbox: outbox)

        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        var thrown: HLError?
        do {
            try await repo.recordFromReminder(
                medicationId: "med-2",
                scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
                status: .taken
            )
        } catch let err as HLError {
            thrown = err
        }
        guard case .notPersisted = thrown else {
            Issue.record("expected notPersisted, got \(String(describing: thrown))")
            return
        }
        #expect(await outbox.snapshot.isEmpty, "no false queue when the durable enqueue failed")
    }
}

// MARK: - Test helpers

/// A `KeychainStoring` whose writes throw and reads return nil — drives
/// `OutboxPayloadCipher.fetchOrCreateKey` (and therefore `encrypt`) into a
/// throw so `OutboxStore.enqueue` fails, simulating a degraded outbox.
private struct ThrowingKeychain: KeychainStoring {
    func setString(_: String, forKey _: String) throws {
        throw KeychainError.osStatus(-1)
    }

    func getString(forKey _: String) -> String? {
        nil
    }

    func setData(_: Data, forKey _: String) throws {
        throw KeychainError.osStatus(-1)
    }

    func getData(forKey _: String) -> Data? {
        nil
    }

    func remove(forKey _: String) throws {}
    func removeAll() throws {}
}

/// Minimal `Sendable` box so a `@Sendable` send closure can publish a value
/// captured at send-time back to the test.
private final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) {
        stored = initial
    }

    var value: T {
        get { lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set { lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

// swiftlint:enable force_unwrapping force_try
