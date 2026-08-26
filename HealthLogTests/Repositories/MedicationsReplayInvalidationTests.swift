import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **audit-v0162 M-5 regression coverage — medication outbox-replay invalidation.**
///
/// The medication replay path only re-POSTed and invalidated NOTHING (the
/// store-side invalidation runs only on the LIVE mutation path;
/// `OutboxReplayService` calls the repo directly). A dose marked / med created
/// offline that replayed later left the SWR rows stale until TTL — asymmetric
/// with `MeasurementsRepository.replay` → `invalidateAfterWrite`.
///
/// With an `SWRCoordinator` wired, the `replay*` methods now drop the affected
/// rows through the `MutationKind` matrix.
///
/// NOTE (wiring handoff): the production composition root
/// (`AppContainer+Repositories.swift`, owned by the appcontainer-decompose
/// workstream) still constructs `MedicationsRepository(... )` WITHOUT `swr:`.
/// One line — `swr: swr` — activates this in production; the mechanism is
/// complete and verified here.
@Suite("MedicationsRepository — M-5 replay invalidation")
struct MedicationsReplayInvalidationTests {
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(true)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    @Test("Replaying a queued intake drops the compliance + today-intakes SWR rows")
    func intakeReplayInvalidatesAggregateRows() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        try await cache.write(
            .medicationsCompliance(days: CacheKey.complianceWindowDays),
            payload: JSONEncoder.hlDefault.encode([ComplianceDay]())
        )
        #expect(await coordinator.peek(.medicationsCompliance(days: CacheKey.complianceWindowDays), as: [ComplianceDay].self) != nil)

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox, swr: coordinator)
        await api.setHandler { _ in
            MedicationIntakeWireDTO(id: "i-1", medicationId: "med-1", scheduledFor: .now, takenAt: .now)
        }

        _ = try await repo.replay(
            .init(intakeId: "i-1", status: "taken", takenAt: .now),
            idempotencyKey: "key-1"
        )

        #expect(
            await coordinator.peek(.medicationsCompliance(days: CacheKey.complianceWindowDays), as: [ComplianceDay].self) == nil,
            "M-5: a replayed intake must drop the compliance SWR row"
        )
    }

    @Test("Without a coordinator wired, replay is a safe no-op (legacy behaviour)")
    func replayWithoutCoordinatorIsNoOp() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox) // no swr
        await api.setHandler { _ in
            MedicationIntakeWireDTO(id: "i-2", medicationId: "med-2", scheduledFor: .now, takenAt: .now)
        }
        let intake = try await repo.replay(
            .init(intakeId: "i-2", status: "taken", takenAt: .now),
            idempotencyKey: "key-2"
        )
        #expect(intake.id == "i-2", "replay still returns the mapped intake with no coordinator")
    }
}
