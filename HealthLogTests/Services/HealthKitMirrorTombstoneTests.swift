#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **A6 (1.4)** — a HealthLog copy the person deletes in Apple Health stays
    /// deleted there.
    ///
    /// The server mirror's tombstones were only ever filled from metadata a
    /// deleted object does not keep, so they stayed empty, and the next fresh
    /// page wrote a deleted copy straight back. Every copy now carries a sync
    /// identifier that names its server row, the one key HealthKit keeps on a
    /// deletion. Deleting a copy still deletes nothing on the server: the row
    /// stays, the copy stays deleted in Apple Health.
    ///
    /// The collector, `HealthLogStandard`, the repository, the `APIClient` and
    /// the planner are real; HealthKit and the server are stand-ins.
    @Suite("A6: a HealthLog copy deleted in Apple Health stays deleted", .serialized, .mockURLSession)
    struct HealthKitMirrorTombstoneTests {
        private static let instant = Date(timeIntervalSince1970: 1_790_000_000)

        /// Apple Health after the person deleted the copy: no sample carries
        /// the row's id, and no own sample sits at its instant.
        private static let copyGone = HealthKitServerMirrorProbe(
            isShareAuthorized: { _ in true },
            existsWithExternalIDs: { _, _ in false },
            ownSamplesNear: { _, _ in [] }
        )

        /// A fresh account per test. Its list lives in the standard defaults,
        /// as in the app, and is removed afterwards.
        private static func freshOwner() -> String {
            "a6-\(UUID().uuidString)"
        }

        private static func forget(_ owners: String...) {
            for owner in owners {
                UserDefaults.standard.removeObject(forKey: HealthKitMirrorTombstones(ownerID: owner).key)
            }
        }

        private static func tombstones(_ owner: String) -> Set<String> {
            HealthKitMirrorTombstones(ownerID: owner).ids
        }

        private static func webWeight(_ id: String) -> HealthLog.Measurement {
            HealthLog.Measurement(id: id, kind: .weight, recordedAt: instant, value: .scalar(81.2), source: .manual)
        }

        private typealias Plan = HealthKitServerMirrorPlanner.Plan

        private static func mirror(_ rows: [HealthLog.Measurement], excluding: Set<String> = []) async -> Plan {
            await HealthKitServerMirrorPlanner.plan(rows, excluding: excluding, probe: copyGone)
        }

        /// The real deletion path for one account, behind the scripted
        /// HealthKit pages.
        private struct Harness {
            let wire: DeletionWire
            let standard: HealthLogStandard
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let cursors: DurableHealthCursorStore
            let keys: [String: HealthSyncCursorKey]

            static func make(owner: String, types: [String]) async throws -> Harness {
                let wire = DeletionWire()
                wire.install()
                let api = DeletionFixture.api()
                let outbox = try DeletionFixture.outbox()
                let standard = await DeletionFixture.standard(
                    api: api,
                    outbox: outbox,
                    reconciler: MeasurementsRepository(api: api, outbox: outbox)
                )
                let registry = AuthenticatedSessionLeaseRegistry()
                let lease = try CollectorFixture.makeLease(owner: owner, registry: registry)
                let (cursors, keys) = try await DeletionFixture.cursors(for: types, lease: lease)
                return Harness(wire: wire, standard: standard, registry: registry, lease: lease, cursors: cursors, keys: keys)
            }

            func collect(
                _ types: [String],
                pages: [AnchoredHealthSamplePage]
            ) async -> [AnchoredHealthSampleCollector.TypeResult] {
                let collector = AnchoredHealthSampleCollector(
                    cursors: cursors,
                    query: ScriptedPageSource(pages: pages),
                    consumer: standard
                )
                return await collector.collect(typeIdentifiers: types, trigger: .manual, notBefore: .distantPast, requiring: lease)
            }
        }

        // MARK: - The reported case

        @Test("a mirror copy deleted in Apple Health is remembered, sends nothing, and is not written back")
        func mirrorCopyStaysDeleted() async throws {
            let owner = Self.freshOwner()
            defer { Self.forget(owner) }
            let harness = try await Harness.make(owner: owner, types: [DeletionFixture.weight])
            let row = Self.webWeight("srv-w-1")
            let copy = try #require(await Self.mirror([row]).samples.first)
            let expected = "dev.healthlog.measurement/HKQuantityTypeIdentifierBodyMass/srv-w-1"
            #expect(copy.metadata?[HKMetadataKeySyncIdentifier] as? String == expected)
            #expect(copy.metadata?[HKMetadataKeySyncVersion] as? Int == 1)

            // The person deletes the copy in the Health app.
            let results = await harness.collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: copy)], anchor: 4)]
            )

            #expect(harness.wire.all.isEmpty, "the copy was never uploaded; the server row stays")
            #expect(Self.tombstones(owner) == [row.id])
            #expect(results.first?.holdReason == nil)
            let key = try #require(harness.keys[DeletionFixture.weight])
            #expect(await harness.cursors.queryAnchor(for: key) == HKQueryAnchor(fromValue: 4))
            // The next fresh page still lists the row. Without the tombstone the
            // mirror would write it again; with it, it leaves the row alone.
            #expect(await Self.mirror([row]).samples.count == 1)
            #expect(await Self.mirror([row], excluding: Self.tombstones(owner)).samples.isEmpty)
        }

        @Test("a reading typed in HealthLog and deleted in Apple Health is not written back either")
        func appEntryCopyStaysDeleted() async throws {
            let owner = Self.freshOwner()
            defer { Self.forget(owner) }
            let glucose = HKQuantityTypeIdentifier.bloodGlucose.rawValue
            let harness = try await Harness.make(owner: owner, types: [glucose])
            // What the create-time write saves (`performWrite`) for a row the
            // POST has just given its server id.
            let row = HealthLog.Measurement(
                id: "srv-g-1", kind: .glucose, recordedAt: Self.instant, value: .scalar(104), source: .manual
            )
            let copy = try #require(HealthKitService.quantitySamples(
                for: row,
                metadata: HealthKitService.createTimeMetadata(for: row)
            ).first)
            #expect(copy.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true)

            _ = await harness.collect(
                [glucose],
                pages: [DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: copy)], anchor: 2)]
            )

            #expect(harness.wire.all.isEmpty, "glucose deletions are forwarded, but not the deletion of a copy")
            #expect(Self.tombstones(owner) == [row.id])
            // The row is MANUAL, so every fresh page offers it to the mirror.
            #expect(await Self.mirror([row], excluding: Self.tombstones(owner)).samples.isEmpty)
        }

        @Test("an Apple Health original is still sent to the delete route, also next to a deleted copy")
        func originalsAreStillForwarded() async throws {
            let owner = Self.freshOwner()
            defer { Self.forget(owner) }
            let harness = try await Harness.make(owner: owner, types: [DeletionFixture.weight])
            let row = Self.webWeight("srv-w-2")
            let copy = try #require(await Self.mirror([row]).samples.first)
            // A scale app that keeps its own sync identifier, and a reading
            // typed in the Health app without any metadata.
            let scale = HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
                start: Self.instant,
                end: Self.instant,
                metadata: [HKMetadataKeySyncIdentifier: "scale-reading-7781", HKMetadataKeySyncVersion: 3]
            )
            let typed = HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 79.5),
                start: Self.instant,
                end: Self.instant
            )

            let results = await harness.collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(of: [scale, copy, typed].map(DeletionFixture.deletedObject(of:)), anchor: 6)]
            )

            #expect(harness.wire.all.map(\.externalIds) == [[scale.uuid.uuidString, typed.uuid.uuidString]])
            #expect(Self.tombstones(owner) == [row.id])
            #expect(results.first?.holdReason == nil)
        }

        // MARK: - Blood pressure

        @Test("a blood pressure deleted in Apple Health is remembered once from both halves and stays deleted")
        func bloodPressureStaysDeleted() async throws {
            let owner = Self.freshOwner()
            defer { Self.forget(owner) }
            let types = [DeletionFixture.systolic, DeletionFixture.diastolic]
            let harness = try await Harness.make(owner: owner, types: types)
            let row = HealthLog.Measurement(
                id: "srv-bp-sys",
                kind: .bloodPressure,
                recordedAt: Self.instant,
                value: .bloodPressure(systolic: 128, diastolic: 84),
                source: .manual,
                bloodPressureDiastolicId: "srv-bp-dia"
            )
            let correlation = try #require(await Self.mirror([row]).objects.first as? HKCorrelation)
            let halves = correlation.objects.compactMap { $0 as? HKQuantitySample }
            let systolic = try #require(halves.first { $0.quantityType == HKQuantityType(.bloodPressureSystolic) })
            let diastolic = try #require(halves.first { $0.quantityType == HKQuantityType(.bloodPressureDiastolic) })
            // Three objects, three identifiers, one row.
            let objects: [HKObject] = [correlation, systolic, diastolic]
            let identifiers = objects.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }
            #expect(Set(identifiers).count == 3)
            #expect(identifiers.allSatisfy { HealthKitCopySyncIdentity.serverID(fromSyncIdentifier: $0) == row.id })

            // Deleting the reading in Health deletes the correlation and both
            // halves; each half's type reports its own deletion.
            let results = await harness.collect(
                types,
                pages: [
                    DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: systolic)], anchor: 3),
                    DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: diastolic)], anchor: 4)
                ]
            )

            #expect(harness.wire.all.isEmpty)
            #expect(Self.tombstones(owner) == [row.id])
            #expect(results.allSatisfy { $0.holdReason == nil })
            #expect(await Self.mirror([row], excluding: Self.tombstones(owner)).samples.isEmpty)
        }

        // MARK: - Every written kind

        @Test("every kind HealthLog writes into Apple Health carries an identifier naming its row")
        func everyWrittenKindNamesItsRow() async {
            for kind in MetricKind.serverMirrorWritableKinds {
                let value: MeasurementValue = kind == .bloodPressure ? .bloodPressure(systolic: 120, diastolic: 80) : .scalar(1)
                let row = HealthLog.Measurement(
                    id: "srv-\(kind.rawValue)", kind: kind, recordedAt: Self.instant, value: value, source: .manual
                )
                let written = await Self.mirror([row])
                #expect(!written.samples.isEmpty, "\(kind.rawValue)")
                let split = HealthKitCopySyncIdentity.split(written.samples.map(DeletionFixture.deletedObject(of:)))
                #expect(split.sampleIDs.isEmpty, "\(kind.rawValue)")
                #expect(Set(split.copyServerIDs) == [row.id], "\(kind.rawValue)")
            }
            // The eligibility probes build samples without metadata, and stay so.
            let probe = HealthKitService.quantitySamples(for: Self.webWeight("srv-x"), metadata: [:])
            #expect(probe.first?.metadata?[HKMetadataKeySyncIdentifier] == nil)
        }

        @Test("only HealthLog's own identifier names a server row")
        func identifierParsing() {
            let identifier = HealthKitCopySyncIdentity.identifier(serverID: "srv/odd-1", typeIdentifier: "HKQuantityTypeIdentifierBodyMass")
            #expect(identifier == "dev.healthlog.measurement/HKQuantityTypeIdentifierBodyMass/srv/odd-1")
            #expect(HealthKitCopySyncIdentity.serverID(fromSyncIdentifier: identifier) == "srv/odd-1")
            let foreign: [Any?] = [
                nil,
                42,
                "scale-reading-7781",
                "dev.healthlog.measurement/",
                "dev.healthlog.measurement/srv-1",
                "dev.healthlog.measurement//srv-1",
                "dev.healthlog.measurement/HKQuantityTypeIdentifierBodyMass/"
            ]
            for value in foreign {
                #expect(HealthKitCopySyncIdentity.serverID(fromSyncIdentifier: value) == nil)
            }
        }

        // MARK: - Owners

        @Test("tombstones belong to the account that deleted: the mirror reads the signed-in account's list")
        func tombstonesArePerAccount() async throws {
            let ownerA = Self.freshOwner()
            let ownerB = Self.freshOwner()
            defer { Self.forget(ownerA, ownerB) }
            let harness = try await Harness.make(owner: ownerA, types: [DeletionFixture.weight])
            let row = Self.webWeight("srv-w-3")
            let copy = try #require(await Self.mirror([row]).samples.first)

            _ = await harness.collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: copy)], anchor: 5)]
            )

            #expect(Self.tombstones(ownerA) == [row.id])
            #expect(Self.tombstones(ownerB).isEmpty)
            let keychain = InMemoryKeychain()
            try keychain.setString(ownerA, forKey: KeychainKey.userID)
            let service = HealthKitService(keychain: keychain, bundleID: "dev.healthlog.app")
            #expect(await service.serverMirrorExclusions() == [row.id])
            try keychain.setString(ownerB, forKey: KeychainKey.userID)
            #expect(await service.serverMirrorExclusions().isEmpty)
        }

        @Test("a pass whose account has signed out records nothing and holds, so the deletion is read again")
        func signedOutPassRecordsNothing() async throws {
            let owner = Self.freshOwner()
            defer { Self.forget(owner) }
            let harness = try await Harness.make(owner: owner, types: [DeletionFixture.weight])
            harness.registry.invalidate()

            let held = await harness.standard.consumeDeletions(
                [],
                copiesOf: ["srv-w-4"],
                ofType: DeletionFixture.weight,
                requiring: harness.lease
            )

            #expect(held != nil)
            #expect(Self.tombstones(owner).isEmpty)
        }

        // MARK: - Update path from 1.3.0

        @Test("update path: a copy 1.3.0 wrote goes out like an original once, comes back with an identifier, and then stays deleted")
        func copyFrom130() async throws {
            let owner = Self.freshOwner()
            defer { Self.forget(owner) }
            let harness = try await Harness.make(owner: owner, types: [DeletionFixture.weight])
            let row = Self.webWeight("srv-w-legacy")
            let legacy = DeletionFixture.legacyCopy(of: row, kilograms: 81.2)

            // 1. Its deletion keeps no metadata, so nothing tells it from a
            //    reading another app wrote: it goes to the delete route, a
            //    no-op there (the copy was never uploaded), and no tombstone.
            _ = await harness.collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: legacy)], anchor: 1)]
            )
            #expect(harness.wire.deletedIDs == [legacy.uuid.uuidString])
            #expect(Self.tombstones(owner).isEmpty)

            // 2. So the mirror writes the reading once more, now with its
            //    identifier.
            let rewritten = try #require(await Self.mirror([row], excluding: Self.tombstones(owner)).samples.first)
            #expect(HealthKitCopySyncIdentity.serverID(fromSyncIdentifier: rewritten.metadata?[HKMetadataKeySyncIdentifier]) == row.id)

            // 3. Deleting that copy sticks.
            _ = await harness.collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(of: [DeletionFixture.deletedObject(of: rewritten)], anchor: 2)]
            )
            #expect(harness.wire.all.count == 1, "nothing more went to the server")
            #expect(Self.tombstones(owner) == [row.id])
            #expect(await Self.mirror([row], excluding: Self.tombstones(owner)).samples.isEmpty)
        }

        @Test("update path: the 1.3.0 list key and an unreadable value leave each account's list empty and writable")
        func storeFrom130() throws {
            let suite = "hl.test.a6.tombstones.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // The global 1.3.0 key. No shipped build wrote it, but a value
            // there must not leak into any account's list.
            let legacyKey = "hl.healthkit.serverMirror.tombstones.v1"
            defaults.set(["srv-old"], forKey: legacyKey)
            let tombstones = HealthKitMirrorTombstones(ownerID: "account-a", defaults: defaults)
            defaults.set(42, forKey: tombstones.key)

            #expect(tombstones.ids.isEmpty)
            tombstones.record(["srv-1"])
            #expect(tombstones.ids == ["srv-1"])
            #expect(HealthKitMirrorTombstones(ownerID: "account-b", defaults: defaults).ids.isEmpty)
            #expect(defaults.stringArray(forKey: legacyKey) == ["srv-old"])
        }

        // MARK: - Bound

        @Test("each account's list is bounded: the newest ids stay, a repeat moves to the end")
        func listIsBounded() throws {
            let suite = "hl.test.a6.bound.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let tombstones = HealthKitMirrorTombstones(ownerID: "account-a", defaults: defaults)
            // 2000 server ids of about 25 characters are some 60 KB, read once
            // per fresh page. Far more than anyone deletes by hand; deleting
            // all of HealthLog's data in Health at once keeps the newest 2000.
            #expect(HealthKitMirrorTombstones.capacity == 2000)

            tombstones.record(["first"])
            tombstones.record((0 ..< HealthKitMirrorTombstones.capacity).map { "n\($0)" })
            #expect(tombstones.ids.count == HealthKitMirrorTombstones.capacity)
            #expect(!tombstones.ids.contains("first"))

            tombstones.record(["n0", "n0", ""])
            tombstones.record(["latest"])
            #expect(tombstones.ids.count == HealthKitMirrorTombstones.capacity)
            #expect(tombstones.ids.contains("n0"))
            #expect(!tombstones.ids.contains("n1"))
            #expect(tombstones.ids.contains("latest"))
        }

        // MARK: - Waist circumference

        @Test("a waist circumference deleted in Apple Health goes to the delete route under its UUID")
        func waistDeletionIsForwarded() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let server = RecordingDeletionServer()
            let waist = HKQuantityTypeIdentifier.waistCircumference.rawValue

            let held = await HealthSampleDeletionForwarder(server: server, queue: nil)
                .forward(["WAIST-UUID"], ofType: waist, requiring: lease)

            #expect(held == nil)
            #expect(server.sent == [["WAIST-UUID"]])
            // B5's read path sends it raw, under that same UUID.
            let sample = HKQuantitySample(
                type: HKQuantityType(.waistCircumference),
                quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: 86),
                start: Self.instant,
                end: Self.instant
            )
            let entry = try #require(HealthKitWireConverter.entries(from: sample).first)
            #expect(entry.externalId == sample.uuid.uuidString)
        }
    }
#endif
