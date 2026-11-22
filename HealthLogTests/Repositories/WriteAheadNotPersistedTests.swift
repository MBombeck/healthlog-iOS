import Foundation
@testable import HealthLog
import Testing

/// A write that is neither on the server nor on disk must not look saved.
///
/// Each test fails the send with an error the app normally answers with
/// "queued, will be sent later" and refuses the outbox write underneath it.
/// The caller has to hear `HLError.notPersisted`, the outbox has to be empty,
/// and a store on top has to tell the user instead of showing the entry.
@Suite("A write that is neither sent nor stored is reported as not saved")
struct WriteAheadNotPersistedTests {
    private func refusingOutbox() throws -> OutboxQueue {
        try OutboxQueue(inMemory: true, backgroundLease: WARefusingLease())
    }

    private var lostConnection: WAFailingAPI {
        WAFailingAPI(error: .network(.connectionLost))
    }

    private func expectNotPersisted(_ label: String, _ write: () async throws -> Void) async {
        do {
            try await write()
            Issue.record("\(label): the call returned as if the write were safe")
        } catch HLError.notPersisted {
            return
        } catch {
            Issue.record("\(label): expected notPersisted, got \(error)")
        }
    }

    // MARK: - Medication intakes

    @Test("a planned dose that could not be stored is not reported as queued")
    func plannedDose() async throws {
        let outbox = try refusingOutbox()
        let api = lostConnection
        let repo = MedicationsRepository(api: api, outbox: outbox)
        await expectNotPersisted("medications.record") {
            _ = try await repo.record(intake: "intake-1", status: .taken, takenAt: WAFixture.takenAt)
        }
        #expect(api.log.all.count == 1, "the dose was tried once and not sent again behind the caller's back")
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("a free dose that could not be stored is not reported as queued")
    func freeDose() async throws {
        let outbox = try refusingOutbox()
        let repo = MedicationsRepository(api: lostConnection, outbox: outbox)
        await expectNotPersisted("medications.logIntake") {
            _ = try await repo.logIntake(medicationId: "med-1", scheduledFor: nil, takenAt: WAFixture.takenAt, skipped: false)
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - The repositories that used to swallow the refusal

    @Test("FamilyHistoryRepository.create")
    func familyHistoryCreate() async throws {
        let outbox = try refusingOutbox()
        let repo = FamilyHistoryRepository(api: lostConnection, outbox: outbox)
        await expectNotPersisted("familyHistory.create") {
            _ = try await repo.create(FamilyHistoryCreate(relationship: .mother, condition: "Diabetes"))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("MentalHealthRepository.submit")
    func mentalHealthSubmit() async throws {
        let outbox = try refusingOutbox()
        let repo = MentalHealthRepository(api: lostConnection, outbox: outbox)
        await expectNotPersisted("mentalHealth.submit") {
            _ = try await repo.submit(CreateAssessmentRequest(instrument: .who5, items: [3, 3, 3, 3, 3]))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("MoodRepository.log and delete")
    func moodWrites() async throws {
        let outbox = try refusingOutbox()
        let repo = MoodRepository(api: lostConnection, outbox: outbox)
        await expectNotPersisted("mood.log") {
            _ = try await repo.log(score: 4, tags: [], note: nil)
        }
        await expectNotPersisted("mood.delete") {
            try await repo.delete(id: "mood-1")
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("CoachAboutMeRepository.dismissQuestion")
    func coachDismissQuestion() async throws {
        let outbox = try refusingOutbox()
        let repo = CoachAboutMeRepository(api: lostConnection, outbox: outbox)
        await expectNotPersisted("coachAboutMe.dismissQuestion") {
            _ = try await repo.dismissQuestion(CoachAboutMeDismissWrite(question: "Wie schläfst du?"))
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("MeasurementsRepository.delete and bulkDelete")
    func measurementDeletes() async throws {
        let outbox = try refusingOutbox()
        let repo = MeasurementsRepository(api: lostConnection, outbox: outbox)
        await expectNotPersisted("measurements.delete") {
            try await repo.delete(id: "m-1")
        }
        await expectNotPersisted("measurements.bulkDelete") {
            _ = try await repo.bulkDelete(ids: ["m-1", "m-2"])
        }
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("a delete in several chunks that cannot all be stored leaves none of them in the queue")
    func bulkDeleteStoredInPart() async throws {
        // Three chunks: the first is stored and fails on the wire, the second
        // is stored, the third is refused.
        let outbox = try OutboxQueue(inMemory: true, backgroundLease: WAExhaustedLease(grants: 2))
        let api = lostConnection
        let ids = (0 ... 2 * MeasurementsRepository.bulkDeleteMaxIDsPerBatch).map { "m-\($0)" }
        await expectNotPersisted("measurements.bulkDelete") {
            _ = try await MeasurementsRepository(api: api, outbox: outbox).bulkDelete(ids: ids)
        }
        #expect(api.log.all.count == 1)
        #expect(await outbox.snapshot.isEmpty, "the caller shows every row again, so no chunk may delete some of them later")
    }

    @Test("a delete in several chunks that can all be stored is queued whole and keeps its own error")
    func bulkDeleteStoredWhole() async throws {
        let outbox = try OutboxQueue(inMemory: true, backgroundLease: WAExhaustedLease(grants: 3))
        let ids = (0 ... 2 * MeasurementsRepository.bulkDeleteMaxIDsPerBatch).map { "m-\($0)" }
        await #expect(throws: HLError.network(.connectionLost)) {
            _ = try await MeasurementsRepository(api: lostConnection, outbox: outbox).bulkDelete(ids: ids)
        }
        let rows = await outbox.snapshot
        #expect(rows.map(\.kind) == [.bulkDeleteMeasurements, .bulkDeleteMeasurements, .bulkDeleteMeasurements])
        #expect(Set(rows.map(\.idempotencyKey)).count == 3)
    }

    // MARK: - What a refused write does NOT change

    @Test("a write the server answers needs no stored copy, so a refused outbox does not fail it")
    func landedWriteNeedsNoNet() async throws {
        let outbox = try refusingOutbox()
        let op = OutboxQueue.Operation(kind: .deleteMood, payload: Data("{}".utf8), idempotencyKey: "wa-landed")
        let answer = try await outbox.writeAhead(op) { "landed" }
        #expect(answer == "landed")
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("a write the server refuses keeps its own error, with or without a stored copy")
    func refusedWriteKeepsItsError() async throws {
        let outbox = try refusingOutbox()
        let refused = HLError.server(status: 422, code: "validation", message: "no")
        let repo = FamilyHistoryRepository(api: WAFailingAPI(error: refused), outbox: outbox)
        await #expect(throws: refused) {
            _ = try await repo.create(FamilyHistoryCreate(relationship: .mother, condition: "Diabetes"))
        }
    }

    // MARK: - The message reaches the user

    @Test("FamilyHistoryStore.create shows no entry and sets an error when the write is neither sent nor stored")
    @MainActor
    func storeReportsTheLoss() async throws {
        let outbox = try refusingOutbox()
        let store = FamilyHistoryStore(repository: FamilyHistoryRepository(api: lostConnection, outbox: outbox))
        let created = await store.create(FamilyHistoryCreate(relationship: .mother, condition: "Diabetes"))
        #expect(created == nil)
        #expect(store.records.isEmpty, "an optimistic row here would be an entry that exists nowhere")
        #expect(store.lastError != nil)
    }

    @Test("FamilyHistoryStore.create still shows the entry when the write is safely queued")
    @MainActor
    func storeKeepsAQueuedEntry() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let store = FamilyHistoryStore(repository: FamilyHistoryRepository(api: lostConnection, outbox: outbox))
        let created = await store.create(FamilyHistoryCreate(relationship: .mother, condition: "Diabetes"))
        #expect(created != nil)
        #expect(store.records.count == 1)
        #expect(store.lastError == nil)
        #expect(await outbox.snapshot.count == 1)
    }
}
