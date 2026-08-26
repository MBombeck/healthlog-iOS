import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// State-level coverage for `PenInventoryStore`.
@Suite("Pen inventory store")
@MainActor
struct PenInventoryStoreTests {
    private func makeRepo() throws -> GLP1LocalRepository {
        let container = try GLP1LocalStore.makeInMemory()
        return GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
    }

    private let medID = "med-Y"

    @Test("Empty load yields empty state")
    func emptyLoad() async throws {
        let repo = try makeRepo()
        let store = PenInventoryStore(medicationID: medID, repo: repo)
        await store.load()
        #expect(store.pens.isEmpty)
        #expect(store.activePen == nil)
        #expect(store.unopenedCount == 0)
        #expect(store.finishedPens.isEmpty)
    }

    @Test("Add appends newest-dispensed-first")
    func addAppends() async throws {
        let repo = try makeRepo()
        let store = PenInventoryStore(medicationID: medID, repo: repo)
        await store.add(
            manufacturer: "Old",
            doseStrength: "1 mg",
            dispensedAt: Date(timeIntervalSince1970: 1_700_000_000),
            firstUsedAt: nil,
            notes: nil
        )
        await store.add(
            manufacturer: "New",
            doseStrength: "1 mg",
            dispensedAt: Date(timeIntervalSince1970: 1_800_000_000),
            firstUsedAt: nil,
            notes: nil
        )
        #expect(store.pens.count == 2)
        #expect(store.pens[0].manufacturer == "New")
        #expect(store.pens[1].manufacturer == "Old")
    }

    @Test("activePen surfaces the first started + unfinished row")
    func activePenSurface() async throws {
        let repo = try makeRepo()
        let store = PenInventoryStore(medicationID: medID, repo: repo)
        await store.add(
            manufacturer: "Unopened",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: nil,
            notes: nil
        )
        await store.add(
            manufacturer: "Active",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: .now,
            notes: nil
        )
        #expect(store.activePen?.manufacturer == "Active")
        #expect(store.unopenedCount == 1)
    }

    @Test("markFinished transitions active → finished")
    func markFinished() async throws {
        let repo = try makeRepo()
        let store = PenInventoryStore(medicationID: medID, repo: repo)
        await store.add(
            manufacturer: "Active",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: .now,
            notes: nil
        )
        let id = try #require(store.pens.first?.id)
        await store.markFinished(id: id)
        #expect(store.activePen == nil)
        #expect(store.finishedPens.count == 1)
    }

    @Test("Delete removes row")
    func deleteRow() async throws {
        let repo = try makeRepo()
        let store = PenInventoryStore(medicationID: medID, repo: repo)
        await store.add(
            manufacturer: "X",
            doseStrength: "Y",
            dispensedAt: .now,
            firstUsedAt: nil,
            notes: nil
        )
        let id = try #require(store.pens.first?.id)
        await store.delete(id: id)
        #expect(store.pens.isEmpty)
    }

    @Test("unopenedCount excludes active and finished rows")
    func unopenedCountIsolation() async throws {
        let repo = try makeRepo()
        let store = PenInventoryStore(medicationID: medID, repo: repo)
        // 1 active + 2 unopened + 1 finished
        await store.add(
            manufacturer: "Active",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: .now,
            notes: nil
        )
        for index in 0 ..< 2 {
            await store.add(
                manufacturer: "Stock\(index)",
                doseStrength: "1 mg",
                dispensedAt: .now,
                firstUsedAt: nil,
                notes: nil
            )
        }
        await store.add(
            manufacturer: "Finished",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: .now,
            notes: nil
        )
        let finishedID = try #require(store.pens.first { $0.manufacturer == "Finished" }?.id)
        await store.markFinished(id: finishedID)
        #expect(store.unopenedCount == 2)
        #expect(store.finishedPens.count == 1)
        #expect(store.activePen?.manufacturer == "Active")
    }
}
