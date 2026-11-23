#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// The copy edits as the rest of the HealthKit path sees them: which ids
    /// and types an edit names, and how the deletion pages that follow HealthLog's
    /// own removals reach the mirror tombstones through the real
    /// `HealthLogStandard.consumeDeletions`.
    @Suite("HealthKit own copies: edit scope and deletion pages", .serialized, .mockURLSession)
    struct HealthKitOwnCopyDeletionPageTests {
        private static let instant = Date(timeIntervalSince1970: 1_790_000_000)

        private static func bloodPressure(_ id: String, diastolicID: String?, systolic: Double = 128) -> HealthLog.Measurement {
            HealthLog.Measurement(
                id: id,
                kind: .bloodPressure,
                recordedAt: instant,
                value: .bloodPressure(systolic: systolic, diastolic: 82),
                source: .manual,
                bloodPressureDiastolicId: diastolicID
            )
        }

        private static func freshOwner() -> String {
            "a3-\(UUID().uuidString)"
        }

        private static func tombstones(_ owner: String) -> Set<String> {
            HealthKitMirrorTombstones(ownerID: owner).ids
        }

        // MARK: - Scope

        @Test("blood pressure: both ids (with the old diastolic id) and both quantity types plus the correlation")
        func bloodPressureScope() {
            let edit = HealthKitService.copyEdit(removing: Self.bloodPressure("bp-sys", diastolicID: "bp-dia"))
            #expect(edit.kind == .remove)
            #expect(edit.serverIDs == ["bp-sys", "bp-dia"])
            #expect(Set(edit.typeIdentifiers) == [
                DeletionFixture.systolic,
                DeletionFixture.diastolic,
                HKCorrelationTypeIdentifier.bloodPressure.rawValue
            ])
        }

        @Test("a change records whether the number moved; a note alone does not")
        func changeFacts() {
            let old = Self.bloodPressure("bp-1", diastolicID: nil)
            let noteOnly = HealthLog.Measurement(
                id: "bp-1", kind: .bloodPressure, recordedAt: Self.instant,
                value: .bloodPressure(systolic: 128, diastolic: 82), note: "after coffee", source: .manual
            )
            let moved = Self.bloodPressure("bp-1", diastolicID: nil, systolic: 131)
            #expect(!HealthKitService.copyEdit(replacing: old, with: noteOnly).contentChanged)
            #expect(HealthKitService.copyEdit(replacing: old, with: moved).contentChanged)
            #expect(HealthKitService.copyEdit(replacing: old, with: moved).mirrorEligible)
        }

        @Test("a Withings row is mirror-eligible, so its edit is written back under the mirror's rule")
        func withingsIsEligible() {
            let old = HealthLog.Measurement(id: "w-1", kind: .weight, recordedAt: Self.instant, value: .scalar(81), source: .withings)
            let new = HealthLog.Measurement(id: "w-1", kind: .weight, recordedAt: Self.instant, value: .scalar(80.4), source: .withings)
            let edit = HealthKitService.copyEdit(replacing: old, with: new)
            #expect(edit.mirrorEligible)
            #expect(HealthKitOwnCopyEditor.replacementAction(writeAllowed: true, contentChanged: edit.contentChanged) == .removeAndRewrite)
        }

        // MARK: - Deletion pages

        @Test("blood pressure removed by HealthLog: systolic and diastolic pages leave no tombstone; a later deletion by the person does")
        func twoPagesNoTombstone() async throws {
            let owner = Self.freshOwner()
            defer { UserDefaults.standard.removeObject(forKey: HealthKitMirrorTombstones(ownerID: owner).key) }
            let id = "bp-\(UUID().uuidString)"
            let harness = try await Self.harness(owner: owner)
            let (standard, lease) = (harness.standard, harness.lease)
            HealthKitOwnCopyLedger.shared.noteSelfDeleted([
                (serverID: id, typeIdentifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue),
                (serverID: id, typeIdentifier: DeletionFixture.systolic),
                (serverID: id, typeIdentifier: DeletionFixture.diastolic)
            ])

            _ = await standard.consumeDeletions([], copiesOf: [id], ofType: DeletionFixture.systolic, requiring: lease)
            _ = await standard.consumeDeletions([], copiesOf: [id], ofType: DeletionFixture.diastolic, requiring: lease)
            #expect(Self.tombstones(owner).isEmpty)

            _ = await standard.consumeDeletions([], copiesOf: [id], ofType: DeletionFixture.systolic, requiring: lease)
            #expect(Self.tombstones(owner) == [id])
            withExtendedLifetime(harness) {}
        }

        @Test("edited twice in a row: both self-deletions of a type are answered, the third deletion is the person's")
        func doubleEditPages() async throws {
            let owner = Self.freshOwner()
            defer { UserDefaults.standard.removeObject(forKey: HealthKitMirrorTombstones(ownerID: owner).key) }
            let id = "w-\(UUID().uuidString)"
            let harness = try await Self.harness(owner: owner)
            let (standard, lease) = (harness.standard, harness.lease)
            HealthKitOwnCopyLedger.shared.noteSelfDeleted([(serverID: id, typeIdentifier: DeletionFixture.weight)])
            HealthKitOwnCopyLedger.shared.noteSelfDeleted([(serverID: id, typeIdentifier: DeletionFixture.weight)])

            _ = await standard.consumeDeletions([], copiesOf: [id, id], ofType: DeletionFixture.weight, requiring: lease)
            #expect(Self.tombstones(owner).isEmpty)

            _ = await standard.consumeDeletions([], copiesOf: [id], ofType: DeletionFixture.weight, requiring: lease)
            #expect(Self.tombstones(owner) == [id])
            withExtendedLifetime(harness) {}
        }

        /// The real deletion path for one account. The registry stays with the
        /// harness: the lease holds it weakly and refuses once it is gone.
        private struct Harness {
            let standard: HealthLogStandard
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
        }

        private static func harness(owner: String) async throws -> Harness {
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
            return Harness(standard: standard, registry: registry, lease: lease)
        }
    }
#endif
