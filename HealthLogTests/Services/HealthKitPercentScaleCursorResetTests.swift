#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// #113 — the one-time re-read of the SpO2 and body-fat partitions.
    ///
    /// The case that matters is the **existing installation**: a 1.0.3 phone
    /// whose two anchors already walked past every reading the old server
    /// refused. A fresh install proves nothing here — it has no anchor to drop.
    @Suite("SpO2 / body-fat cursor reset (#113)")
    struct HealthKitPercentScaleCursorResetTests {
        /// Records which anchor each type's first query resumed from.
        final class TypedPageSource: AnchoredHealthSampleQuerying, Sendable {
            private let resumed = Mutex<[String: [Int?]]>([:])
            private let nextAnchor: Int

            init(nextAnchor: Int) {
                self.nextAnchor = nextAnchor
            }

            func resumedAnchors(_ type: String) -> [Int?] {
                resumed.withLock { $0[type] ?? [] }
            }

            func page(
                typeIdentifier: String,
                resumingFrom anchor: HKQueryAnchor?,
                notBefore _: Date,
                limit _: Int
            ) async throws -> AnchoredHealthSamplePage {
                resumed.withLock { $0[typeIdentifier, default: []].append(anchor.flatMap(TypedPageSource.value)) }
                return AnchoredHealthSamplePage(
                    samples: [],
                    deletedObjectCount: 0,
                    newAnchor: HKQueryAnchor(fromValue: nextAnchor),
                    mayHaveMore: false
                )
            }

            /// `HKQueryAnchor` exposes no value; equality against a probe does.
            static func value(_ anchor: HKQueryAnchor) -> Int? {
                [0, 500, 900].first { HKQueryAnchor(fromValue: $0) == anchor }
            }
        }

        private static let spo2 = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        private static let bodyFat = HKQuantityTypeIdentifier.bodyFatPercentage.rawValue
        private static let heartRate = HKQuantityTypeIdentifier.heartRate.rawValue

        /// An installation that has been collecting under 1.0.3: every partition
        /// verified with an advanced anchor.
        private static func seedExistingInstall(
            backing: CollectorCursorBacking,
            lease: HealthSyncAuthenticatedLease
        ) async throws {
            let store = DurableHealthCursorStore(storage: backing.storage)
            for type in [spo2, bodyFat, heartRate] {
                let key = try #require(lease.cursorKey(typeIdentifier: type))
                try await store.save(HKQueryAnchor(fromValue: 500), for: key, requiring: lease)
                #expect(await store.migrationState(for: key) == .verified)
            }
        }

        private static func makeCoordinator(
            backing: CollectorCursorBacking,
            source: TypedPageSource,
            lease: HealthSyncAuthenticatedLease
        ) -> AppOwnedHealthCollectionCoordinator {
            // A fresh store per coordinator is a relaunch: nothing survives but
            // the backing storage.
            let cursors = DurableHealthCursorStore(storage: backing.storage)
            return AppOwnedHealthCollectionCoordinator(
                collector: AnchoredHealthSampleCollector(
                    cursors: cursors,
                    query: source,
                    consumer: ScriptedConsumer(outcomes: [])
                ),
                cursors: cursors,
                admission: { lease },
                cutoff: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
        }

        @Test("update path: an advanced SpO2/body-fat anchor is dropped once, the rest untouched, not again on relaunch")
        func existingInstallReReadsOnceAndOnlyOnce() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            try await Self.seedExistingInstall(backing: backing, lease: lease)

            // First launch of the fixed build.
            let firstSource = TypedPageSource(nextAnchor: 900)
            _ = await Self.makeCoordinator(backing: backing, source: firstSource, lease: lease).run(.manual)

            // The two percent partitions start over from the backfill window …
            #expect(firstSource.resumedAnchors(Self.spo2) == [nil])
            #expect(firstSource.resumedAnchors(Self.bodyFat) == [nil])
            // … and nothing else moved.
            #expect(firstSource.resumedAnchors(Self.heartRate) == [500])

            // Second launch: the re-read committed 900, and the reset does not
            // run again.
            let secondSource = TypedPageSource(nextAnchor: 900)
            _ = await Self.makeCoordinator(backing: backing, source: secondSource, lease: lease).run(.manual)
            #expect(secondSource.resumedAnchors(Self.spo2) == [900])
            #expect(secondSource.resumedAnchors(Self.bodyFat) == [900])
            #expect(secondSource.resumedAnchors(Self.heartRate) == [900])
        }

        @Test("the reset is per account: a second account on the same device gets its own")
        func resetIsPerAccount() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let backing = CollectorCursorBacking()
            let store = DurableHealthCursorStore(storage: backing.storage)

            let leaseA = try CollectorFixture.makeLease(owner: "account-a", registry: registry)
            #expect(await HealthKitPercentScaleCursorReset.apply(store: store, requiring: leaseA).count == 2)
            #expect(await HealthKitPercentScaleCursorReset.apply(store: store, requiring: leaseA).isEmpty)

            let leaseB = try CollectorFixture.makeLease(
                owner: "account-b",
                registry: registry,
                bearer: { "token-account-b" }
            )
            let keyB = try #require(leaseB.cursorKey(typeIdentifier: Self.spo2))
            #expect(await !store.hasApplied(reset: HealthKitPercentScaleCursorReset.resetID, for: keyB))
            #expect(await HealthKitPercentScaleCursorReset.apply(store: store, requiring: leaseB).count == 2)
        }

        @Test("a reset keeps the partition collectable and refuses another account's partition")
        func resetKeepsMigrationAndIsOwnerBound() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            try await Self.seedExistingInstall(backing: backing, lease: lease)
            let store = DurableHealthCursorStore(storage: backing.storage)
            let key = try #require(lease.cursorKey(typeIdentifier: Self.spo2))

            #expect(try await store.resetCursorOnce(HealthKitPercentScaleCursorReset.resetID, for: key, requiring: lease))
            #expect(await store.anchor(for: key) == nil)
            #expect(await store.migrationState(for: key) == .verified)
            #expect(await store.permitsCollection(for: key))

            let foreign = try #require(
                HealthSyncCursorKey(ownerID: "account-z", source: .speziSamples, typeIdentifier: Self.spo2)
            )
            await #expect(throws: HealthSyncCursorStoreError.partitionOwnerMismatch) {
                try await store.resetCursorOnce(HealthKitPercentScaleCursorReset.resetID, for: foreign, requiring: lease)
            }
        }
    }
#endif
