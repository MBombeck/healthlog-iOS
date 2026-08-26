import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_try

/// T-4 commit 3 — predicate coverage for the optimistic-patch helpers
/// on `MedicationDetailStore`. The detail screen calls these BEFORE
/// firing the network request (via `MedicationsStore`) so the row
/// reflects the operator intent immediately. On
/// `WriteOutcome.failed` (non-retriable) the parent calls the
/// matching `rollback*` helper to restore the prior state.
@MainActor
@Suite("MedicationDetailStore — T-4 optimistic intake mutate")
struct MedicationDetailStoreOptimisticMutateTests {
    // MARK: - applyOptimisticMark

    @Test("applyOptimisticMark(.taken) sets takenAt = scheduledFor (or clamped now)")
    func optimisticMarkTakenSetsTakenAt() {
        let store = makeStore(with: [
            makeEvent(
                id: "evt-1",
                scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
                takenAt: nil,
                skipped: false
            )
        ])

        let original = store.applyOptimisticMark(
            eventId: "evt-1",
            status: .taken,
            now: Date(timeIntervalSince1970: 1_714_554_000)
        )

        #expect(original != nil)
        #expect(store.intakes.first?.takenAt == Date(timeIntervalSince1970: 1_714_550_400))
        #expect(store.intakes.first?.skipped == false)
    }

    @Test("applyOptimisticMark(.skipped) sets skipped=true and clears takenAt")
    func optimisticMarkSkippedClearsTakenAt() {
        let store = makeStore(with: [
            makeEvent(
                id: "evt-1",
                scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
                takenAt: Date(timeIntervalSince1970: 1_714_550_400),
                skipped: false
            )
        ])

        store.applyOptimisticMark(eventId: "evt-1", status: .skipped)

        #expect(store.intakes.first?.skipped == true)
        #expect(store.intakes.first?.takenAt == nil)
    }

    @Test("applyOptimisticMark returns nil for unknown event id")
    func optimisticMarkReturnsNilWhenMissing() {
        let store = makeStore(with: [])
        let result = store.applyOptimisticMark(eventId: "missing", status: .taken)
        #expect(result == nil)
    }

    @Test("rollbackOptimisticMark restores the prior event payload")
    func rollbackRestoresOriginal() {
        let original = makeEvent(
            id: "evt-1",
            scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
            takenAt: nil,
            skipped: false
        )
        let store = makeStore(with: [original])
        _ = store.applyOptimisticMark(eventId: "evt-1", status: .taken)

        store.rollbackOptimisticMark(eventId: "evt-1", original: original)

        #expect(store.intakes.first?.takenAt == nil)
        #expect(store.intakes.first?.skipped == false)
    }

    @Test("rollbackOptimisticMark re-inserts the row if it was dropped by a refresh")
    func rollbackReinsertsRowIfMissing() {
        let original = makeEvent(
            id: "evt-1",
            scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
            takenAt: nil,
            skipped: false
        )
        let store = makeStore(with: [])
        store.rollbackOptimisticMark(eventId: "evt-1", original: original)
        #expect(store.intakes.count == 1)
        #expect(store.intakes.first?.id == "evt-1")
    }

    // MARK: - applyOptimisticDelete

    @Test("applyOptimisticDelete removes the row + returns its index")
    func optimisticDeleteRemovesRow() {
        let events = [
            makeEvent(id: "evt-1", scheduledFor: Date(timeIntervalSince1970: 1000), takenAt: nil, skipped: false),
            makeEvent(id: "evt-2", scheduledFor: Date(timeIntervalSince1970: 2000), takenAt: nil, skipped: false),
            makeEvent(id: "evt-3", scheduledFor: Date(timeIntervalSince1970: 3000), takenAt: nil, skipped: false)
        ]
        let store = makeStore(with: events)

        let snapshot = store.applyOptimisticDelete(eventId: "evt-2")
        #expect(snapshot != nil)
        #expect(snapshot?.index == 1)
        #expect(snapshot?.event.id == "evt-2")
        #expect(store.intakes.map(\.id) == ["evt-1", "evt-3"])
    }

    @Test("rollbackOptimisticDelete re-inserts at the prior index")
    func rollbackDeleteReinsertsAtIndex() {
        let events = [
            makeEvent(id: "evt-1", scheduledFor: Date(timeIntervalSince1970: 1000), takenAt: nil, skipped: false),
            makeEvent(id: "evt-2", scheduledFor: Date(timeIntervalSince1970: 2000), takenAt: nil, skipped: false),
            makeEvent(id: "evt-3", scheduledFor: Date(timeIntervalSince1970: 3000), takenAt: nil, skipped: false)
        ]
        let store = makeStore(with: events)
        let snapshot = store.applyOptimisticDelete(eventId: "evt-2")
        #expect(snapshot != nil)

        if let snap = snapshot {
            store.rollbackOptimisticDelete(snap.event, at: snap.index)
        }
        #expect(store.intakes.map(\.id) == ["evt-1", "evt-2", "evt-3"])
    }

    @Test("rollbackOptimisticDelete clamps index when array shorter than original")
    func rollbackDeleteClampsIndex() {
        let store = makeStore(with: [])
        let phantom = makeEvent(
            id: "evt-1",
            scheduledFor: Date(timeIntervalSince1970: 1000),
            takenAt: nil,
            skipped: false
        )
        // Index 99 out of range — must not crash, must clamp.
        store.rollbackOptimisticDelete(phantom, at: 99)
        #expect(store.intakes.count == 1)
        #expect(store.intakes.first?.id == "evt-1")
    }

    @Test("applyOptimisticDelete returns nil for unknown id")
    func optimisticDeleteReturnsNilWhenMissing() {
        let store = makeStore(with: [
            makeEvent(id: "evt-1", scheduledFor: Date(timeIntervalSince1970: 1000), takenAt: nil, skipped: false)
        ])
        let snapshot = store.applyOptimisticDelete(eventId: "missing")
        #expect(snapshot == nil)
        #expect(store.intakes.count == 1)
    }

    // MARK: - Helpers

    private func makeStore(with events: [PaginatedIntakeEvent]) -> MedicationDetailStore {
        let med = Medication(
            id: "med-1",
            name: "Test",
            dose: "1 mg",
            schedule: MedicationSchedule(times: [], weekdays: nil)
        )
        let outbox = try! OutboxQueue(inMemory: true)
        let api = OptimisticStubAPIClient()
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationDetailStore(medication: med, repo: repo)
        store._testInject(intakes: events)
        return store
    }

    private func makeEvent(
        id: String,
        scheduledFor: Date,
        takenAt: Date?,
        skipped: Bool
    ) -> PaginatedIntakeEvent {
        PaginatedIntakeEvent(
            id: id,
            takenAt: takenAt,
            skipped: skipped,
            scheduledFor: scheduledFor,
            injectionSite: nil
        )
    }
}

private final class OptimisticStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.unknown("optimistic-mutate tests never network-fetch")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.unknown("optimistic-mutate tests never network-fetch")
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("optimistic-mutate tests never network-fetch")
    }
}

// swiftlint:enable force_try
