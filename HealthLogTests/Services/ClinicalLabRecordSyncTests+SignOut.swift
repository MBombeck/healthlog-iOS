import Foundation
@testable import HealthLog
import Testing

/// Sign-out and the update path for Health Records labs (D4): the answer
/// belongs to the account, and a device updated from 1.6 stays quiet.
extension ClinicalLabRecordSyncTests {
    @MainActor
    @Test("sign-out takes the answer back: the next account is asked, and nothing is read for it")
    func signOutTakesTheAnswerBack() async {
        let defaults = Self.defaults()
        let reader = ClinicalLabFakeReader(records: [Self.record(1)])
        let uploader = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("inserted", nil) }) }
        let importer = Self.importer(reader: reader, uploader: uploader, defaults: defaults)
        let store = ClinicalLabRecordsStore(importer: importer, readsHealthKit: true, defaults: defaults)
        await store.connect()
        let cursors = ClinicalLabRecordCursorStore(defaults: defaults)
        #expect(cursors.load(owner: "owner-a").lastPass != nil)

        store.clearOnLogout()
        cursors.clear(owner: "owner-a")

        #expect(store.consent == .notAsked)
        #expect(store.offersCard)
        #expect(ClinicalLabRecordsConsent.current(defaults: defaults) == .notAsked)
        #expect(cursors.load(owner: "owner-a").lastPass == nil)
        #expect(await importer.sync() == .off)
        #expect(await uploader.calls.count == 1)
    }

    @MainActor
    @Test("a device updated with an answer keeps it until its account signs out")
    func updatedAnswerStaysUntilSignOut() async {
        // 1.6 wrote the same key; the signed-in account keeps syncing.
        let defaults = Self.defaults()
        defaults.set(ClinicalLabRecordsConsent.requested.rawValue, forKey: ClinicalLabRecordsConsent.defaultsKey)
        let uploader = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("inserted", nil) }) }
        let importer = Self.importer(reader: ClinicalLabFakeReader(records: [Self.record(1)]), uploader: uploader, defaults: defaults)
        let store = ClinicalLabRecordsStore(importer: importer, readsHealthKit: true, defaults: defaults)
        #expect(store.consent == .requested)
        #expect(!store.offersCard)
        guard case .completed = await importer.sync() else {
            Issue.record("the updated answer did not sync")
            return
        }
        store.clearOnLogout()
        #expect(defaults.object(forKey: ClinicalLabRecordsConsent.defaultsKey) == nil)
    }

    @Test("an existing installation without the permission reads and asks nothing on a sync pass")
    func updatePathStaysQuiet() async {
        // A device updated from 1.6: no consent key at all.
        let defaults = Self.defaults()
        #expect(ClinicalLabRecordsConsent.current(defaults: defaults) == .notAsked)
        let reader = ClinicalLabFakeReader(records: [Self.record(1)])
        let uploader = ClinicalLabFakeUploader { _ in Self.response([]) }
        let importer = Self.importer(reader: reader, uploader: uploader, defaults: defaults)
        #expect(await importer.sync() == .off)
        #expect(await reader.authorizationRequests == 0)
        #expect(await reader.reads == 0)
        #expect(await uploader.calls.isEmpty)
        // The orchestrator hears "disabled", which is not an omission.
        #expect(ClinicalLabSyncPassResult.off.capabilityResult(.clinicalLabRecords).disposition == .disabled)
    }
}
