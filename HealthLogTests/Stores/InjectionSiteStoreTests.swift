import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

@Suite("Injection-site store")
@MainActor
struct InjectionSiteStoreTests {
    private func makeRepo() throws -> GLP1LocalRepository {
        let container = try GLP1LocalStore.makeInMemory()
        return GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
    }

    private let medID = "med-Z"

    @Test("Empty load yields empty state")
    func emptyLoad() async throws {
        let repo = try makeRepo()
        let store = InjectionSiteStore(medicationID: medID, repo: repo)
        await store.load(serverIntakes: [])
        #expect(store.mergedHistory.isEmpty)
        #expect(store.lastUsedSite == nil)
        #expect(store.suggestedNextSite == nil)
    }

    @Test("Log appends newest-first to merged history")
    func logAppends() async throws {
        let repo = try makeRepo()
        let store = InjectionSiteStore(medicationID: medID, repo: repo)
        await store.load(serverIntakes: [])
        await store.log(
            site: .abdomenLeftUpper,
            injectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await store.log(
            site: .thighRight,
            injectedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(store.mergedHistory.count == 2)
        #expect(store.mergedHistory[0].site == .thighRight)
        #expect(store.mergedHistory[1].site == .abdomenLeftUpper)
        #expect(store.lastUsedSite == .thighRight)
    }

    @Test("Server intakes merge into history when injectionSite parses")
    func serverIntakeMerge() async throws {
        let repo = try makeRepo()
        let store = InjectionSiteStore(medicationID: medID, repo: repo)
        let intakes = [
            PaginatedIntakeEvent(
                id: "i1",
                takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                skipped: false,
                scheduledFor: Date(timeIntervalSince1970: 1_700_000_000),
                injectionSite: "abdomen_left_upper"
            ),
            // Unparseable site → skipped
            PaginatedIntakeEvent(
                id: "i2",
                takenAt: Date(timeIntervalSince1970: 1_750_000_000),
                skipped: false,
                scheduledFor: Date(timeIntervalSince1970: 1_750_000_000),
                injectionSite: "garbage_site"
            ),
            // No site at all → skipped
            PaginatedIntakeEvent(
                id: "i3",
                takenAt: Date(timeIntervalSince1970: 1_780_000_000),
                skipped: false,
                scheduledFor: Date(timeIntervalSince1970: 1_780_000_000),
                injectionSite: nil
            )
        ]
        await store.load(serverIntakes: intakes)
        #expect(store.mergedHistory.count == 1)
        #expect(store.mergedHistory[0].source == .server)
        #expect(store.mergedHistory[0].site == .abdomenLeftUpper)
    }

    @Test("Suggested next site avoids most-recent injection")
    func suggestedAvoidsRecent() async throws {
        let repo = try makeRepo()
        let store = InjectionSiteStore(medicationID: medID, repo: repo)
        await store.load(serverIntakes: [])
        await store.log(site: .abdomenLeftUpper)
        #expect(store.suggestedNextSite != .abdomenLeftUpper)
    }

    @Test("Mixed local + server history limit-capped")
    func historyLimit() async throws {
        let repo = try makeRepo()
        let store = InjectionSiteStore(medicationID: medID, repo: repo, historyLimit: 3)
        // 2 local
        for offset in 0 ..< 2 {
            await store.log(
                site: .thighLeft,
                injectedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + offset * 100))
            )
        }
        // 2 server
        var intakes: [PaginatedIntakeEvent] = []
        for idx in 0 ..< 2 {
            let timestamp = Date(timeIntervalSince1970: Double(1_750_000_000 + idx * 100))
            intakes.append(PaginatedIntakeEvent(
                id: "srv-\(idx)",
                takenAt: timestamp,
                skipped: false,
                scheduledFor: timestamp,
                injectionSite: "abdomen_left_upper"
            ))
        }
        await store.load(serverIntakes: intakes)
        #expect(store.mergedHistory.count == 3)
    }

    @Test("Delete removes local-source row, server rows untouched")
    func deleteRemovesLocalOnly() async throws {
        let repo = try makeRepo()
        let store = InjectionSiteStore(medicationID: medID, repo: repo)
        let intakes = [
            PaginatedIntakeEvent(
                id: "srv1",
                takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                skipped: false,
                scheduledFor: Date(timeIntervalSince1970: 1_700_000_000),
                injectionSite: "abdomen_left_upper"
            )
        ]
        await store.log(
            site: .thighRight,
            injectedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await store.load(serverIntakes: intakes)
        let localID = try #require(
            store.mergedHistory.first { $0.source == .local }?.id
        )
        await store.delete(id: localID)
        #expect(store.mergedHistory.count == 1)
        #expect(store.mergedHistory.first?.source == .server)
    }
}
