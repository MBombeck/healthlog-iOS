import Foundation
@testable import HealthLog
import Testing

/// Cross-account isolation for every HealthKit path.
///
/// An A→B switch during a fetch, an upload, a cache write, or an anchor reset
/// must stop account A's work completely: A may not request, publish, cache,
/// enqueue, reset, or advance a cursor once B is live, and a reset must target
/// the partition A captured rather than whoever the Keychain names at the time
/// the reset finally runs.
@Suite("HealthKit sync account isolation")
struct HealthSyncAccountIsolationTests {
    // MARK: - Lease adapter (single Phase-06 authority)

    @Test("the Phase-07 adapter reuses the Phase-06 generation authority")
    func adapterReusesPhase06Generation() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let session = try #require(registry.activate(ownerID: "account-a"))
        let lease = try #require(
            HealthSyncOwnerLease.capture(from: registry, ownerID: "account-a", source: .speziSamples)
        )

        #expect(lease.ownerID == "account-a")
        #expect(lease.generation == session.generation)
        #expect(lease.isCurrent)
        try lease.requireCurrent()
    }

    @Test("a lease captured under A stops the moment B activates")
    func lateLeaseIsRejectedAfterSwitch() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        _ = try #require(registry.activate(ownerID: "account-a"))
        let leaseA = try #require(
            HealthSyncOwnerLease.capture(from: registry, ownerID: "account-a", source: .dailyStatistics)
        )

        _ = try #require(registry.activate(ownerID: "account-b"))

        #expect(!leaseA.isCurrent)
        #expect(throws: CancellationError.self) {
            try leaseA.requireCurrent()
        }
        #expect(HealthSyncOwnerLease.capture(from: registry, ownerID: "account-a", source: .dailyStatistics) == nil)
    }

    @Test("a lease can only write its own owner's cursor partition")
    func leaseOnlyWritesItsOwnPartition() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        _ = try #require(registry.activate(ownerID: "account-a"))
        let leaseA = try #require(
            HealthSyncOwnerLease.capture(from: registry, ownerID: "account-a", source: .heartEvent)
        )
        _ = try #require(registry.activate(ownerID: "account-b"))
        let leaseB = try #require(
            HealthSyncOwnerLease.capture(from: registry, ownerID: "account-b", source: .heartEvent)
        )

        let keyA = try #require(leaseA.cursorKey(typeIdentifier: "HKCategoryTypeIdentifierHighHeartRateEvent"))
        let keyB = try #require(leaseB.cursorKey(typeIdentifier: "HKCategoryTypeIdentifierHighHeartRateEvent"))
        #expect(keyA != keyB)
        #expect(keyA.storageKey != keyB.storageKey)
    }

    // MARK: - RED

    /// A page that finished after the switch must not commit anything.
    @Test("a late account A pass cannot mutate account B")
    func lateAccountACannotMutateB() {
        var violations: [String] = []

        let registry = AuthenticatedSessionLeaseRegistry()
        _ = registry.activate(ownerID: "account-a")
        let leaseA = HealthSyncOwnerLease.capture(from: registry, ownerID: "account-a", source: .dailyStatistics)
        _ = registry.activate(ownerID: "account-b")

        let lateOutcome = HealthSyncPageOutcome(
            postedCount: 1,
            entries: [HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .terminalAccepted)],
            transportThrew: false,
            durableRetryPersisted: false,
            durableRetryFailed: false,
            leaseIsCurrent: leaseA?.isCurrent ?? false,
            wasCancelled: false
        )
        if HealthSyncCursorPolicy.installed.decide(lateOutcome) == .commit {
            violations.append("a page owned by the previous account still committed its cursor")
        }

        #expect(violations.isEmpty, "late account A mutated B")
    }
}
