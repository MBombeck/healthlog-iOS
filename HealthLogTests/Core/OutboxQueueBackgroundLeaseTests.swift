import Foundation
@testable import HealthLog
import Testing

/// Build 274 (public #4) — build 271 was killed by RunningBoard (`0xdead10cc`)
/// while a HealthKit observer wake persisted a retry row into the outbox store
/// in the shared app-group container: a SQLite lock held while suspending.
/// Every outbox write now runs under a background-execution lease; when the
/// system grants none, the write is refused (the caller already treats that as
/// "not persisted" and holds its cursor) instead of gambling with the lock.
@Suite("OutboxQueue — background-execution lease around persistence")
struct OutboxQueueBackgroundLeaseTests {
    /// Build 274 (public #4) — records the lease name and whether the body ran,
    /// so a test can prove the write happens INSIDE the lease and never outside.
    final class RecordingLease: BackgroundExecutionLeasing, @unchecked Sendable {
        private let lock = NSLock()
        private let grants: Bool
        private var _names: [String] = []
        private var _bodiesRun = 0
        init(grants: Bool) {
            self.grants = grants
        }

        var names: [String] {
            lock.withLock { _names }
        }

        var bodiesRun: Int {
            lock.withLock { _bodiesRun }
        }

        func withLease<T: Sendable>(
            named name: String,
            _ body: @escaping @Sendable () async throws -> T
        ) async throws -> T? {
            lock.withLock { _names.append(name) }
            guard grants else { return nil }
            lock.withLock { _bodiesRun += 1 }
            return try await body()
        }
    }

    @Test("an enqueue writes inside a named lease")
    func enqueueWritesInsideTheLease() async throws {
        let lease = RecordingLease(grants: true)
        let queue = try OutboxQueue(inMemory: true, backgroundLease: lease)
        try await queue.enqueue(.init(kind: .createMeasurement, payload: Data("x".utf8)))
        #expect(lease.names == ["outbox.persist"])
        #expect(lease.bodiesRun == 1)
        let rows = await queue.snapshot
        #expect(rows.count == 1)
    }

    @Test("a refused lease persists nothing and throws")
    func refusedLeasePersistsNothingAndThrows() async throws {
        let lease = RecordingLease(grants: false)
        let queue = try OutboxQueue(inMemory: true, backgroundLease: lease)
        await #expect(throws: (any Error).self) {
            try await queue.enqueue(.init(kind: .createMeasurement, payload: Data("x".utf8)))
        }
        #expect(lease.bodiesRun == 0)
        let rows = await queue.snapshot
        #expect(rows.isEmpty)
    }

    @Test("the default lease is unconditional, so every existing test path still writes")
    func defaultLeaseIsUnconditional() async throws {
        let queue = try OutboxQueue(inMemory: true)
        try await queue.enqueue(.init(kind: .takeMedication, payload: Data()))
        let rows = await queue.snapshot
        #expect(rows.count == 1)
    }

    @Test("the unconditional lease runs the body and returns its value")
    func unconditionalLeaseRunsTheBody() async throws {
        let value = try await UnconditionalBackgroundExecutionLease().withLease(named: "test") { 42 }
        #expect(value == 42)
    }
}
