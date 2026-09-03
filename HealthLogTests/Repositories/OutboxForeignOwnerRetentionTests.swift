import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// Build 273 (sync audit A11) — a row owned by another user is RETAINED,
/// never transmitted, never deleted. The replay used to log "dead-lettered"
/// and then `remove` the row, so a shared-device sign-in as User B silently
/// destroyed User A's queued health writes.
@Suite("Outbox — foreign-owner rows are retained (A11)", .serialized)
struct OutboxForeignOwnerRetentionTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var hits = 0
        func record() {
            lock.lock()
            hits += 1
            lock.unlock()
        }

        var hitCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return hits
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

    @Test("another user's queued write survives a replay pass untouched and unsent")
    func foreignRowSurvivesReplay() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        try await outbox.enqueue(.init(
            kind: .createMeasurement,
            payload: Data("{}".utf8),
            idempotencyKey: "idem-a-1",
            ownerUserID: "user-a"
        ))
        let recorder = Recorder()
        MockURLProtocol.handler = { request in
            recorder.record()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let api = makeAPI()
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: { "user-b" },
            maxAttempts: 8,
            attemptBackoff: 0
        )
        await replay.runOnce()
        await replay.runOnce()

        #expect(recorder.hitCount == 0, "a foreign row never reaches the wire")
        let rows = await outbox.snapshot
        #expect(rows.count == 1, "the row is retained for its owner, not deleted")
        #expect(rows.first?.ownerUserID == "user-a")
    }
}
