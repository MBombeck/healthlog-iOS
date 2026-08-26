import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — cross-account isolation for every HealthKit path.
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

    @Test("every teardown seam is owned and bound to this suite")
    func teardownSeamsAreOwned() {
        let teardown = HealthSyncTriggerInventory.rows.filter { $0.trigger == .accountTeardown }
        #expect(teardown.count == 5)
        #expect(teardown.allSatisfy { !$0.ownerPlan.isEmpty })
        #expect(teardown.allSatisfy { $0.testIdentifier.contains("HealthSyncAccountIsolationTests") })
    }

    // MARK: - RED

    /// A page that finished after the switch must not commit anything, and the
    /// two production partitions that are still owner-blind — the daily-stat
    /// cache key and the ECG anchor reset — must become owner bound.
    @Test("a late account A pass cannot mutate account B")
    func lateAccountACannotMutateB() throws {
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

        let bindings = [
            ("HealthLog/Services/HealthKitDailyStatsCache.swift", "ownerUserID"),
            ("HealthLog/Services/EcgSyncCoordinator.swift", "HealthSyncOwnerLease"),
            ("HealthLog/Services/HealthKit/MoodStateOfMindImporter.swift", "HealthSyncOwnerLease"),
            ("HealthLog/Services/HealthKit/HeartHealthEventImporter.swift", "HealthSyncOwnerLease")
        ]
        for (path, symbol) in bindings {
            let contents = try Self.source(path)
            if !contents.contains(symbol) {
                violations.append("\(path) is not partitioned by \(symbol)")
            }
        }

        #expect(violations.isEmpty, "EXPECTED_RED: late account A mutated B")
    }

    // MARK: - Source access

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
