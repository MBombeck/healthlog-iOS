import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// State-level coverage for `TitrationLadderStore` — merge semantics
/// between server `doseChanges` and local `TitrationStepEntry` rows, plus
/// the catalog-driven "next standard step" suggestion.
@Suite("Titration ladder store")
@MainActor
struct TitrationLadderStoreTests {
    private func makeRepo() throws -> GLP1LocalRepository {
        let container = try GLP1LocalStore.makeInMemory()
        return GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
    }

    private let medID = "med-1"

    @Test("Empty load yields empty timeline")
    func emptyTimeline() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        await store.load(serverChanges: [])
        #expect(store.mergedTimeline.isEmpty)
        #expect(store.currentStep == nil)
        #expect(store.nextStandardStepMg == nil)
    }

    @Test("Server-only changes surface in ascending order")
    func serverOnly() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        let changes = [
            Glp1DoseChangeDTO(
                id: "srv2",
                effectiveFrom: Date(timeIntervalSince1970: 1_800_000_000),
                doseValue: 7.5,
                doseUnit: "mg",
                note: nil
            ),
            Glp1DoseChangeDTO(
                id: "srv1",
                effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
                doseValue: 5.0,
                doseUnit: "mg",
                note: nil
            )
        ]
        await store.load(serverChanges: changes)
        let timeline = store.mergedTimeline
        #expect(timeline.count == 2)
        #expect(timeline[0].doseMg == 5.0)
        #expect(timeline[1].doseMg == 7.5)
        #expect(timeline.allSatisfy { $0.source == .server })
        #expect(store.currentStep?.doseMg == 7.5)
    }

    @Test("Local-only entries surface in timeline")
    func localOnly() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        await store.add(
            effectiveFrom: Date(timeIntervalSince1970: 1_800_000_000),
            doseMg: 2.5,
            note: "first"
        )
        await store.load(serverChanges: [])
        let timeline = store.mergedTimeline
        #expect(timeline.count == 1)
        #expect(timeline[0].doseMg == 2.5)
        #expect(timeline[0].source == .local)
    }

    @Test("Same-day overlap prefers local row")
    func localBeatsServerOnSameDay() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let serverChange = Glp1DoseChangeDTO(
            id: "srv1",
            effectiveFrom: day,
            doseValue: 5.0,
            doseUnit: "mg",
            note: "from server"
        )
        await store.add(effectiveFrom: day, doseMg: 7.5, note: "local override")
        await store.load(serverChanges: [serverChange])
        let timeline = store.mergedTimeline
        #expect(timeline.count == 1)
        #expect(timeline[0].source == .local)
        #expect(timeline[0].doseMg == 7.5)
    }

    @Test("Different-day server + local both surface")
    func differentDaysBothSurface() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        await store.add(
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            doseMg: 2.5,
            note: nil
        )
        let serverChange = Glp1DoseChangeDTO(
            id: "srv1",
            effectiveFrom: Date(timeIntervalSince1970: 1_900_000_000),
            doseValue: 7.5,
            doseUnit: "mg",
            note: nil
        )
        await store.load(serverChanges: [serverChange])
        let timeline = store.mergedTimeline
        #expect(timeline.count == 2)
        #expect(timeline[0].doseMg == 2.5)
        #expect(timeline[0].source == .local)
        #expect(timeline[1].doseMg == 7.5)
        #expect(timeline[1].source == .server)
    }

    @Test("Next standard step from catalog above current dose")
    func nextStandardStep() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: GLP1DrugCatalog.drug(for: .tirzepatide),
            repo: repo
        )
        await store.add(effectiveFrom: .now, doseMg: 5.0, note: nil)
        await store.load(serverChanges: [])
        // Tirzepatide ladder: 2.5, 5, 7.5, 10, 12.5, 15. Current = 5.
        #expect(store.nextStandardStepMg == 7.5)
    }

    @Test("Next standard step nil at or above catalog max")
    func nextStandardStepAtMax() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: GLP1DrugCatalog.drug(for: .tirzepatide),
            repo: repo
        )
        // 15 mg is the max for Tirzepatide.
        await store.add(effectiveFrom: .now, doseMg: 15.0, note: nil)
        await store.load(serverChanges: [])
        #expect(store.nextStandardStepMg == nil)
    }

    @Test("Next standard step nil when catalog absent")
    func nextStandardStepNoCatalog() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        await store.add(effectiveFrom: .now, doseMg: 1.0, note: nil)
        await store.load(serverChanges: [])
        #expect(store.nextStandardStepMg == nil)
    }

    @Test("Update mutates dose and note")
    func updateMutation() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        await store.add(
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            doseMg: 5.0,
            note: "initial"
        )
        await store.load(serverChanges: [])
        let id = try #require(store.mergedTimeline.first?.id)
        await store.update(
            id: id,
            effectiveFrom: Date(timeIntervalSince1970: 1_800_000_000),
            doseMg: 7.5,
            note: "moved"
        )
        let timeline = store.mergedTimeline
        #expect(timeline.count == 1)
        #expect(timeline[0].doseMg == 7.5)
        #expect(timeline[0].note == "moved")
    }

    @Test("Delete removes a local row")
    func deleteRemoves() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: nil,
            repo: repo
        )
        await store.add(effectiveFrom: .now, doseMg: 2.5, note: nil)
        await store.load(serverChanges: [])
        let id = try #require(store.mergedTimeline.first?.id)
        await store.delete(id: id)
        #expect(store.mergedTimeline.isEmpty)
    }

    @Test("Semaglutide catalog step progression")
    func semaglutideProgression() async throws {
        let repo = try makeRepo()
        let store = TitrationLadderStore(
            medicationID: medID,
            catalogDrug: GLP1DrugCatalog.drug(for: .semaglutide),
            repo: repo
        )
        // Semaglutide ladder: 0.25, 0.5, 1, 2.
        await store.add(effectiveFrom: .now, doseMg: 0.5, note: nil)
        await store.load(serverChanges: [])
        #expect(store.nextStandardStepMg == 1.0)
    }
}
