#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// Two ways a type used to go quiet until the next launch: an observer
    /// signal that arrived while no account was admitted, and a partition a
    /// failed cursor write closed.
    @Suite("Collector: kept signals and reopened partitions")
    struct CollectorAdmissionAndPartitionRecoveryTests {
        private static let stepType = CollectorFixture.stepType
        private static let massType = HKQuantityTypeIdentifier.bodyMass.rawValue

        /// Records which type each read was for.
        final class TypeRecordingSource: AnchoredHealthSampleQuerying, Sendable {
            private let types = Mutex<[String]>([])

            var queriedTypes: [String] {
                types.withLock { $0 }
            }

            func page(
                typeIdentifier: String,
                resumingFrom _: HKQueryAnchor?,
                notBefore _: Date,
                limit _: Int
            ) async throws -> AnchoredHealthSamplePage {
                types.withLock { $0.append(typeIdentifier) }
                return CollectorFixture.page(1)
            }
        }

        /// Records what the collector reports to Sync Diagnostics.
        final class LockLog: Sendable {
            private let reports = Mutex<[(locked: [String: HealthSyncPartitionLockReason], checked: [String])]>([])

            var last: (locked: [String: HealthSyncPartitionLockReason], checked: [String])? {
                reports.withLock { $0.last }
            }

            var sink: AnchoredHealthSampleCollector.PartitionLockSink {
                { [self] locked, checked in reports.withLock { $0.append((locked, checked)) } }
            }
        }

        private static func migrate(
            _ type: String,
            in store: DurableHealthCursorStore,
            lease: HealthSyncAuthenticatedLease
        ) async throws -> HealthSyncCursorKey {
            let key = try #require(HealthSyncCursorKey(ownerID: lease.ownerID, source: .speziSamples, typeIdentifier: type))
            _ = try await store.migrate(
                key,
                legacyKey: SpeziAnchorMigrator.speziGlobalAnchorKey(for: type),
                ownership: .unownedGlobal,
                requiring: lease
            )
            return key
        }

        // MARK: - Observer admission

        @Test("a signal that arrives without an admitted account is collected with the next delivery")
        func refusedAdmissionKeepsTheSignal() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let store = DurableHealthCursorStore(storage: CollectorCursorBacking().storage)
            _ = try await Self.migrate(Self.stepType, in: store, lease: lease)
            _ = try await Self.migrate(Self.massType, in: store, lease: lease)
            let source = TypeRecordingSource()
            let observer = RecordingObserver()
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: []),
                observer: observer,
                partitionLocks: LockLog().sink
            )
            let admitted = Mutex(false)
            await collector.startObserving([Self.stepType, Self.massType], notBefore: .distantPast) {
                guard admitted.withLock({ $0 }) else { throw HealthSyncLeaseRefusal.unavailableAuthentication }
                return try CollectorFixture.makeLease(registry: registry)
            }

            await observer.deliver(Self.massType)
            #expect(source.queriedTypes.isEmpty, "nothing is read without an account")

            admitted.withLock { $0 = true }
            await observer.deliver(Self.stepType)

            #expect(Set(source.queriedTypes) == [Self.stepType, Self.massType])
            await collector.stopObserving()
        }

        // MARK: - Failed partitions

        @Test("a partition a failed cursor write closed is read again in the next pass")
        func failedWriteIsReopened() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: CollectorCursorBacking(), lease: lease)
            await #expect(throws: HealthSyncCursorStoreError.malformedAnchor) {
                try await store.save(anchor: Data(), for: key, requiring: lease)
            }
            #expect(await store.permitsCollection(for: key) == false)

            let source = TypeRecordingSource()
            let locks = LockLog()
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: []),
                partitionLocks: locks.sink
            )
            let results = await collector.collect(
                typeIdentifiers: [Self.stepType],
                trigger: .foreground,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(source.queriedTypes == [Self.stepType])
            #expect(results.first?.partitionLocked == false)
            #expect(await store.migrationState(for: key) == .replayingLegacy(
                quarantineReference: SpeziAnchorMigrator.speziGlobalAnchorKey(for: Self.stepType)
            ))
            #expect(locks.last?.locked == [:])
            #expect(locks.last?.checked == [Self.stepType])
        }

        @Test("a failed ownership proof stays closed and is reported as locked")
        func proofFailureStaysClosed() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: CollectorCursorBacking(), lease: lease)
            await store.failClosed(key, reason: "legacy owner proof did not match the partition")

            let source = TypeRecordingSource()
            let locks = LockLog()
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: []),
                partitionLocks: locks.sink
            )
            let results = await collector.collect(
                typeIdentifiers: [Self.stepType],
                trigger: .foreground,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(source.queriedTypes.isEmpty)
            #expect(results.first?.partitionLocked == true)
            #expect(locks.last?.locked == [Self.stepType: .closed])
            #expect(await store.permitsCollection(for: key) == false)
        }

        @Test("update path: a partition 1.6 left failed on disk collects again, from the cursor it had")
        func failedRecordFromAnEarlierBuild() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let key = try #require(HealthSyncCursorKey(ownerID: lease.ownerID, source: .speziSamples, typeIdentifier: Self.stepType))
            // What an earlier build wrote: a verified cursor, then a
            // later write that did not read back closed the partition.
            let seed = DurableHealthCursorStore(storage: backing.storage)
            _ = try await seed.migrate(key, legacyKey: "hl.unused", ownership: .provenOwner(lease.ownerID), requiring: lease)
            try await seed.save(anchor: Data([7, 7, 7]), for: key, requiring: lease)
            let failed = """
            {"version":2,"state":"failed","reason":"cursor write did not survive read back","updatedAt":0}
            """
            backing.storage.write(key.storageKey + ".migration", Data(failed.utf8))

            let store = DurableHealthCursorStore(storage: backing.storage)
            #expect(await store.migrationState(for: key) == .failed(reason: DurableHealthCursorStore.unverifiedWriteReason))
            #expect(try await store.reopenAfterFailedWrite(key, requiring: lease))
            #expect(await store.migrationState(for: key) == .verified)
            #expect(await store.anchor(for: key) == Data([7, 7, 7]))
        }

        @Test("only a failed write reopens; another account or a stale lease is refused")
        func reopenIsNarrow() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: CollectorCursorBacking(), lease: lease)

            // An open partition stays as it is.
            #expect(try await store.reopenAfterFailedWrite(key, requiring: lease))

            await store.failClosed(key, reason: "operator rollback")
            #expect(try await store.reopenAfterFailedWrite(key, requiring: lease) == false)
            #expect(await store.migrationState(for: key) == .failed(reason: "operator rollback"))

            // A current lease of another account never reopens this one's partition.
            await store.failClosed(key, reason: DurableHealthCursorStore.unverifiedWriteReason)
            let other = try CollectorFixture.makeLease(owner: "account-b", registry: registry)
            await #expect(throws: HealthSyncCursorStoreError.partitionOwnerMismatch) {
                try await store.reopenAfterFailedWrite(key, requiring: other)
            }
            // The first account's lease went stale with the switch.
            await #expect(throws: HealthSyncLeaseRefusal.staleSession) {
                try await store.reopenAfterFailedWrite(key, requiring: lease)
            }
            #expect(await store.migrationState(for: key) == .failed(reason: DurableHealthCursorStore.unverifiedWriteReason))
        }
    }
#endif
