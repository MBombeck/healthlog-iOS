import Foundation
@testable import HealthLog
import Synchronization
import Testing

// #191 (21:04 UTC, final): steps deleted by clientId, the intake form's slots
// from the day's ledger, and the current dose from complianceDisplay.

/// Records every request with its query; answers by method.
private final class QueryAPI: APIClientProtocol, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let query: [String: String]
    }

    private let lock = Mutex<[Call]>([])
    private let answer: @Sendable (Call) -> String

    init(_ answer: @escaping @Sendable (Call) -> String) {
        self.answer = answer
    }

    var calls: [Call] {
        lock.withLock { $0 }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let call = Call(
            method: request.method.rawValue,
            path: request.path,
            query: Dictionary(request.query, uniquingKeysWith: { $1 })
        )
        lock.withLock { $0.append(call) }
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(answer(call).utf8))
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = try await send(request)
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("not stubbed")
    }
}

@Suite("#191 — a titration step is deleted by its clientId")
@MainActor
struct Glp1DeleteByClientIdTests {
    @Test("the query form of the DELETE carries the clientId")
    func requestShape() async throws {
        let api = QueryAPI { _ in "{}" }
        try await Glp1DoseChangeRepository(api: api).delete(medicationID: "med-1", clientId: "local-7")
        let call = try #require(api.calls.first)
        #expect(call.method == "DELETE")
        #expect(call.path == "/api/medications/med-1/glp1/dose-changes")
        #expect(call.query == ["clientId": "local-7"])
    }

    @Test("deleting a step that waits for its upload spends its clientId on the server")
    func deleteWaitingStep() async throws {
        // Offline for the create: the step stays unmarked, then is deleted.
        let api = QueryAPI { call in call.method == "POST" ? "not json" : "{}" }
        let local = try GLP1LocalRepository(
            store: GLP1LocalStore(modelContainer: GLP1LocalStore.makeInMemory()),
            doseChangeServer: Glp1DoseChangeRepository(api: api)
        )
        let step = try await local.addTitrationStep(medicationID: "med-1", effectiveFrom: .now, doseMg: 2.5, note: nil)
        let store = TitrationLadderStore(medicationID: "med-1", catalogDrug: nil, repo: local)
        await store.load(serverChanges: [])
        await store.settleUpload()
        #expect(await store.delete(id: step.id))
        let deletes = api.calls.filter { $0.method == "DELETE" }
        #expect(deletes.map(\.query) == [["clientId": step.id]])
        #expect(try await local.titrationSteps(medicationID: "med-1").isEmpty)
    }
}

@Suite("#191 — the intake form offers the slots the server lists for the day")
struct IntakeDaySlotTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(
        _ kind: String,
        _ offset: TimeInterval,
        _ time: String?,
        state: String?,
        status: String = "upcoming"
    ) -> MedicationDoseHistoryRow {
        MedicationDoseHistoryRow(
            kind: kind,
            at: base.addingTimeInterval(offset),
            timeOfDay: time,
            statusRaw: status,
            stateRaw: state
        )
    }

    @Test("only open slot rows: not taken, not skipped, not ad hoc")
    func openSlots() {
        let rows = [
            row("slot", 0, "08:00", state: "due"),
            row("slot", 3600 * 12, "20:00", state: "upcoming"),
            row("slot", -3600, "07:00", state: "taken", status: "taken_on_time"),
            row("slot", -7200, "06:00", state: "skipped", status: "skipped"),
            row("ad_hoc", 600, nil, state: nil, status: "ad_hoc")
        ]
        let slots = IntakeSlotAttribution.openDaySlots(rows)
        #expect(slots.map(\.instant) == [base, base.addingTimeInterval(3600 * 12)])
        #expect(slots.first?.time == TimeOfDay(hour: 8, minute: 0))
    }

    @Test("update path: an older ledger without state reads its status")
    func olderLedger() {
        let rows = [row("slot", 0, "08:00", state: nil, status: "taken_late"), row("slot", 60, "08:01", state: nil, status: "missed")]
        #expect(IntakeSlotAttribution.openDaySlots(rows).count == 1)
    }

    @Test("a late take counts for the server's slot instant; an off day (no rows) is an extra dose")
    func attribution() {
        let slot = IntakeSlotAttribution.DaySlot(instant: base, time: TimeOfDay(hour: 8, minute: 0))
        let late = IntakeSlotAttribution.resolve(
            takenAt: base.addingTimeInterval(2 * 3600),
            daySlots: [slot],
            skipped: false,
            countNear: true
        )
        #expect(late.forceSlotInstant == base)
        let exact = IntakeSlotAttribution.resolve(takenAt: base.addingTimeInterval(600), daySlots: [slot], skipped: false, countNear: true)
        #expect(exact.scheduledFor == base)
        let offDay = IntakeSlotAttribution.resolve(takenAt: base, daySlots: [], skipped: false, countNear: true)
        #expect(offDay == .extra(nearSlot: nil))
        #expect(offDay.forceSlotInstant == nil)
        #expect(IntakeSlotAttribution.resolve(takenAt: base, daySlots: [], skipped: true, countNear: true) == .noSlot)
    }

    @Test("422 force_slot.invalid gets its own sentence")
    func invalidSlot() {
        let refusal = HLError.server(status: 422, code: IntakeWriteRefusal.forceSlotInvalidCode, message: "raw")
        guard case let .server(_, _, message) = IntakeWriteRefusal.explained(refusal) else {
            Issue.record("shape")
            return
        }
        #expect(message != "raw")
        guard case let .server(_, _, occupied) = IntakeWriteRefusal.explained(
            .server(status: 422, code: IntakeWriteRefusal.forceSlotOccupiedCode, message: "raw")
        ) else { return }
        #expect(occupied != message)
    }
}

@Suite("#191 — the detail page acts on the server's current dose")
struct DetailCurrentDoseTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private var rows: [MedicationIntake] {
        [
            MedicationIntake(id: "a", medicationId: "m", scheduledAt: base, status: .pending),
            MedicationIntake(id: "b", medicationId: "m", scheduledAt: base.addingTimeInterval(3600 * 12), status: .pending)
        ]
    }

    private func display(_ target: Date?) -> ComplianceDisplay {
        ComplianceDisplay(
            shortDays: 7, longDays: 30,
            short: ComplianceDisplayWindow(rate: 90), long: ComplianceDisplayWindow(rate: 90),
            currentDose: ComplianceCurrentDose(targetAt: target)
        )
    }

    @Test("targetAt picks the row; null means no current dose; without the key the old rule")
    func currentDose() {
        let later = base.addingTimeInterval(3600 * 12)
        let now = base.addingTimeInterval(3600 * 13)
        #expect(MedicationDetailDoseActions.currentOpenDose(
            medicationId: "m", todayIntakes: rows, complianceDisplay: display(base), now: now, serverNamesDose: true
        )?.id == "a")
        #expect(MedicationDetailDoseActions.currentOpenDose(
            medicationId: "m", todayIntakes: rows, complianceDisplay: display(nil), now: now, serverNamesDose: true
        ) == nil)
        #expect(MedicationDetailDoseActions.currentOpenDose(
            medicationId: "m", todayIntakes: rows, complianceDisplay: display(base), now: now, serverNamesDose: false
        )?.id == "b", "the latest due one, as before")
        #expect(later > base)
    }
}
