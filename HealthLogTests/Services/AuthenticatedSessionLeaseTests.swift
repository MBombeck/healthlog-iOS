@testable import HealthLog
import Testing

@Suite("AuthenticatedSessionLeaseTests")
struct AuthenticatedSessionLeaseTests {
    @Test
    func currentLeaseIsAccepted() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let lease = try #require(registry.activate(ownerID: "account-a"))

        #expect(lease.isCurrent)
        try lease.requireCurrent()
    }

    @Test
    func oldLeaseIsRejectedAfterReplacement() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let oldLease = try #require(registry.activate(ownerID: "account-a"))
        _ = try #require(registry.activate(ownerID: "account-b"))

        #expect(
            !oldLease.isCurrent,
            "EXPECTED_RED: old lease remained current after replacement"
        )
    }

    @Test
    func invalidationRejectsCapturedLease() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        _ = try #require(registry.activate(ownerID: "account-a"))
        let lease = try #require(registry.capture(ownerID: "account-a"))

        registry.invalidate()

        #expect(!lease.isCurrent)
        #expect(throws: CancellationError.self) {
            try lease.requireCurrent()
        }
    }

    @Test
    func sameOwnerReloginAdvancesGeneration() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let first = try #require(registry.activate(ownerID: "account-a"))
        let second = try #require(registry.activate(ownerID: "account-a"))

        #expect(first.generation != second.generation)
        #expect(!first.isCurrent)
        #expect(second.isCurrent)
    }

    @Test
    func captureRequiresExactActiveOwner() throws {
        let registry = AuthenticatedSessionLeaseRegistry()

        #expect(registry.activate(ownerID: "") == nil)
        _ = try #require(registry.activate(ownerID: "account-a"))
        #expect(registry.capture(ownerID: "account-b") == nil)
        #expect(registry.capture(ownerID: "") == nil)
        #expect(try #require(registry.capture(ownerID: "account-a")).isCurrent)
    }

    @Test
    func taskCancellationRejectsOtherwiseCurrentLease() async throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let lease = try #require(registry.activate(ownerID: "account-a"))

        let isCurrent = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return lease.isCurrent
        }.value

        #expect(!isCurrent)
    }

    @Test
    func concurrentChecksAndReplacementAreRaceFree() async throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let oldLease = try #require(registry.activate(ownerID: "account-a"))

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 200 {
                group.addTask {
                    if index.isMultiple(of: 17) {
                        _ = registry.activate(ownerID: "account-b")
                    } else {
                        _ = oldLease.isCurrent
                    }
                }
            }
        }

        #expect(!oldLease.isCurrent)
        #expect(try #require(registry.capture(ownerID: "account-b")).isCurrent)
    }
}
