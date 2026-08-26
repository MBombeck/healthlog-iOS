import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-REMINDERS (#23 v1.18.1) — pins the `MeasurementRemindersStore` mutation
/// reconciliation, and (08-22) the optimistic `delete` rollback that is still
/// the one optimistic path here. Uses the shared `StubAPIClient` (defined in
/// `MeasurementsStoreTests.swift`) with `swr: nil` so the store loads directly
/// (no cache) and the reconciliation is observable.
@MainActor
@Suite("MeasurementRemindersStore")
struct MeasurementRemindersStoreTests {
    private nonisolated static func row(id: String, satisfied: Bool = false) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: id,
            label: "Reminder \(id)",
            measurementType: "WEIGHT",
            intervalDays: 30,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: nil,
            nextDueAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSatisfiedAt: satisfied ? .now : nil,
            enabled: true
        )
    }

    @Test("load populates reminders from the repo list")
    func loadList() async {
        let api = StubAPIClient()
        let rows = [Self.row(id: "r1"), Self.row(id: "r2")]
        await api.setHandler { _ in rows }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))

        await store.load()

        #expect(store.reminders.map(\.id) == ["r1", "r2"])
        #expect(store.error == nil)
    }

    @Test("satisfy success reconciles with the server re-anchored row")
    func satisfySuccess() async {
        let api = StubAPIClient()
        let satisfiedRow = Self.row(id: "r1", satisfied: true)
        await api.setHandler { req in
            // The list load returns the un-satisfied row; the satisfy POST
            // returns the re-anchored row. Branch on the request type.
            if req is APIRequest<[MeasurementReminderRow]> {
                return [Self.row(id: "r1")]
            }
            return satisfiedRow
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        #expect(store.reminders.first?.lastSatisfiedAt == nil)

        let ok = await store.satisfy(id: "r1")

        #expect(ok)
        #expect(store.reminders.first?.lastSatisfiedAt != nil)
        #expect(store.error == nil)
    }

    @Test("satisfy failure rolls back to the pre-mutation snapshot")
    func satisfyRollback() async {
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<[MeasurementReminderRow]> {
                return [Self.row(id: "r1")]
            }
            throw HLError.server(status: 500, code: nil, message: "boom")
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        let before = store.reminders

        let ok = await store.satisfy(id: "r1")

        #expect(!ok)
        // 08-22: there is no stamp to roll back any more — the row was never
        // touched, so it is still exactly what the last list said. The assertion
        // is unchanged; only this note is.
        #expect(store.reminders == before)
        #expect(store.reminders.first?.lastSatisfiedAt == nil)
        #expect(store.error != nil)
    }

    @Test("update success reloads with the server-recomputed row")
    func updateSuccess() async {
        let api = StubAPIClient()
        // First load: label "Reminder r1". After PATCH the list reload returns
        // the renamed + re-anchored row (server recomputes nextDueAt).
        let renamed = MeasurementReminderRow(
            id: "r1",
            label: "Yearly checkup",
            measurementType: "WEIGHT",
            intervalDays: 365,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 8,
            location: nil,
            nextDueAt: Date(timeIntervalSince1970: 1_900_000_000),
            lastSatisfiedAt: nil,
            enabled: true
        )
        let didPatch = PatchFlag()
        await api.setHandler { req in
            if req is APIRequest<[MeasurementReminderRow]> {
                return didPatch.fired ? [renamed] : [Self.row(id: "r1")]
            }
            // The PATCH itself returns the updated row.
            didPatch.fired = true
            return renamed
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        #expect(store.reminders.first?.label == "Reminder r1")

        let ok = await store.update(
            id: "r1",
            patch: MeasurementReminderUpdate(label: "Yearly checkup", intervalDays: .set(365), notifyHour: 8)
        )

        #expect(ok)
        #expect(store.reminders.first?.label == "Yearly checkup")
        #expect(store.reminders.first?.intervalDays == 365)
        #expect(store.error == nil)
    }

    @Test("update failure surfaces an error and keeps the prior row")
    func updateFailure() async {
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<[MeasurementReminderRow]> {
                return [Self.row(id: "r1")]
            }
            throw HLError.server(status: 422, code: nil, message: "invalid")
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        let ok = await store.update(id: "r1", patch: MeasurementReminderUpdate(label: "x"))

        #expect(!ok)
        #expect(store.reminders.first?.label == "Reminder r1")
        #expect(store.error != nil)
    }

    @Test("delete success removes the row")
    func deleteSuccess() async {
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<[MeasurementReminderRow]> {
                return [Self.row(id: "r1"), Self.row(id: "r2")]
            }
            return EmptyResponse() // delete decodes the canonical empty 2xx body
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        let ok = await store.delete(id: "r1")

        #expect(ok)
        #expect(store.reminders.map(\.id) == ["r2"])
    }

    @Test("delete failure restores the removed row")
    func deleteRollback() async {
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<[MeasurementReminderRow]> {
                return [Self.row(id: "r1"), Self.row(id: "r2")]
            }
            throw HLError.server(status: 500, code: nil, message: "boom")
        }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()

        let ok = await store.delete(id: "r1")

        #expect(!ok)
        #expect(store.reminders.map(\.id) == ["r1", "r2"]) // restored
        #expect(store.error != nil)
    }

    /// Tiny mutable flag for the stub handler to distinguish the pre- vs
    /// post-PATCH list reload. The handler closure runs on the API actor; the
    /// flag is only flipped/read inside it, so the unchecked annotation is safe.
    private final class PatchFlag: @unchecked Sendable {
        var fired = false
    }
}
