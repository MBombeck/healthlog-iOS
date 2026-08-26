import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("OutboxQueue")
struct OutboxQueueTests {
    @Test("enqueue + remove")
    func enqueueRemove() async throws {
        let queue = try OutboxQueue(inMemory: true)
        let id = UUID()
        try await queue.enqueue(.init(id: id, kind: .createMeasurement, payload: Data("x".utf8), createdAt: .now, attempts: 0))
        let snap = await queue.snapshot
        #expect(snap.count == 1)
        try await queue.remove(id: id)
        let snap2 = await queue.snapshot
        #expect(snap2.isEmpty)
    }

    @Test("incrementAttempts updates the entry")
    func attempts() async throws {
        let queue = try OutboxQueue(inMemory: true)
        let id = UUID()
        try await queue.enqueue(.init(id: id, kind: .takeMedication, payload: Data(), createdAt: .now, attempts: 0))
        try await queue.incrementAttempts(id: id)
        try await queue.incrementAttempts(id: id)
        let snap = await queue.snapshot
        #expect(snap.first?.attempts == 2)
    }

    @Test("clearAll empties the queue (used by account-deletion cascade)")
    func clearAllEmpties() async throws {
        let queue = try OutboxQueue(inMemory: true)
        try await queue
            .enqueue(.init(id: UUID(), kind: .createMeasurement, payload: Data("a".utf8), createdAt: .now, attempts: 0))
        try await queue
            .enqueue(.init(id: UUID(), kind: .takeMedication, payload: Data("b".utf8), createdAt: .now, attempts: 0))
        let pre = await queue.snapshot
        #expect(pre.count == 2)
        await queue.clearAll()
        let post = await queue.snapshot
        #expect(post.isEmpty)
    }

    @Test("clearAll on empty queue is a no-op")
    func clearAllOnEmpty() async throws {
        let queue = try OutboxQueue(inMemory: true)
        await queue.clearAll()
        let snap = await queue.snapshot
        #expect(snap.isEmpty)
    }
}
