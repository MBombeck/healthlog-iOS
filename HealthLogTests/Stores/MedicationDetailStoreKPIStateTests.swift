import Foundation
@testable import HealthLog
import Testing

/// **#115 · 1.3 — the detail KPI is the server's `compliance30`, verbatim.**
///
/// Until 1.0.3 the KPI tallied "on time" on the client (ledger rows, else the
/// drained intake table with a ±30 min rule) and ranked that above the
/// server's `compliance30`. These tests pin that only the server number
/// paints, that `applicable: false` never paints its zero placeholders, and
/// that a settled load without a server payload reads "unknown" rather than a
/// local estimate. Fixture shapes follow `MedicationComplianceResponse` in
/// `docs/api/openapi.yaml` at `v1.39.0`.
@MainActor
@Suite("MedicationDetailStore — KPI is the server's compliance30 (#115 1.3)")
struct MedicationDetailStoreKPIStateTests {
    private static func payload(
        rate30: Int = 75, taken30: Int = 3, missed30: Int = 1, skipped30: Int = 0,
        applicable: Bool? = true
    ) -> MedicationCompliancePayload {
        MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1),
            compliance30: ComplianceWindowResult(
                totalExpected: taken30 + missed30 + skipped30, taken: taken30, skipped: skipped30,
                missed: missed30, rate: rate30, streak: 0
            ),
            applicable: applicable
        )
    }

    @Test("pre-settle without a payload paints .pending, never a number")
    func pendingBeforeAnyData() {
        let store = makeStore()
        store._testInject(intakes: [], settled: false)
        #expect(store.complianceKPIState() == .pending)
    }

    @Test("the server's compliance30 paints verbatim: rate, taken, taken + missed")
    func serverWindowVerbatim() {
        let store = makeStore()
        store._testInject(intakes: [], compliance: Self.payload(rate30: 75, taken30: 3, missed30: 1, skipped30: 2))
        #expect(store.complianceKPIState() == .server(.init(rate: 75, taken: 3, expected: 4)))
    }

    @Test("a client on-time tally no longer outranks the server (ledger + drained intakes present)")
    func clientTallyNeverWins() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Ledger says 1 of 2 on time (50 %), the drained table 10 of 10 (100 %);
        // the server says 75 %. Only the server number may paint.
        let rows = [
            makeLedgerRow(id: "r1", status: .takenOnTime, at: now.addingTimeInterval(-86400)),
            makeLedgerRow(id: "r2", status: .takenLate, at: now.addingTimeInterval(-2 * 86400))
        ]
        let store = makeStore()
        store._testInject(
            intakes: makeWindow(days: 10, now: now),
            compliance: Self.payload(),
            doseHistory: makeEnvelope(rows: rows, now: now)
        )
        #expect(store.complianceKPIState() == .server(.init(rate: 75, taken: 3, expected: 4)))
    }

    @Test("applicable: false (NO_LOCAL_SCHEDULE) never paints its zero placeholders as 0 %")
    func notApplicable() {
        let store = makeStore()
        store._testInject(intakes: [], compliance: Self.payload(rate30: 0, taken30: 0, missed30: 0, applicable: false))
        #expect(store.complianceKPIState() == .notApplicable)
    }

    @Test("an older server without `applicable` keeps its percentage")
    func olderServerStillApplicable() {
        let store = makeStore()
        store._testInject(intakes: [], compliance: Self.payload(applicable: nil))
        #expect(store.complianceKPIState() == .server(.init(rate: 75, taken: 3, expected: 4)))
    }

    @Test("settled offline (no payload) reads unknown, not a local estimate from the drained history")
    func unavailableAfterSettleWithoutServer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [makeLedgerRow(id: "r1", status: .takenOnTime, at: now.addingTimeInterval(-86400))]
        let store = makeStore()
        store._testInject(
            intakes: makeWindow(days: 10, now: now),
            doseHistory: makeEnvelope(rows: rows, now: now),
            settled: true
        )
        #expect(store.complianceKPIState() == .unavailable)
    }

    @Test("applicable decodes from the v1.39 wire shape")
    func decodesApplicable() throws {
        let json = #"""
        {"applicable":false,"notApplicableReason":"NO_LOCAL_SCHEDULE",
         "compliance7":{"totalExpected":0,"taken":0,"skipped":0,"missed":0,"rate":0,"streak":0},
         "compliance30":{"totalExpected":0,"taken":0,"skipped":0,"missed":0,"rate":0,"streak":0},
         "dailyCompliance":{},"complianceDisplay":null}
        """#
        let payload = try JSONDecoder.hlDefault.decode(MedicationCompliancePayload.self, from: Data(json.utf8))
        #expect(payload.isApplicable == false)
    }

    // MARK: - Fixtures

    private func makeStore() -> MedicationDetailStore {
        let med = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 12, minute: 0)])
        )
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: KPIStateStubAPIClient(), outbox: outbox)
        return MedicationDetailStore(medication: med, repo: repo)
    }

    private func makeWindow(days: Int, now: Date) -> [PaginatedIntakeEvent] {
        (0 ..< days).map { offset in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return PaginatedIntakeEvent(
                id: "i-\(offset)",
                takenAt: scheduled,
                skipped: false,
                scheduledFor: scheduled,
                injectionSite: nil
            )
        }
    }

    private func makeEnvelope(rows: [MedicationDoseHistoryRow], now: Date) -> MedicationDoseHistoryEnvelope {
        MedicationDoseHistoryEnvelope(
            from: now.addingTimeInterval(-30 * 24 * 60 * 60),
            to: now,
            rows: rows
        )
    }

    private func makeLedgerRow(
        id: String,
        status: MedicationDoseHistoryStatus,
        at: Date
    ) -> MedicationDoseHistoryRow {
        MedicationDoseHistoryRow(
            kind: "slot",
            at: at,
            timeOfDay: "12:00",
            statusRaw: status.rawValue,
            intake: MedicationDoseHistoryRow.Intake(
                id: id,
                scheduledFor: at,
                takenAt: status == .takenOnTime || status == .takenLate ? at : nil,
                skipped: status == .skipped
            )
        )
    }
}

private final class KPIStateStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.canceled
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.canceled
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.canceled
    }
}
