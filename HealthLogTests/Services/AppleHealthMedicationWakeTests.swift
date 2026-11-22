import Foundation
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

/// **W3 (iOS 1.3, #126 1.5 / HealthLog#1173, #1221)** — Apple Health
/// medications on every trigger, not only on "Sync all".
///
/// Three things kept a dose logged in Health away from the server until the app
/// was opened: the short wakes did not plan the import
/// (`HealthSyncCompositionPlan.incrementalSet`), nothing observed dose events,
/// and the bulk POST carried no `syncTrigger`, so the server's `MEDICATION_DOSE`
/// arrival record (v1.42.4) could never say "background". This suite pins all
/// three, plus the short-wake budget and the one-sweep-at-a-time rule.
///
/// `.serialized` — the suite installs a process-global `MockURLProtocol.handler`.
@Suite("Apple Health medications — wakes, observer and syncTrigger", .serialized, .mockURLSession)
struct AppleHealthMedicationWakeTests {
    // MARK: - Plans

    @Test(
        "every pull trigger plans the medication import",
        arguments: [
            HealthSyncTrigger.appRefresh, .silentPush, .processing, .foreground, .manual, .postAuthentication
        ]
    )
    func everyPullTriggerPlansTheImport(trigger: HealthSyncTrigger) {
        #expect(HealthSyncCompositionPlan.required(for: trigger).contains(.appleMedicationImport))
        let planned = HealthSyncCapabilityRegistry.unsupportedEverywhere()
            .plannedCapabilities(for: trigger, observedSource: nil)
        #expect(planned.contains(.appleMedicationImport))
    }

    @Test("a short wake runs the import with an incremental budget")
    func shortWakeBudgetIsIncremental() {
        for trigger in [HealthSyncTrigger.appRefresh, .silentPush] {
            #expect(HealthSyncBudget.required(for: trigger).incrementalOnly)
        }
    }

    // MARK: - Budget

    @Test("a short-wake sweep posts one chunk and keeps the rest pending")
    func shortWakePostsOneChunk() async throws {
        let recorder = MedicationRequestRecorder()
        Self.installServer(recorder)
        let (api, keychain) = MedFixtures.makeAPI()
        let reader = FakeMedicationReader(medications: [Self.medication], doses: Self.doses(count: 501))
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader)

        let summary = await fixture.importer.sync(maxDoseChunks: 1)

        #expect(recorder.bulkEntryCounts == [500])
        #expect(summary.dosesInserted == 500)
        #expect(summary.dosesDeferredToNextSweep == 1)
        #expect(fixture.ledger.pendingIdentities() == ["DOSE-0500"])

        // The next sweep has no budget and settles the one that waited. (The
        // fake reader ignores `since`, so it re-offers all 501; the 500 the
        // ledger already settled are not sent again.)
        let next = await fixture.importer.sync()
        #expect(recorder.bulkEntryCounts == [500, 1])
        #expect(next.dosesDeferredToNextSweep == 0)
        #expect(fixture.ledger.pendingIdentities().isEmpty)
    }

    @Test("a sweep with time to spare posts every chunk")
    func unboundedSweepPostsEverything() async throws {
        let recorder = MedicationRequestRecorder()
        Self.installServer(recorder)
        let (api, keychain) = MedFixtures.makeAPI()
        let reader = FakeMedicationReader(medications: [Self.medication], doses: Self.doses(count: 501))
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader)

        let summary = await fixture.importer.sync()

        #expect(recorder.bulkEntryCounts == [500, 1])
        #expect(summary.dosesDeferredToNextSweep == 0)
        #expect(fixture.ledger.pendingIdentities().isEmpty)
    }

    // MARK: - syncTrigger

    @Test(
        "the bulk POST carries the pass's syncTrigger",
        arguments: [SyncTrigger.background, .push, .foreground]
    )
    func bulkCarriesSyncTrigger(trigger: SyncTrigger) async throws {
        let recorder = MedicationRequestRecorder()
        Self.installServer(recorder)
        let (api, keychain) = MedFixtures.makeAPI()
        let context = SyncTriggerContext()
        let reader = FakeMedicationReader(medications: [Self.medication], doses: Self.doses(count: 1))
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader, syncTrigger: context)

        await context.bind(trigger) {
            _ = await fixture.importer.sync()
        }

        let body = try #require(recorder.lastBulkBody)
        #expect(body["syncTrigger"] as? String == trigger.rawValue)
    }

    @Test("manual reaches the wire only once the server is known to be 1.42 or later")
    func manualFollowsTheServerVersion() async throws {
        let recorder = MedicationRequestRecorder()
        Self.installServer(recorder)
        let (api, keychain) = MedFixtures.makeAPI()
        let context = SyncTriggerContext()
        let reader = FakeMedicationReader(medications: [Self.medication], doses: Self.doses(count: 1))
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader, syncTrigger: context)

        await context.bind(.manual) {
            _ = await fixture.importer.sync()
        }
        #expect(recorder.lastBulkBody?["syncTrigger"] as? String == "foreground")

        // A second installation: the first one settled its dose and sends nothing more.
        context.noteServerVersion(ServerVersionInfo(version: "1.42.4"))
        let second = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader, syncTrigger: context)
        await context.bind(.manual) {
            _ = await second.importer.sync()
        }
        #expect(recorder.lastBulkBody?["syncTrigger"] as? String == "manual")
    }

    // MARK: - scheduledFor (server v1.42.4, HealthLog#1221)

    @Test("an extra dose sends its own time as scheduledFor, never a slot")
    func extraDoseSendsItsOwnTime() throws {
        // Wednesday 20:45 for a Tuesday/Friday 22:00 medication (the #1221
        // report): Health logs it without a scheduled date.
        let takenAt = Date(timeIntervalSince1970: 1_791_398_700)
        let occurrence = AppleHealthDoseRecord.occurrenceDate(scheduledDate: nil, sampleStart: takenAt)
        let dose = AppleHealthDoseRecord(
            eventUUID: "EXTRA",
            conceptIdentifier: MedFixtures.conceptA,
            logStatus: .taken,
            scheduledAt: occurrence,
            takenAt: takenAt
        )
        let entry = try #require(MedicationsRepository.BulkIntakeEntry.appleHealth(dose: dose, mirroredMedicationId: "m"))
        #expect(entry.scheduledFor == takenAt)
        #expect(entry.takenAt == takenAt)
    }

    @Test("a scheduled dose names its slot, even when taken on another day")
    func scheduledDoseNamesItsSlot() throws {
        let slot = Date(timeIntervalSince1970: 1_791_324_000)
        let takenAt = slot.addingTimeInterval(10 * 3600)
        let dose = AppleHealthDoseRecord(
            eventUUID: "SCHEDULED",
            conceptIdentifier: MedFixtures.conceptA,
            logStatus: .taken,
            scheduledAt: AppleHealthDoseRecord.occurrenceDate(scheduledDate: slot, sampleStart: takenAt),
            takenAt: takenAt
        )
        let entry = try #require(MedicationsRepository.BulkIntakeEntry.appleHealth(dose: dose, mirroredMedicationId: "m"))
        #expect(entry.scheduledFor == slot)
        #expect(entry.takenAt == takenAt)
    }

    // MARK: - Fixtures

    static let medication = AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Magnesium")

    static func doses(count: Int) -> [AppleHealthDoseRecord] {
        (0 ..< count).map { index in
            let instant = Date(timeIntervalSince1970: 1_791_000_000 + Double(index) * 60)
            return AppleHealthDoseRecord(
                eventUUID: String(format: "DOSE-%04d", index),
                conceptIdentifier: MedFixtures.conceptA,
                logStatus: .taken,
                scheduledAt: instant,
                takenAt: instant
            )
        }
    }

    /// A server that already mirrors concept A and answers every bulk entry
    /// `inserted`, index by index.
    static func installServer(_ recorder: MedicationRequestRecorder) {
        MockURLProtocol.install { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = [(id: "srv-A", name: "Magnesium", externalId: Optional(MedFixtures.conceptA))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            if path == "/api/medications" {
                return (MedFixtures.ok(req), Data(MedFixtures.medEnvelope(id: "srv-A", name: "Magnesium").utf8))
            }
            let count = recorder.bulkEntryCounts.last ?? 0
            return (MedFixtures.ok(req), Data(bulkInserted(count).utf8))
        }
    }

    static func bulkInserted(_ count: Int) -> String {
        let entries = (0 ..< count).map { #"{"index":\#($0),"status":"inserted","id":"intake-\#($0)"}"# }
        return #"""
        {"data":{"processed":\#(count),"inserted":\#(count),"updated":0,"duplicates":0,\#
        "skipped":[],"entries":[\#(entries.joined(separator: ","))]},"error":null}
        """#
    }
}

// swiftlint:enable force_unwrapping
