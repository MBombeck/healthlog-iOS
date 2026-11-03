import Foundation
@testable import HealthLog
import Testing

/// A2 (1.4, #138) — the dose import marks its history as `backfill`.
///
/// The first sweep of a fresh account sends every dose Apple Health keeps,
/// years of them. The server records the trigger on its `MEDICATION_DOSE`
/// arrival entry; a `backfill` moves only `lastBackfillAt` there, so the
/// catch-up no longer reads as a fresh background arrival. Doses of the last
/// two days (the live window the sample streams use too) keep the pass's own
/// trigger and go first.
@Suite("Apple Health medications: history doses as backfill (A2)", .serialized, .mockURLSession)
struct AppleHealthMedicationBackfillTests {
    private static func dose(_ id: String, at instant: Date) -> AppleHealthDoseRecord {
        AppleHealthDoseRecord(
            eventUUID: id,
            conceptIdentifier: MedFixtures.conceptA,
            logStatus: .taken,
            scheduledAt: instant,
            takenAt: instant
        )
    }

    @Test("recent doses keep the pass's trigger and go first; older doses go out as backfill")
    func historyDosesAreBackfill() async throws {
        let recorder = MedicationRequestRecorder()
        AppleHealthMedicationWakeTests.installServer(recorder)
        let (api, keychain) = MedFixtures.makeAPI()
        let context = SyncTriggerContext()
        context.noteServerVersion(ServerVersionInfo(version: "1.43.0"))
        context.noteServerFeatures([.syncTriggerBackfill])
        let now = Date()
        let doses = [
            Self.dose("OLD-1", at: now.addingTimeInterval(-40 * 86400)),
            Self.dose("OLD-2", at: now.addingTimeInterval(-3 * 86400)),
            Self.dose("NEW-1", at: now.addingTimeInterval(-3600)),
            Self.dose("NEW-2", at: now.addingTimeInterval(-2 * 3600)),
            Self.dose("NEW-3", at: now.addingTimeInterval(-26 * 3600))
        ]
        let reader = FakeMedicationReader(medications: [AppleHealthMedicationWakeTests.medication], doses: doses)
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader, syncTrigger: context)

        let summary = await context.bind(.background) {
            await fixture.importer.sync()
        }

        #expect(recorder.bulkEntryCounts == [3, 2])
        #expect(recorder.bulkSyncTriggers == ["background", "backfill"])
        #expect(summary.dosesInserted == 5)
        #expect(fixture.ledger.pendingIdentities().isEmpty)
    }

    @Test("a server without backfill sees every dose under the pass's trigger")
    func olderServerSeesTheLiveTrigger() async throws {
        let recorder = MedicationRequestRecorder()
        AppleHealthMedicationWakeTests.installServer(recorder)
        let (api, keychain) = MedFixtures.makeAPI()
        let context = SyncTriggerContext()
        let now = Date()
        let doses = [
            Self.dose("OLD-1", at: now.addingTimeInterval(-40 * 86400)),
            Self.dose("NEW-1", at: now.addingTimeInterval(-3600))
        ]
        let reader = FakeMedicationReader(medications: [AppleHealthMedicationWakeTests.medication], doses: doses)
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader, syncTrigger: context)

        _ = await context.bind(.push) {
            await fixture.importer.sync()
        }

        #expect(recorder.bulkSyncTriggers.allSatisfy { $0 == "push" })
        #expect(recorder.bulkEntryCounts.reduce(0, +) == 2)
    }
}
