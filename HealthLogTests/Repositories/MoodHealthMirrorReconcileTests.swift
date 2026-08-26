import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping force_try

/// **v0.10.0 W10 reconcile — mood ↔ Apple Health correctness fixes.**
///
/// M1: an offline-logged mood (queued in the outbox, synced later) must be
/// mirrored into HKStateOfMind on the OUTBOX-REPLAY success path — not only on
/// the online-success branch — so it actually reaches Apple Health. A replayed
/// delete must remove the mirror.
///
/// M2: on logout / user-change the device-local sync toggle must be forced OFF
/// and the per-user import anchor reset, so a different user signing in on the
/// same device does not re-import the previous user's full HKStateOfMind
/// history into their account.
///
/// Real `APIClient` + `MockURLProtocol` for the replay round-trip (per
/// PROJECT_GUIDE.md anti-pattern guidance — mock servers hide schema drift).
@Suite("W10 — mood ↔ Apple Health mirror reconcile", .serialized)
struct MoodHealthMirrorReconcileTests {
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

    /// Server-true wire envelope for `POST /api/mood-entries` — returns the
    /// full `MoodEntry` shape with a server-assigned id.
    private let moodPostResponse = """
    {"id":"srv-mood-99","mood":"GUT","tags":["happy"],\
    "moodLoggedAt":"2026-05-01T10:00:00Z","source":"MANUAL","note":null}
    """

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

    // MARK: - M1 — offline-replay mirrors to HealthKit

    @Test("M1: a replayed offline logMood mirrors the SERVER entry into HealthKit")
    func replayedLogMoodMirrorsToHK() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        // The offline-queued entry carries a local-<UUID> id (the optimistic
        // local row). After replay the server assigns srv-mood-99 — the mirror
        // must receive the SERVER entry (so the externalUUID anti-dupe = server
        // id, matching the online path), not the local placeholder.
        let entry = MoodEntry(id: "local-abc", recordedAt: Date(timeIntervalSince1970: 1_700_000_000), score: 4, tags: ["happy"])
        let op = try makeOp(kind: .logMood, payload: entry, key: "key-logmood-1")
        try await outbox.enqueue(op)

        let recorder = MirrorRecorder()
        MockURLProtocol.handler = { [resp = moodPostResponse] req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/mood-entries")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }

        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            mirrorMood: { entry in recorder.recordWrite(entry.id) },
            mirrorMoodDelete: { id in recorder.recordDelete(id) }
        )
        await replay.runOnce()

        #expect(await (outbox.snapshot).isEmpty)
        // The mirror fired exactly once, with the SERVER-assigned id.
        #expect(recorder.writes == ["srv-mood-99"])
        #expect(recorder.deletes.isEmpty)
    }

    @Test("M1: a replayed offline deleteMood removes the HealthKit mirror")
    func replayedDeleteMoodRemovesHKMirror() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let op = try makeOp(
            kind: .deleteMood,
            payload: OutboxQueue.Payloads.DeleteMood(id: "srv-mood-77"),
            key: "key-delmood-1"
        )
        try await outbox.enqueue(op)

        let recorder = MirrorRecorder()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            mirrorMood: { entry in recorder.recordWrite(entry.id) },
            mirrorMoodDelete: { id in recorder.recordDelete(id) }
        )
        await replay.runOnce()

        #expect(await (outbox.snapshot).isEmpty)
        #expect(recorder.deletes == ["srv-mood-77"])
        #expect(recorder.writes.isEmpty)
    }

    // MARK: - M2 — logout resets toggle + import anchor

    @MainActor
    @Test("M2: deactivateOnLogout forces the sync toggle OFF and resets the importer")
    func deactivateOnLogoutForcesOffAndResets() async throws {
        let suite = "MoodHealthMirrorReconcileTests.m2-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Simulate "toggle was ON for the previous user".
        defaults.set(true, forKey: MoodHealthSyncStore.prefKey)

        let writer = ResetRecordingWriter()
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let store = MoodHealthSyncStore(
            healthKit: writer,
            moodRepo: MoodRepository(api: api, outbox: outbox),
            keychain: InMemoryKeychain(),
            defaults: defaults
        )
        #expect(store.enabled)

        await store.deactivateOnLogout()

        // Toggle forced off — both the in-memory flag and the persisted pref —
        // so the NEXT user does not auto-activate the importer.
        #expect(!store.enabled)
        #expect(!defaults.bool(forKey: MoodHealthSyncStore.prefKey))
        // The per-user anchor reset path was invoked (not just a plain stop).
        #expect(await writer.resetCount == 1)
    }

    @MainActor
    @Test("manual mood sync runs only for an existing explicit opt-in")
    func manualMoodSyncPreservesOptIn() async throws {
        let suite = "MoodHealthMirrorReconcileTests.manual-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = ResetRecordingWriter()
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let disabled = MoodHealthSyncStore(
            healthKit: writer,
            moodRepo: MoodRepository(api: api, outbox: outbox),
            keychain: InMemoryKeychain(),
            defaults: defaults
        )

        await disabled.triggerSyncIfEnabled()
        #expect(await writer.refreshCount == 0)

        defaults.set(true, forKey: MoodHealthSyncStore.prefKey)
        let enabled = MoodHealthSyncStore(
            healthKit: writer,
            moodRepo: MoodRepository(api: api, outbox: outbox),
            keychain: InMemoryKeychain(),
            defaults: defaults
        )
        await enabled.triggerSyncIfEnabled()

        #expect(await writer.refreshCount == 1)
        #expect(enabled.enabled)
    }
}

// MARK: - Test doubles

/// Thread-safe recorder for the replay-mirror closures (invoked off URLSession
/// threads).
private final class MirrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writeIDs: [String] = []
    private var deleteIDs: [String] = []

    func recordWrite(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        writeIDs.append(id)
    }

    func recordDelete(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        deleteIDs.append(id)
    }

    var writes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return writeIDs
    }

    var deletes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deleteIDs
    }
}

/// Stub `AnyHealthKitWriter` that records the `resetMoodImport()` call (M2).
private actor ResetRecordingWriter: AnyHealthKitWriter {
    private(set) var resetCount = 0
    private(set) var refreshCount = 0

    func write(_: HealthLog.Measurement) async throws {}
    func writeMood(_: MoodEntry) async throws {}
    func deleteMood(id _: String) async throws {}
    func requestMoodAuthorization() async throws {}
    func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
    func refreshMoodImport(repo _: MoodRepository, userID _: String?) async {
        refreshCount += 1
    }

    func stopMoodImport() async {}
    func resetMoodImport() async {
        resetCount += 1
    }

    func activateBackgroundDeliveries() async throws {}
    func runBackgroundSyncPass() async {}
    func attachUploader(_: MeasurementBatchUploader) async {}
    func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
    func setInitialBackfillCutoff(_: Date?) async {}
    func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
}

// swiftlint:enable force_unwrapping force_try
