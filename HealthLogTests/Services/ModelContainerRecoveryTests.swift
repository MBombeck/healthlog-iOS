import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// Audit M2 — proves the in-memory recovery floor does NOT trap when the
/// store's own `makeInMemory()` throws. Previously these paths closed with
/// `try!`, so an in-memory build failure would crash on the exact path that
/// exists to avoid a hard launch failure.
@Suite("ModelContainerRecovery — non-trapping in-memory floor")
struct ModelContainerRecoveryTests {
    private struct DeliberateFailure: Error {}

    @Test("Happy path: primary build is used unchanged")
    func happyPathUsesPrimaryBuild() {
        // Reuse a real store schema so the happy path is exercised against the
        // production factory shape (not a synthetic model).
        let container = ModelContainerRecovery.recoveredInMemoryContainer(
            log: HLLog.outbox,
            subsystem: "Outbox",
            build: OutboxStore.makeInMemory
        )
        // The Outbox model is present → the primary build was honored, not the
        // empty-schema floor.
        #expect(container.schema.entities.contains { $0.name == "OutboxOperation" })
    }

    @Test("Degrade path: throwing build does not trap, returns an inert store")
    func degradeDoesNotTrap() {
        // If `try!` were still in place this call site would crash the test
        // process; reaching the assertion proves the floor is non-trapping.
        let container = ModelContainerRecovery.recoveredInMemoryContainer(
            log: HLLog.outbox,
            subsystem: "Outbox",
            build: { throw DeliberateFailure() }
        )
        // The empty-schema floor carries none of the store's models — it is an
        // inert, never-trapping fallback.
        #expect(container.schema.entities.isEmpty)
    }
}
