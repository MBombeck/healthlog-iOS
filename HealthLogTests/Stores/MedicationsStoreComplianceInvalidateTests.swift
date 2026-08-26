import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// Arch-C1 reconcile-coverage:
///
/// `MedicationsStore.create / update / archive` used to invalidate only
/// `.dashboardSummary` + `.healthScore`. The `.medicationsCompliance(days: MedicationsStore.complianceDaysWindow)`
/// key — which drives the meds-compliance ring on the dashboard + the
/// Medikamente-tab heatmap — was left stale. A user-flow like
/// "add a new medication" → "see today's ring drop a slot" never updated
/// the ring until the next 30-minute SWR-TTL refresh.
///
/// Post-reconcile: all three CRUD mutations include
/// `.medicationsCompliance(days: MedicationsStore.complianceDaysWindow)` in their sibling-invalidate list.
@Suite("MedicationsStore — Arch-C1 compliance invalidation on CRUD")
struct MedicationsStoreComplianceInvalidateTests {
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { c in c.yield(online)
                    c.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    @Test("create() invalidates medicationsCompliance(days: complianceDaysWindow) on success")
    @MainActor
    func createInvalidatesCompliance() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // Pre-seed compliance so we can prove the invalidate hit it.
        try await cache.write(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            payload: JSONEncoder.hlDefault.encode([ComplianceDay]())
        )

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo, swr: coordinator)

        await api.setHandler { _ in medT3Wire(id: "srv-1", name: "Ozempic", dose: "1.0 mg") }
        let outcome = await store.create(.init(name: "Ozempic", dose: "1.0 mg"))

        #expect(outcome == .success)
        let after: Cached<[ComplianceDay]>? = await cache.read(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            as: [ComplianceDay].self
        )
        #expect(after == nil, "create() must invalidate .medicationsCompliance(days: MedicationsStore.complianceDaysWindow)")
    }

    @Test("update() invalidates medicationsCompliance(days: complianceDaysWindow) on success")
    @MainActor
    func updateInvalidatesCompliance() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        try await cache.write(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            payload: JSONEncoder.hlDefault.encode([ComplianceDay]())
        )

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo, swr: coordinator)
        store._test_seed(complianceFixture: [
            medT3Domain(id: "srv-1", name: "Ozempic", dose: "1.0 mg")
        ])

        await api.setHandler { _ in medT3Wire(id: "srv-1", name: "Ozempic", dose: "2.0 mg") }
        let outcome = await store.update(id: "srv-1", patch: .init(dose: "2.0 mg"))

        #expect(outcome == .success)
        let after: Cached<[ComplianceDay]>? = await cache.read(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            as: [ComplianceDay].self
        )
        #expect(after == nil, "update() must invalidate .medicationsCompliance(days: MedicationsStore.complianceDaysWindow)")
    }

    @Test("archive() invalidates medicationsCompliance(days: complianceDaysWindow) on success")
    @MainActor
    func archiveInvalidatesCompliance() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        try await cache.write(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            payload: JSONEncoder.hlDefault.encode([ComplianceDay]())
        )

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo, swr: coordinator)
        store._test_seed(complianceFixture: [
            medT3Domain(id: "srv-1", name: "Ozempic", dose: "1.0 mg")
        ])

        await api.setHandler { _ in EmptyResponse() }
        let outcome = await store.archive(id: "srv-1")

        #expect(outcome == .success)
        let after: Cached<[ComplianceDay]>? = await cache.read(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            as: [ComplianceDay].self
        )
        #expect(after == nil, "archive() must invalidate .medicationsCompliance(days: MedicationsStore.complianceDaysWindow)")
    }
}

private extension MedicationsStore {
    // swiftlint:disable:next identifier_name
    func _test_seed(complianceFixture rows: [Medication]) {
        _testForceSet(medications: rows)
    }
}

// swiftlint:enable force_unwrapping
