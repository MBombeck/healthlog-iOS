#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// Phase 07 Wave 2 — the account cutover, restated.
    ///
    /// **This suite replaces `SpeziAnchorMigrator — legacy → Spezi seed`.** The old
    /// suite pinned four properties of a migration that ran in the opposite
    /// direction from the one this phase needs: it copied a per-account
    /// `hl.healthkit.anchor.<token>.<typeID>` blob *into* SpeziHealthKit's
    /// installation-global `queryAnchors` slot, guarded by a one-shot UserDefaults
    /// flag. Every one of those four properties is now either meaningless (nothing
    /// reads Spezi's slots) or actively wrong (an account's resume token must never
    /// be written somewhere another account resumes from). The old behaviour and the
    /// new one cannot both be green, so the suite is restated rather than deleted.
    ///
    /// What is asserted instead is the property the old one could not express: the
    /// installation-global anchor is *quarantined* — recorded, never read into the
    /// partition, never deleted — and the account replays from its chosen cutoff.
    @Suite("SpeziAnchorMigrator — quarantine the global, replay per account")
    struct SpeziAnchorMigratorTests {
        private final class Backing: Sendable {
            private let entries = Mutex<[String: Data]>([:])

            func data(forKey key: String) -> Data? {
                entries.withLock { $0[key] }
            }

            func set(_ value: Data, forKey key: String) {
                entries.withLock { $0[key] = value }
            }

            var keys: Set<String> {
                entries.withLock { Set($0.keys) }
            }

            var storage: HealthSyncCursorStorage {
                HealthSyncCursorStorage(
                    read: { [self] key in data(forKey: key) },
                    write: { [self] key, value in set(value, forKey: key) }
                )
            }
        }

        private func makeLease(
            owner: String,
            registry: AuthenticatedSessionLeaseRegistry
        ) throws -> HealthSyncAuthenticatedLease {
            _ = registry.activate(ownerID: owner)
            return try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: owner,
                source: .speziSamples,
                bearerProvider: { "token-\(owner)" }
            )
        }

        private let sampleTypes = [
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue
        ]

        // MARK: - Tests

        @Test("the quarantine reference names SpeziHealthKit's real global slot")
        func quarantineReferenceNamesTheSpeziSlot() {
            let typeID = HKQuantityTypeIdentifier.stepCount.rawValue
            #expect(
                SpeziAnchorMigrator.speziGlobalAnchorKey(for: typeID)
                    == "edu.stanford.Spezi.SpeziHealthKit.queryAnchors.\(typeID)"
            )
        }

        @Test("every server-bound type is quarantined into a replaying partition")
        func everyTypeReplaysBehindAQuarantine() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(owner: "user-A", registry: registry)
            let backing = Backing()
            let store = DurableHealthCursorStore(storage: backing.storage)

            let states = await SpeziAnchorMigrator.migrateAccountCursors(
                types: sampleTypes,
                store: store,
                requiring: lease
            )

            #expect(states.count == sampleTypes.count)
            for typeID in sampleTypes {
                let expected = SpeziAnchorMigrator.speziGlobalAnchorKey(for: typeID)
                #expect(states[typeID] == .replayingLegacy(quarantineReference: expected))
                let key = try #require(lease.cursorKey(typeIdentifier: typeID))
                #expect(await store.quarantineReference(for: key) == expected)
                // Replaying permits collection — from the chosen cutoff, with no
                // cursor adopted from the global value.
                #expect(await store.permitsCollection(for: key))
                #expect(await store.anchor(for: key) == nil)
            }
        }

        @Test("the global anchor is never read into the partition and never deleted")
        func globalAnchorIsNeitherAdoptedNorDeleted() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(owner: "user-A", registry: registry)
            let backing = Backing()
            let typeID = HKQuantityTypeIdentifier.stepCount.rawValue
            let globalKey = SpeziAnchorMigrator.speziGlobalAnchorKey(for: typeID)
            backing.set(Data([9, 9, 9]), forKey: globalKey)

            let store = DurableHealthCursorStore(storage: backing.storage)
            await SpeziAnchorMigrator.migrateAccountCursors(
                types: [typeID],
                store: store,
                requiring: lease
            )

            let key = try #require(lease.cursorKey(typeIdentifier: typeID))
            #expect(await store.anchor(for: key) != Data([9, 9, 9]))
            #expect(await store.anchor(for: key) == nil)
            // Retained exactly as it was: quarantine records a reference, it does
            // not remove the value it points at.
            #expect(backing.data(forKey: globalKey) == Data([9, 9, 9]))
        }

        @Test("two accounts get disjoint partitions from the same global anchor")
        func twoAccountsDoNotShareAPartition() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let backing = Backing()
            let store = DurableHealthCursorStore(storage: backing.storage)
            let typeID = HKQuantityTypeIdentifier.stepCount.rawValue

            let leaseA = try makeLease(owner: "user-A", registry: registry)
            await SpeziAnchorMigrator.migrateAccountCursors(types: [typeID], store: store, requiring: leaseA)
            let keyA = try #require(leaseA.cursorKey(typeIdentifier: typeID))
            let anchorA = try #require(HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 7), label: "t"))
            try await store.save(anchor: anchorA, for: keyA, requiring: leaseA)

            // B signs in on the same device. Its partition starts empty, and A's
            // progress is not visible to it.
            let leaseB = try makeLease(owner: "user-B", registry: registry)
            await SpeziAnchorMigrator.migrateAccountCursors(types: [typeID], store: store, requiring: leaseB)
            let keyB = try #require(leaseB.cursorKey(typeIdentifier: typeID))

            #expect(keyA.storageKey != keyB.storageKey)
            #expect(await store.anchor(for: keyB) == nil)
            #expect(await store.anchor(for: keyA) == anchorA)
        }

        @Test("a second migration pass is a no-op, not a second adoption")
        func migrationIsIdempotent() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(owner: "user-A", registry: registry)
            let backing = Backing()
            let store = DurableHealthCursorStore(storage: backing.storage)
            let typeID = HKQuantityTypeIdentifier.stepCount.rawValue

            await SpeziAnchorMigrator.migrateAccountCursors(types: [typeID], store: store, requiring: lease)
            let key = try #require(lease.cursorKey(typeIdentifier: typeID))
            let anchor = try #require(HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 3), label: "t"))
            try await store.save(anchor: anchor, for: key, requiring: lease)

            let second = await SpeziAnchorMigrator.migrateAccountCursors(
                types: [typeID],
                store: store,
                requiring: lease
            )

            // Still replaying, still holding the progress the account made.
            #expect(second[typeID]?.permitsCollection == true)
            #expect(await store.anchor(for: key) == anchor)
        }

        @Test("a stale lease migrates nothing")
        func staleLeaseMigratesNothing() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(owner: "user-A", registry: registry)
            let backing = Backing()
            let store = DurableHealthCursorStore(storage: backing.storage)
            // A different account takes over the session after admission.
            _ = registry.activate(ownerID: "user-B")

            let states = await SpeziAnchorMigrator.migrateAccountCursors(
                types: sampleTypes,
                store: store,
                requiring: lease
            )

            for typeID in sampleTypes {
                #expect(states[typeID]?.permitsCollection == false)
                let key = try #require(HealthSyncCursorKey(
                    ownerID: "user-A",
                    source: .speziSamples,
                    typeIdentifier: typeID
                ))
                #expect(await store.permitsCollection(for: key) == false)
            }
        }

        @Test("fail-closed rollback stops every partition without deleting or widening")
        func failClosedStopsWithoutWidening() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(owner: "user-A", registry: registry)
            let backing = Backing()
            let store = DurableHealthCursorStore(storage: backing.storage)
            let typeID = HKQuantityTypeIdentifier.stepCount.rawValue
            let globalKey = SpeziAnchorMigrator.speziGlobalAnchorKey(for: typeID)
            backing.set(Data([4, 2]), forKey: globalKey)

            await SpeziAnchorMigrator.migrateAccountCursors(types: [typeID], store: store, requiring: lease)
            let key = try #require(lease.cursorKey(typeIdentifier: typeID))
            let anchor = try #require(HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 5), label: "t"))
            try await store.save(anchor: anchor, for: key, requiring: lease)

            await SpeziAnchorMigrator.failClosed(
                reason: "rollback under test",
                types: [typeID],
                store: store,
                requiring: lease
            )

            // Stopped…
            #expect(await store.permitsCollection(for: key) == false)
            // …but the owner's own progress, the quarantine reference, and the
            // quarantined value itself all survive.
            #expect(await store.anchor(for: key) == anchor)
            #expect(await store.quarantineReference(for: key) == globalKey)
            #expect(backing.data(forKey: globalKey) == Data([4, 2]))
        }
    }
#endif
