import Foundation
@testable import HealthLog
import Testing

/// **audit-release 05 C-1 — critical-med AlarmKit scheduling failures surface.**
///
/// A critical (life-safety) medication alarm that fails to arm used to be
/// logged + swallowed with NO user signal — the med still presented as
/// alarm-owned while no alarm was set. The store now holds the failed
/// medication ids (`criticalAlarmFailureIDs`) and maps them to display names
/// (`criticalAlarmFailureNames`) so `MedicationsScreen` can render a persistent
/// warning naming exactly which dose alarm is not set.
///
/// The real scheduling path runs through AlarmKit (unavailable in unit tests),
/// so these tests drive the failure set via the DEBUG test seam and assert the
/// store→UI surfacing (the name mapping + the logout clear) behaves.
@MainActor
@Suite("MedicationsStore — C-1 critical-alarm failure surfacing")
struct MedicationsStoreCriticalAlarmFailureTests {
    private func makeStore() throws -> MedicationsStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        return MedicationsStore(repo: repo)
    }

    private func med(_ id: String, _ name: String) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: "1 mg",
            schedule: MedicationSchedule(times: [], weekdays: nil),
            active: true,
            archivedAt: nil
        )
    }

    @Test("no failures → no warning names")
    func emptyByDefault() throws {
        let store = try makeStore()
        #expect(store.criticalAlarmFailureIDs.isEmpty)
        #expect(store.criticalAlarmFailureNames.isEmpty)
    }

    @Test("failed ids resolve to their medication names")
    func failureIDsMapToNames() throws {
        let store = try makeStore()
        store._testForceSet(medications: [
            med("a", "Insulin"),
            med("b", "Warfarin"),
            med("c", "Lisinopril")
        ])
        store._testSetCriticalAlarmFailureIDs(["a", "c"])

        let names = store.criticalAlarmFailureNames
        #expect(Set(names) == ["Insulin", "Lisinopril"])
        #expect(!names.contains("Warfarin"))
    }

    @Test("an id with no matching medication is dropped from the warning")
    func staleIDIsDropped() throws {
        let store = try makeStore()
        store._testForceSet(medications: [med("a", "Insulin")])
        store._testSetCriticalAlarmFailureIDs(["a", "ghost"])

        #expect(store.criticalAlarmFailureNames == ["Insulin"])
    }

    @Test("logout clears the alarm-failure warning")
    func logoutClearsFailures() throws {
        let store = try makeStore()
        store._testForceSet(medications: [med("a", "Insulin")])
        store._testSetCriticalAlarmFailureIDs(["a"])
        #expect(!store.criticalAlarmFailureNames.isEmpty)

        store.clearOnLogout()
        #expect(store.criticalAlarmFailureIDs.isEmpty)
        #expect(store.criticalAlarmFailureNames.isEmpty)
    }
}
