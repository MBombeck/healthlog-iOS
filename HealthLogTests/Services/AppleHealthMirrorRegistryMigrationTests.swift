import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-10 / GH #47** — the poisoned-registry migration.
///
/// Every key written before CU-10 was
/// `String(describing: HKHealthConceptIdentifier)` — a memory address that never
/// recurs. Those entries point at phantom server rows and can never be hit
/// again, so the upgrade has to discard them rather than carry them forward.
@Suite("AppleHealthMirrorRegistry — CU-10 key-schema migration")
struct AppleHealthMirrorRegistryMigrationTests {
    private func suiteName() -> String {
        "applemed.registry.\(UUID().uuidString)"
    }

    private func defaults(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    private func makeRegistry(_ name: String) -> AppleHealthMirrorRegistry {
        AppleHealthMirrorRegistry(userID: "user-mig", defaultsProvider: { UserDefaults(suiteName: name)! })
    }

    /// Seed the legacy layout directly (no schema stamp, pointer-shaped keys) —
    /// exactly what an app upgraded from the defective build carries.
    private func seedLegacy(_ name: String, map: [String: String], cursor: Date?) {
        let store = defaults(name)
        store.removePersistentDomain(forName: name)
        let token = HealthKitBackfillWindowStore.partitionToken(for: "user-mig")
        store.set(map, forKey: "hl.medications.appleHealth.conceptMap." + token)
        if let cursor {
            store.set(cursor.timeIntervalSince1970, forKey: "hl.medications.appleHealth.doseCursor." + token)
        }
    }

    private let stableKey = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("lisinopril".utf8))

    @Test("Pointer-shaped keys are discarded on first construction")
    func discardsPointerShapedKeys() {
        let name = suiteName()
        seedLegacy(
            name,
            map: [
                "<HKHealthConceptIdentifier: 0x12568db80>": "srv-phantom-1",
                "<HKHealthConceptIdentifier: 0x126b25160>": "srv-phantom-2",
                "0x11f47e3e0": "srv-phantom-3"
            ],
            cursor: Date(timeIntervalSince1970: 1_783_000_000)
        )

        let registry = makeRegistry(name)

        #expect(registry.conceptMap().isEmpty)
        #expect(registry.medicationId(forConcept: "<HKHealthConceptIdentifier: 0x12568db80>") == nil)
        // The doses those concepts held back must be re-read, so the cursor goes
        // with the map. The re-import is idempotent on the dose-event UUID.
        #expect(registry.doseCursor() == nil)
    }

    @Test("A key already written under the new scheme survives the migration")
    func keepsNewSchemeKeys() {
        let name = suiteName()
        seedLegacy(
            name,
            map: [
                stableKey: "srv-real",
                "<HKHealthConceptIdentifier: 0x12568db80>": "srv-phantom"
            ],
            cursor: nil
        )

        let registry = makeRegistry(name)

        #expect(registry.conceptMap() == [stableKey: "srv-real"])
        #expect(registry.medicationId(forConcept: stableKey) == "srv-real")
    }

    @Test("The migration runs once — a later write is not discarded again")
    func migrationIsIdempotent() {
        let name = suiteName()
        seedLegacy(name, map: ["<HKHealthConceptIdentifier: 0x1>": "srv-phantom"], cursor: nil)

        let first = makeRegistry(name)
        #expect(first.conceptMap().isEmpty)

        first.recordMirror(conceptIdentifier: stableKey, medicationId: "srv-real")
        // **Plan 07-05.** `advanceDoseCursor(to:)` is gone — the date watermark
        // it wrote is the defect ``AppleHealthDoseLedger`` replaces, and nothing
        // in production writes it any more. What this test always meant is
        // unchanged and still asserted: a second construction re-runs the
        // migration check and leaves an already-migrated partition alone,
        // including the frozen legacy cursor the ledger seeds itself from. The
        // value is therefore written the way an upgraded install carries it —
        // directly, by the build that predates this plan.
        let token = HealthKitBackfillWindowStore.partitionToken(for: "user-mig")
        defaults(name).set(
            Date(timeIntervalSince1970: 1_783_000_000).timeIntervalSince1970,
            forKey: "hl.medications.appleHealth.doseCursor." + token
        )

        // A freshly constructed registry over the same defaults re-runs the
        // migration check and must leave the rebuilt map alone.
        let second = makeRegistry(name)
        #expect(second.medicationId(forConcept: stableKey) == "srv-real")
        #expect(second.doseCursor() == Date(timeIntervalSince1970: 1_783_000_000))
    }

    @Test("A clean install migrates nothing and keeps working")
    func cleanInstallIsUntouched() {
        let name = suiteName()
        defaults(name).removePersistentDomain(forName: name)

        let registry = makeRegistry(name)
        #expect(registry.conceptMap().isEmpty)

        registry.recordMirror(conceptIdentifier: stableKey, medicationId: "srv-1")
        #expect(makeRegistry(name).medicationId(forConcept: stableKey) == "srv-1")
    }

    // MARK: - Server reconciliation

    @Test("Reconcile adopts a server-known mirror and drops a mapping whose medication is gone")
    func reconcileFoldsServerTruth() {
        let name = suiteName()
        defaults(name).removePersistentDomain(forName: name)
        let registry = makeRegistry(name)
        registry.recordMirror(conceptIdentifier: stableKey, medicationId: "srv-deleted")

        let otherKey = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("metformin".utf8))
        registry.reconcile(
            serverMirrors: [otherKey: "srv-known"],
            knownMedicationIDs: ["srv-known", "srv-native"]
        )

        // `srv-deleted` is no longer an account medication → the stale mapping goes.
        #expect(registry.medicationId(forConcept: stableKey) == nil)
        // The server knows a mirror this device did not → adopted without a POST.
        #expect(registry.medicationId(forConcept: otherKey) == "srv-known")
    }

    @Test("Reconcile keeps a mapping whose medication still exists")
    func reconcileKeepsLiveMapping() {
        let name = suiteName()
        defaults(name).removePersistentDomain(forName: name)
        let registry = makeRegistry(name)
        registry.recordMirror(conceptIdentifier: stableKey, medicationId: "srv-1")

        registry.reconcile(serverMirrors: [:], knownMedicationIDs: ["srv-1"])

        #expect(registry.medicationId(forConcept: stableKey) == "srv-1")
    }
}

// swiftlint:enable force_unwrapping
