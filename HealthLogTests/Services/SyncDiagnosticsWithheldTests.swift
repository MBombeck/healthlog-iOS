import Foundation
@testable import HealthLog
import Testing

/// What the phone holds back is visible: Apple Health doses still waiting and
/// data types whose cursor stayed locked.
@MainActor
@Suite("Sync Diagnostics: held-back doses and locked types")
struct SyncDiagnosticsWithheldTests {
    private static let steps = "HKQuantityTypeIdentifierStepCount"
    private static let mass = "HKQuantityTypeIdentifierBodyMass"

    private static func store() throws -> (HKSyncDiagnostics, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "hl.hksync.withheld.card.\(UUID().uuidString)"))
        return (HKSyncDiagnostics.makeForTesting(defaults: defaults), defaults)
    }

    @Test("a locked type is listed with its reason until a pass that checks it finds it open")
    func lockedTypesFollowThePasses() throws {
        let (store, defaults) = try Self.store()
        store.recordLockedPartitions([Self.mass: .failedWrite], checked: [Self.mass, Self.steps])
        #expect(store.healthSync.lockedPartitions == [Self.mass: .failedWrite])

        // A pass over other types leaves the lock as it was.
        store.recordLockedPartitions([:], checked: [Self.steps])
        #expect(HKSyncDiagnostics.makeForTesting(defaults: defaults).healthSync.lockedPartitions == [Self.mass: .failedWrite])

        store.recordLockedPartitions([Self.mass: .closed], checked: [Self.mass])
        #expect(store.healthSync.lockedPartitions == [Self.mass: .closed])
        store.recordLockedPartitions([:], checked: [Self.mass])
        #expect(store.healthSync.lockedPartitions == nil)
    }

    @Test("the lock reason follows the partition's state")
    func lockReasonFromState() {
        #expect(HealthSyncPartitionLockReason(.failed(reason: DurableHealthCursorStore.unverifiedWriteReason)) == .failedWrite)
        #expect(HealthSyncPartitionLockReason(.failed(reason: "legacy owner proof did not match the partition")) == .closed)
        #expect(HealthSyncPartitionLockReason(.notStarted) == .notMigrated)
    }

    @Test("a background pass without a session is counted, a foreground one is not")
    func backgroundPassesWithoutSession() throws {
        let (store, defaults) = try Self.store()
        let refused = HealthSyncPassSnapshot.Capability(
            capability: "speziSampleCollection", disposition: "failed", itemsSubmitted: 0, itemsSettled: 0,
            itemsHeld: 0, failure: HealthSyncFailureClass.notAdmitted.rawValue, holdReason: nil
        )
        let ran = HealthSyncPassSnapshot.Capability(
            capability: "outboxDrain", disposition: "ran", itemsSubmitted: 0, itemsSettled: 0,
            itemsHeld: 0, failure: nil, holdReason: nil
        )
        func pass(_ trigger: HealthSyncTrigger, _ capabilities: [HealthSyncPassSnapshot.Capability]) -> HealthSyncPassSnapshot {
            HealthSyncPassSnapshot(
                trigger: trigger.rawValue, startedAt: .now, durationMilliseconds: 1, isComplete: false,
                heldItemCount: 0, omittedCapabilities: [], capabilities: capabilities
            )
        }
        store.recordHealthSyncPass(pass(.processing, [refused, ran]))
        store.recordHealthSyncPass(pass(.observer, [refused]))
        store.recordHealthSyncPass(pass(.foreground, [refused]))
        store.recordHealthSyncPass(pass(.appRefresh, [ran]))

        #expect(store.healthSync.backgroundPassesWithoutSession == 2)
        #expect(HKSyncDiagnostics.makeForTesting(defaults: defaults).healthSync.backgroundPassesWithoutSession == 2)
        #expect(SyncDiagnosticsWithheld(store.healthSync).backgroundWithoutSession == 2)
    }

    @Test("update path: a snapshot persisted by 1.6 decodes with its counters and nothing locked")
    func snapshotFromAnEarlierBuild() throws {
        let defaults = try #require(UserDefaults(suiteName: "hl.hksync.withheld.legacy.\(UUID().uuidString)"))
        let legacy = """
        {"lastPassWasComplete":true,"lastPassHeldItems":4,"lastPassRefusedForMissingAdmission":[],
        "admissionRefusalsTotal":2,"dispositionTotals":{"ran":3},"holdReasonTotals":{},
        "pendingAppleDoseCount":6,"quarantinedLegacyRowCount":1}
        """
        defaults.set(Data(legacy.utf8), forKey: "hl.hksync.pass.v1")

        let store = HKSyncDiagnostics.makeForTesting(defaults: defaults)
        #expect(store.healthSync.pendingAppleDoseCount == 6)
        #expect(store.healthSync.admissionRefusalsTotal == 2)
        #expect(store.healthSync.lockedPartitions == nil)
        #expect(store.healthSync.backgroundPassesWithoutSession == nil)
        #expect(SyncDiagnosticsWithheld(store.healthSync).pendingDoses == 6)
    }

    @Test("only a failed write is promised a retry on the next sync; the others say why")
    func cardContent() {
        var snapshot = HKSyncDiagnostics.HealthSyncSnapshot()
        #expect(SyncDiagnosticsWithheld(snapshot).isEmpty)

        snapshot.pendingAppleDoseCount = 3
        snapshot.lockedPartitions = [Self.steps: .closed, Self.mass: .failedWrite]
        let withheld = SyncDiagnosticsWithheld(snapshot)
        #expect(!withheld.isEmpty)
        #expect(withheld.pendingDoses == 3)
        #expect(withheld.lockedCount == 2)
        #expect(withheld.lockGroups.map(\.reason) == [.failedWrite, .closed])
        #expect(withheld.lockGroups.first?.typeNames == [HealthAccessTypeNaming.displayName(for: Self.mass)])
        let notes = Set([HealthSyncPartitionLockReason.failedWrite, .notMigrated, .closed].map(SyncDiagnosticsWithheld.note(for:)))
        #expect(notes.count == 3, "each reason has its own sentence")
    }
}
