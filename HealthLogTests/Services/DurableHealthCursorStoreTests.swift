import Foundation
@testable import HealthLog
import Synchronization
import Testing

/// Phase 07 Wave 1 — the verified, owner-partitioned cursor store.
///
/// The properties under test are the ones the Wave-0 fault matrix demands of
/// any real storage layer: partitions are per `{owner, source, type}`, a write
/// counts only after a read-back, an unproven migration collects nothing, and
/// an installation-global value is quarantined rather than adopted.
@Suite("Durable health cursor store")
struct DurableHealthCursorStoreTests {
    /// An isolated backing store whose writes can be made to silently vanish for
    /// one partition — the exact fault the read-back exists to catch.
    private final class Backing: Sendable {
        private let entries = Mutex<[String: Data]>([:])
        private let dropped = Mutex<String?>(nil)

        var droppedKeyPrefix: String? {
            get { dropped.withLock { $0 } }
            set { dropped.withLock { $0 = newValue } }
        }

        func data(forKey key: String) -> Data? {
            entries.withLock { $0[key] }
        }

        func set(_ value: Data, forKey key: String) {
            // The migration record must still land; the fault under test is a
            // lost *cursor* write, not a lost audit trail.
            if let prefix = droppedKeyPrefix, key.hasPrefix(prefix), !key.hasSuffix(".migration") { return }
            entries.withLock { $0[key] = value }
        }

        var storage: HealthSyncCursorStorage {
            HealthSyncCursorStorage(
                read: { [self] key in data(forKey: key) },
                write: { [self] key, value in set(value, forKey: key) }
            )
        }
    }

    private func makeDefaults() -> Backing {
        Backing()
    }

    private func makeLease(
        owner: String = "account-a",
        source: HealthSyncSource = .speziSamples,
        registry: AuthenticatedSessionLeaseRegistry
    ) throws -> HealthSyncAuthenticatedLease {
        _ = registry.activate(ownerID: owner)
        return try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: owner,
            source: source,
            bearerProvider: { "token-\(owner)" }
        )
    }

    private func key(
        owner: String = "account-a",
        source: HealthSyncSource = .speziSamples,
        type: String = "HKQuantityTypeIdentifierStepCount"
    ) throws -> HealthSyncCursorKey {
        try #require(HealthSyncCursorKey(ownerID: owner, source: source, typeIdentifier: type))
    }

    // MARK: - Identity

    @Test("owner, source, and type each open a distinct partition")
    func partitionsAreKeyedByOwnerSourceAndType() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)

        let stepsA = try key()
        let sleepA = try key(type: "HKCategoryTypeIdentifierSleepAnalysis")
        let otherSource = try key(source: .heartEvent)

        try await store.save(anchor: Data([1]), for: stepsA, requiring: lease)
        try await store.save(anchor: Data([2]), for: sleepA, requiring: lease)
        try await store.save(anchor: Data([3]), for: otherSource, requiring: lease)

        #expect(await store.anchor(for: stepsA) == Data([1]))
        #expect(await store.anchor(for: sleepA) == Data([2]))
        #expect(await store.anchor(for: otherSource) == Data([3]))
    }

    @Test("a lease can never write another account's partition")
    func foreignPartitionWriteIsRefused() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let leaseA = try makeLease(registry: registry)
        let foreignKey = try key(owner: "account-b")

        await #expect(throws: HealthSyncCursorStoreError.partitionOwnerMismatch) {
            try await store.save(anchor: Data([9]), for: foreignKey, requiring: leaseA)
        }
        #expect(await store.anchor(for: foreignKey) == nil)
    }

    @Test("a page that finishes after an account switch writes nothing")
    func lateWriteAfterAccountSwitchIsRefused() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let leaseA = try makeLease(registry: registry)
        let partition = try key()

        _ = registry.activate(ownerID: "account-b")

        await #expect(throws: HealthSyncLeaseRefusal.staleSession) {
            try await store.save(anchor: Data([1]), for: partition, requiring: leaseA)
        }
        #expect(await store.anchor(for: partition) == nil)
    }

    // MARK: - Verified writes

    @Test("a write that does not survive read-back never stamps progress")
    func lostWriteFailsClosed() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        defaults.droppedKeyPrefix = partition.storageKey

        await #expect(throws: HealthSyncCursorStoreError.writeNotVerified) {
            try await store.save(anchor: Data([7]), for: partition, requiring: lease)
        }

        #expect(await store.anchor(for: partition) == nil)
        #expect(await store.migrationState(for: partition) == .failed(reason: "cursor write did not survive read back"))
        #expect(await store.permitsCollection(for: partition) == false, "a failed partition must not collect")
    }

    @Test("a malformed anchor fails closed and never stamps verified")
    func malformedAnchorFailsClosed() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()

        await #expect(throws: HealthSyncCursorStoreError.malformedAnchor) {
            try await store.save(anchor: Data(), for: partition, requiring: lease)
        }
        #expect(await store.migrationState(for: partition).isComplete == false)
        #expect(await store.permitsCollection(for: partition) == false)
    }

    @Test("a verified write permits collection and reads back byte-identically")
    func verifiedWritePermitsCollection() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()

        let record = try await store.save(anchor: Data([4, 2]), for: partition, requiring: lease)

        #expect(record.anchor == Data([4, 2]))
        #expect(record.version == DurableHealthCursorStore.formatVersion)
        #expect(await store.migrationState(for: partition) == .verified)
        #expect(await store.permitsCollection(for: partition))
    }

    @Test("an untouched partition starts fail-closed, not open")
    func untouchedPartitionStartsClosed() async throws {
        let defaults = makeDefaults()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let partition = try key()

        #expect(await store.migrationState(for: partition) == .notStarted)
        #expect(await store.permitsCollection(for: partition) == false)
        #expect(await store.anchor(for: partition) == nil)
    }

    // MARK: - Commit rule

    @Test("the commit rule holds every fault the durable policy holds")
    func commitHoldsOnEveryFault() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        try await store.save(anchor: Data([1]), for: partition, requiring: lease)

        let rejected = HealthSyncPageOutcome(
            postedCount: 1,
            entries: [HealthSyncEntryOutcome(index: 0, stableIdentity: "s-0", classification: .nonterminal)],
            transportThrew: false,
            durableRetryPersisted: false,
            durableRetryFailed: false,
            leaseIsCurrent: true,
            wasCancelled: false
        )
        let decision = await store.commit(page: rejected, anchor: Data([2]), for: partition, requiring: lease)

        #expect(decision == .hold(reason: .nonterminalEntry))
        #expect(await store.anchor(for: partition) == Data([1]), "a hold leaves the stored cursor untouched")
    }

    @Test("the commit rule advances only on exact acceptance")
    func commitAdvancesOnExactAcceptance() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        try await store.save(anchor: Data([1]), for: partition, requiring: lease)

        let accepted = HealthSyncPageOutcome(
            postedCount: 1,
            entries: [HealthSyncEntryOutcome(index: 0, stableIdentity: "s-0", classification: .terminalAccepted)],
            transportThrew: false,
            durableRetryPersisted: false,
            durableRetryFailed: false,
            leaseIsCurrent: true,
            wasCancelled: false
        )
        let decision = await store.commit(page: accepted, anchor: Data([2]), for: partition, requiring: lease)

        #expect(decision == .commit)
        #expect(await store.anchor(for: partition) == Data([2]))
    }

    @Test("a cancelled page holds for its own reason, never as acceptance")
    func cancelledPageHoldsAsCancellation() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        try await store.save(anchor: Data([1]), for: partition, requiring: lease)

        let accepted = HealthSyncPageOutcome(
            postedCount: 1,
            entries: [HealthSyncEntryOutcome(index: 0, stableIdentity: "s-0", classification: .terminalAccepted)],
            transportThrew: false,
            durableRetryPersisted: false,
            durableRetryFailed: false,
            leaseIsCurrent: true,
            wasCancelled: false
        )
        let decision = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.commit(page: accepted, anchor: Data([2]), for: partition, requiring: lease)
        }.value

        #expect(decision == .hold(reason: .cancelled))
        #expect(await store.anchor(for: partition) == Data([1]))
    }

    // MARK: - Migration

    @Test("an unowned global value is quarantined, never adopted, never deleted")
    func unownedGlobalValueIsQuarantined() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let legacyKey = "edu.stanford.spezi.healthkit.anchor.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([9, 9]), forKey: legacyKey)

        let state = try await store.migrate(
            partition,
            legacyKey: legacyKey,
            ownership: .unownedGlobal,
            requiring: lease
        )

        #expect(state == .replayingLegacy(quarantineReference: legacyKey))
        #expect(await store.anchor(for: partition) == nil, "an unowned value must never become the owner's cursor")
        #expect(defaults.data(forKey: legacyKey) == Data([9, 9]), "the quarantined value stays on disk")
        #expect(await store.quarantinedLegacyValue(for: partition) == Data([9, 9]))
        #expect(await store.permitsCollection(for: partition), "replay from the chosen cutoff is allowed")
    }

    @Test("a proven per-user legacy anchor migrates through the verified write path")
    func provenOwnerLegacyAnchorMigrates() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let legacyKey = "hl.healthkit.anchor.account-a.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([5]), forKey: legacyKey)

        let state = try await store.migrate(
            partition,
            legacyKey: legacyKey,
            ownership: .provenOwner("account-a"),
            requiring: lease
        )

        #expect(state == .verified)
        #expect(await store.anchor(for: partition) == Data([5]))
        #expect(defaults.data(forKey: legacyKey) == Data([5]), "this phase deletes no legacy key")
    }

    @Test("legacy ownership proof for another account fails closed")
    func mismatchedOwnerProofFailsClosed() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let legacyKey = "hl.healthkit.anchor.account-b.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([6]), forKey: legacyKey)

        let state = try await store.migrate(
            partition,
            legacyKey: legacyKey,
            ownership: .provenOwner("account-b"),
            requiring: lease
        )

        #expect(state == .failed(reason: "legacy owner proof did not match the partition"))
        #expect(await store.permitsCollection(for: partition) == false)
        #expect(await store.anchor(for: partition) == nil)
    }

    @Test("a migration whose adoption cannot be verified stays failed")
    func unverifiableAdoptionStaysFailed() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let legacyKey = "hl.healthkit.anchor.account-a.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([5]), forKey: legacyKey)
        defaults.droppedKeyPrefix = partition.storageKey

        let state = try await store.migrate(
            partition,
            legacyKey: legacyKey,
            ownership: .provenOwner("account-a"),
            requiring: lease
        )

        #expect(state == .failed(reason: "legacy anchor adoption did not verify"))
        #expect(await store.permitsCollection(for: partition) == false)
    }

    @Test("a completed replay is verified while the quarantined value is retained")
    func completedReplayVerifiesWithoutDeletingTheQuarantine() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let legacyKey = "edu.stanford.spezi.healthkit.anchor.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([9]), forKey: legacyKey)
        _ = try await store.migrate(partition, legacyKey: legacyKey, ownership: .unownedGlobal, requiring: lease)

        // Progress written during the replay window must not end the replay.
        try await store.save(anchor: Data([1]), for: partition, requiring: lease)
        #expect(await store.migrationState(for: partition) == .replayingLegacy(quarantineReference: legacyKey))

        try await store.completeLegacyReplay(for: partition, requiring: lease)

        #expect(await store.migrationState(for: partition) == .verified)
        #expect(defaults.data(forKey: legacyKey) == Data([9]), "the quarantined value survives through Phase 11")
    }

    @Test("migration is established once and cannot be re-run into a second adoption")
    func migrationIsEstablishedOnce() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let globalKey = "edu.stanford.spezi.healthkit.anchor.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([9]), forKey: globalKey)
        _ = try await store.migrate(partition, legacyKey: globalKey, ownership: .unownedGlobal, requiring: lease)

        let second = try await store.migrate(
            partition,
            legacyKey: globalKey,
            ownership: .provenOwner("account-a"),
            requiring: lease
        )

        #expect(second == .replayingLegacy(quarantineReference: globalKey))
        #expect(await store.anchor(for: partition) == nil)
    }

    // MARK: - Recovery

    @Test("fail-closed recovery stops collection and preserves owner and quarantine state")
    func failClosedRecoveryPreservesState() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let partition = try key()
        let legacyKey = "edu.stanford.spezi.healthkit.anchor.HKQuantityTypeIdentifierStepCount"
        defaults.set(Data([9]), forKey: legacyKey)
        _ = try await store.migrate(partition, legacyKey: legacyKey, ownership: .unownedGlobal, requiring: lease)
        try await store.save(anchor: Data([1]), for: partition, requiring: lease)

        await store.failClosed(partition, reason: "diagnostic recovery")

        #expect(await store.permitsCollection(for: partition) == false)
        #expect(await store.anchor(for: partition) == Data([1]), "the owner's own progress is preserved")
        #expect(await store.quarantineReference(for: partition) == legacyKey)
        #expect(defaults.data(forKey: legacyKey) == Data([9]))
    }

    @Test("diagnostics report every partition without naming the account")
    func diagnosticsAreOwnerSafe() async throws {
        let defaults = makeDefaults()
        let registry = AuthenticatedSessionLeaseRegistry()
        let store = DurableHealthCursorStore(storage: defaults.storage)
        let lease = try makeLease(registry: registry)
        let verified = try key()
        let untouched = try key(type: "HKCategoryTypeIdentifierSleepAnalysis")
        try await store.save(anchor: Data([1]), for: verified, requiring: lease)

        let rows = await store.diagnostics(for: [verified, untouched])

        #expect(rows.count == 2)
        #expect(rows[0].hasCursor)
        #expect(rows[0].permitsCollection)
        #expect(rows[0].migration == .verified)
        #expect(!rows[1].hasCursor)
        #expect(!rows[1].permitsCollection)
        #expect(rows.allSatisfy { !$0.storageKey.contains("account-a") })
    }
}
