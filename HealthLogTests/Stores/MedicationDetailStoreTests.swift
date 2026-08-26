import Foundation
@testable import HealthLog
import Testing

/// Tests for `MedicationDetailStore` — brand detection, PK input building,
/// and the MDR chart-gate predicate.
@MainActor
@Suite("MedicationDetailStore")
struct MedicationDetailStoreTests {
    // MARK: - Brand detection

    @Test("Mounjaro 7.5 mg medication resolves to tirzepatide")
    func mounjaroResolvesToTirzepatide() {
        let med = makeMedication(
            name: "Mounjaro 7.5 mg",
            treatmentClass: "GLP1"
        )
        let store = MedicationDetailStore(medication: med, repo: makeRepo())
        #expect(store.drug?.id == .tirzepatide)
        #expect(store.isGLP1Recognised == true)
        #expect(store.isUnknownGLP1Brand == false)
    }

    @Test("Paracetamol is not a GLP-1 medication")
    func paracetamolIsNotGLP1() {
        let med = makeMedication(
            name: "Paracetamol 500mg",
            treatmentClass: "GENERIC"
        )
        let store = MedicationDetailStore(medication: med, repo: makeRepo())
        #expect(store.drug == nil)
        #expect(store.isGLP1Recognised == false)
        #expect(store.isUnknownGLP1Brand == false)
    }

    @Test("Unknown GLP-1 brand surfaces the unknown-drug state")
    func unknownGlp1Brand() {
        let med = makeMedication(
            name: "Brandnew GLP1 drug",
            treatmentClass: "GLP1"
        )
        let store = MedicationDetailStore(medication: med, repo: makeRepo())
        #expect(store.drug == nil)
        #expect(store.isGLP1Recognised == false)
        #expect(store.isUnknownGLP1Brand == true)
    }

    // MARK: - Headline dose parser

    @Test("Headline dose parser handles common GLP-1 strings")
    func headlineDoseParser() {
        #expect(MedicationDetailStore.parseHeadlineDose("7.5 mg") == 7.5)
        #expect(MedicationDetailStore.parseHeadlineDose("1 mg") == 1.0)
        #expect(MedicationDetailStore.parseHeadlineDose("0.5 mg") == 0.5)
        #expect(MedicationDetailStore.parseHeadlineDose("2,4 mg") == 2.4) // comma decimal
        #expect(MedicationDetailStore.parseHeadlineDose("12.5mg") == 12.5)
    }

    @Test("Headline dose parser falls back to nil on garbage")
    func headlineDoseFallback() {
        #expect(MedicationDetailStore.parseHeadlineDose("") == nil)
        #expect(MedicationDetailStore.parseHeadlineDose("ohne Dosis") == nil)
        #expect(MedicationDetailStore.parseHeadlineDose("mg") == nil)
    }

    // MARK: - Helpers

    private func makeMedication(name: String, treatmentClass: String?) -> Medication {
        Medication(
            id: "med_test",
            name: name,
            dose: "7.5 mg",
            treatmentClass: treatmentClass,
            schedule: MedicationSchedule(times: [], weekdays: nil)
        )
    }

    private func makeRepo() -> MedicationsRepository {
        // We construct the repo against a stub APIClient that never actually
        // dispatches — these tests only exercise the synchronous resolution
        // path (drug detection, helper math). The repo + outbox are required
        // by the init signature but unreferenced by the assertions below.
        let stub = DetailStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        return MedicationsRepository(api: stub, outbox: outbox)
    }
}

// MARK: - Stub API client

private final class DetailStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.canceled
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.canceled
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.canceled
    }
}
