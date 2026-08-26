import Foundation
@testable import HealthLog
import Testing

/// State-machine tests for `MedicationDetailStore` — covers the four
/// branches `MDRGatedDrugLevelSection` switches on:
///
/// 1. Non-GLP-1 medication (`treatmentClass != "GLP1"`) — no chart-section
///    rendered at all.
/// 2. Unknown GLP-1 brand — `isUnknownGLP1Brand == true`, falls back to the
///    "not in EMA catalog" placeholder.
/// 3. Recognised GLP-1 brand — full PK input pipeline.
/// 4. Headline-dose fallback when no dose-change history is present.
///
/// Image snapshots are intentionally skipped (same rationale as
/// `AuthenticatedShellTabsTests` — pixel-fragile across SDKs). We assert on
/// the **observable contract** instead.
@MainActor
@Suite("MedicationDetailScreen state contract")
struct MedicationDetailScreenStateTests {
    @Test("Non-GLP-1 medication: chart-section is hidden + unknown-brand state false")
    func nonGLP1HidesChart() {
        let store = makeStore(name: "Paracetamol 500mg", treatmentClass: "GENERIC")
        #expect(store.isGLP1Recognised == false)
        #expect(store.isUnknownGLP1Brand == false)
        #expect(store.drug == nil)
    }

    @Test("Unknown GLP-1 brand: surfaces the catalog-miss empty state")
    func unknownGLP1ShowsCatalogMissState() {
        let store = makeStore(name: "Mysterio GLP-X", treatmentClass: "GLP1")
        #expect(store.isGLP1Recognised == false)
        #expect(store.isUnknownGLP1Brand == true)
    }

    @Test("Recognised brand: chart-section is eligible + drug resolved")
    func recognisedBrandResolvesAndShowsChart() {
        let store = makeStore(name: "Trulicity 7.5 mg", treatmentClass: "GLP1")
        #expect(store.isGLP1Recognised == true)
        #expect(store.isUnknownGLP1Brand == false)
        #expect(store.drug?.id == .tirzepatide)
    }

    // MARK: - PK input pipeline

    @Test("pkDoseEvents skips skipped intakes")
    func pkDosesSkipSkipped() {
        let store = makeStore(name: "Ozempic 1 mg", treatmentClass: "GLP1")
        let baseline = Date(timeIntervalSince1970: 1_000_000_000)
        store._testInject(intakes: [
            PaginatedIntakeEvent(
                id: "ev_1",
                takenAt: baseline,
                skipped: false,
                scheduledFor: baseline
            ),
            PaginatedIntakeEvent(
                id: "ev_2",
                takenAt: nil,
                skipped: true,
                scheduledFor: baseline.addingTimeInterval(-7 * 24 * 3600)
            ),
            PaginatedIntakeEvent(
                id: "ev_3",
                takenAt: nil,
                skipped: false,
                scheduledFor: baseline.addingTimeInterval(-14 * 24 * 3600)
            )
        ])
        let doses = store.pkDoseEvents()
        #expect(doses.count == 1)
        #expect(doses.first?.takenAt == baseline)
    }

    @Test("pkDoseEvents falls back to headline dose when no dose-change history")
    func pkDosesUseHeadlineFallback() {
        let store = makeStore(name: "Trulicity 7.5 mg", treatmentClass: "GLP1")
        let baseline = Date(timeIntervalSince1970: 1_000_000_000)
        store._testInject(intakes: [
            PaginatedIntakeEvent(
                id: "ev_1",
                takenAt: baseline,
                skipped: false,
                scheduledFor: baseline
            )
        ])
        let doses = store.pkDoseEvents()
        #expect(doses.count == 1)
        #expect(doses.first?.doseMg == 7.5)
    }

    @Test("pkDoseEvents prefers dose-change history over headline dose")
    func pkDosesPreferDoseChangeHistory() {
        let store = makeStore(name: "Trulicity 7.5 mg", treatmentClass: "GLP1")
        let baseline = Date(timeIntervalSince1970: 1_000_000_000)
        let priorDose = baseline.addingTimeInterval(-30 * 24 * 3600)
        // Dose-change: started at 5 mg 30d ago, escalated to 7.5 mg 14d ago.
        let history = [
            Glp1DoseChangeDTO(
                id: "dc_1",
                effectiveFrom: priorDose,
                doseValue: 5.0,
                doseUnit: "mg",
                note: nil
            ),
            Glp1DoseChangeDTO(
                id: "dc_2",
                effectiveFrom: baseline.addingTimeInterval(-14 * 24 * 3600),
                doseValue: 7.5,
                doseUnit: "mg",
                note: nil
            )
        ]
        let details = Glp1DetailsDTO(
            doseChanges: history,
            recentIntakes: [],
            inventory: nil
        )
        store._testInject(
            intakes: [
                // Older intake — falls under the 5 mg dose-change.
                PaginatedIntakeEvent(
                    id: "old",
                    takenAt: baseline.addingTimeInterval(-21 * 24 * 3600),
                    skipped: false,
                    scheduledFor: baseline.addingTimeInterval(-21 * 24 * 3600)
                ),
                // Recent intake — falls under the 7.5 mg dose-change.
                PaginatedIntakeEvent(
                    id: "recent",
                    takenAt: baseline,
                    skipped: false,
                    scheduledFor: baseline
                )
            ],
            details: details
        )
        let doses = store.pkDoseEvents()
        #expect(doses.count == 2)
        // Recent intake gets the 7.5 mg dose; older one gets 5 mg.
        let byTime = doses.sorted { $0.takenAt < $1.takenAt }
        #expect(byTime[0].doseMg == 5.0)
        #expect(byTime[1].doseMg == 7.5)
    }

    @Test("pkDoseEvents falls through non-mg dose-change to older mg change (QC-4)")
    func pkDosesFallThroughNonMgChange() {
        let store = makeStore(name: "Trulicity 7.5 mg", treatmentClass: "GLP1")
        let baseline = Date(timeIntervalSince1970: 1_000_000_000)
        // Hypothetical edge case: an older "5 mg" change followed by a more
        // recent "0.5 µg" (non-mg) row. The bug had us return nil on the µg
        // hit and abort, masking the older valid mg change. Post-fix the
        // non-mg row is skipped and the search continues backward.
        let history = [
            Glp1DoseChangeDTO(
                id: "dc_old_mg",
                effectiveFrom: baseline.addingTimeInterval(-30 * 24 * 3600),
                doseValue: 5.0,
                doseUnit: "mg",
                note: nil
            ),
            Glp1DoseChangeDTO(
                id: "dc_new_ug",
                effectiveFrom: baseline.addingTimeInterval(-7 * 24 * 3600),
                doseValue: 500,
                doseUnit: "µg",
                note: nil
            )
        ]
        let details = Glp1DetailsDTO(
            doseChanges: history,
            recentIntakes: [],
            inventory: nil
        )
        store._testInject(
            intakes: [
                PaginatedIntakeEvent(
                    id: "after_ug",
                    takenAt: baseline,
                    skipped: false,
                    scheduledFor: baseline
                )
            ],
            details: details
        )
        let doses = store.pkDoseEvents()
        // Post-fix: the µg row is skipped, the search continues to the older
        // mg row → 5 mg lands as the resolved dose.
        #expect(doses.count == 1)
        #expect(doses.first?.doseMg == 5.0, "Non-mg recent change must not mask the older mg change")
    }

    @Test("pkDoseEvents falls back to headline dose when ALL history is non-mg (QC-4)")
    func pkDosesAllNonMgUsesHeadline() {
        let store = makeStore(name: "Trulicity 7.5 mg", treatmentClass: "GLP1")
        let baseline = Date(timeIntervalSince1970: 1_000_000_000)
        // Every row in history is non-mg → doseAt returns nil → pkDoseEvents
        // falls back to the headline dose (7.5 mg from the medication name).
        let history = [
            Glp1DoseChangeDTO(
                id: "dc_ug",
                effectiveFrom: baseline.addingTimeInterval(-14 * 24 * 3600),
                doseValue: 500,
                doseUnit: "µg",
                note: nil
            )
        ]
        let details = Glp1DetailsDTO(
            doseChanges: history,
            recentIntakes: [],
            inventory: nil
        )
        store._testInject(
            intakes: [
                PaginatedIntakeEvent(
                    id: "post",
                    takenAt: baseline,
                    skipped: false,
                    scheduledFor: baseline
                )
            ],
            details: details
        )
        let doses = store.pkDoseEvents()
        #expect(doses.count == 1)
        #expect(doses.first?.doseMg == 7.5, "All-non-mg history must fall back to headline dose")
    }

    // MARK: - Helpers

    private func makeStore(name: String, treatmentClass: String?) -> MedicationDetailStore {
        let med = Medication(
            id: "med_test",
            name: name,
            dose: "7.5 mg",
            treatmentClass: treatmentClass,
            schedule: MedicationSchedule(times: [], weekdays: nil)
        )
        let stub = ScreenStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: stub, outbox: outbox)
        return MedicationDetailStore(medication: med, repo: repo)
    }
}

private final class ScreenStubAPIClient: APIClientProtocol, @unchecked Sendable {
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
