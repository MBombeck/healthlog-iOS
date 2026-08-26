import Foundation
@testable import HealthLog
import Testing

/// T-3 commit 5 — covers the empty-vs-skeleton vs. content branches the
/// `MedicationsScreen` uses to pick which top-level view to render.
/// The view itself can't be instantiated headless (NavigationStack +
/// scenePhase), so we exercise the underlying store state-machine and
/// the boolean predicates the screen consumes.
@MainActor
@Suite("MedicationsScreen — empty / skeleton state predicates")
struct MedicationsScreenEmptyStateTests {
    @Test("Fresh store with no rows + isLoading=false → empty state")
    func freshEmptyStoreShowsEmptyState() throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // No load() yet — store is empty + not loading.
        #expect(store.medications.isEmpty)
        #expect(store.todayIntakes.isEmpty)
        #expect(!store.isLoading)
        #expect(store.error == nil)

        // The screen's `hasNoContent` predicate mirrors:
        // !isLoading && medications.isEmpty && todayIntakes.isEmpty && error == nil
        let hasNoContent = !store.isLoading
            && store.medications.isEmpty
            && store.todayIntakes.isEmpty
            && store.error == nil
        #expect(hasNoContent, "Fresh store should drive the empty state")
    }

    @Test("After a successful load with rows → neither skeleton nor empty")
    func loadedWithRowsShowsContent() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { request in
            switch request {
            case is APIRequest<[MedicationWireDTO]>:
                return [MedicationWireDTO(id: "srv-1", name: "Ozempic", dose: "1.0 mg")]
            case is APIRequest<[MedicationIntake]>:
                return [MedicationIntake]()
            case is APIRequest<[ComplianceDay]>:
                return [ComplianceDay]()
            default:
                throw HLError.unknown("unexpected request")
            }
        }
        await store.load()

        #expect(store.medications.count == 1)
        #expect(!store.isLoading)

        let hasNoContent = !store.isLoading
            && store.medications.isEmpty
            && store.todayIntakes.isEmpty
            && store.error == nil
        let showsSkeleton = store.isLoading && store.medications.isEmpty && store.todayIntakes.isEmpty
        #expect(!hasNoContent)
        #expect(!showsSkeleton)
    }

    @Test("Error state surfaces error, suppresses empty + skeleton")
    func errorStateSuppressesEmpty() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.server(status: 500, code: nil, message: "down") }
        await store.load()

        #expect(store.error != nil)
        let hasNoContent = !store.isLoading
            && store.medications.isEmpty
            && store.todayIntakes.isEmpty
            && store.error == nil
        #expect(!hasNoContent, "Error must not render as 'no medications' — banner should surface instead")
    }

    @Test("Only intakes (no medications) still renders content path")
    func intakesOnlyRendersContent() async throws {
        // Edge: user has scheduled intakes for today but the medication
        // rows haven't loaded yet (rare race). The empty state would
        // wipe the intakes timeline — we don't want that.
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { request in
            switch request {
            case is APIRequest<[MedicationWireDTO]>:
                return [MedicationWireDTO]()
            case is APIRequest<[MedicationIntake]>:
                return [MedicationIntake(
                    id: "i-1",
                    medicationId: "srv-1",
                    scheduledAt: Date(timeIntervalSince1970: 1_714_550_400),
                    status: .pending
                )]
            case is APIRequest<[ComplianceDay]>:
                return [ComplianceDay]()
            default:
                throw HLError.unknown("unexpected request")
            }
        }
        await store.load()

        let hasNoContent = !store.isLoading
            && store.medications.isEmpty
            && store.todayIntakes.isEmpty
            && store.error == nil
        #expect(!hasNoContent, "Intakes alone must keep the content path active")
    }
}
