import Foundation
@testable import HealthLog
import Testing

/// **W-COMPLIANCE-INV — KPI paint-state sequence pins.**
///
/// The operator-reported flicker (compliance % jumping 100 → 60 → 50 on
/// screen-open) was the detail KPI painting THREE different sources during a
/// single `load()`:
///
///   1. paint 1 — empty `intakes` → `ComplianceSummary(0, 0)` → ratio 1.0 →
///      **100 %** (pure client artefact),
///   2. paints 2..N — the ±30-min in-time derivation re-ran against every
///      partially-drained intake page,
///   3. final paint — the server dose-history ledger landed last.
///
/// `complianceKPIState()` pins the fixed sequence: `.pending` until the load
/// settles (placeholder, no number at all), then exactly ONE number — the
/// server-canonical value when any server payload exists, or the clearly
/// marked `.localFallback` when the load settled without one (offline / old
/// server). No intermediate client value can ever paint.
@MainActor
@Suite("MedicationDetailStore — W-COMPLIANCE-INV KPI paint state")
struct MedicationDetailStoreKPIStateTests {
    @Test("Pre-settle: empty store paints .pending, never the 100% artefact")
    func pendingBeforeAnyData() {
        let store = makeStore()
        store._testInject(intakes: [], settled: false)
        #expect(store.complianceKPIState() == .pending)
    }

    @Test("Pre-settle: partially-drained intakes still paint .pending (no interim repaint)")
    func pendingWhileIntakesDrain() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        // Simulate the mid-load state: one intake page landed, server
        // compliance + ledger have not. The old code painted the client
        // in-time derivation here (the "60" of 100→60→50).
        store._testInject(intakes: makeWindow(days: 10, now: now), settled: false)
        #expect(store.complianceKPIState(now: now) == .pending)
    }

    @Test("Settled with ledger: paints .server with the ledger numbers")
    func serverFromLedger() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [MedicationDoseHistoryRow] = [
            makeLedgerRow(id: "r1", status: .takenOnTime, at: now.addingTimeInterval(-1 * 86400)),
            makeLedgerRow(id: "r2", status: .missed, at: now.addingTimeInterval(-2 * 86400))
        ]
        let store = makeStore()
        store._testInject(
            intakes: [],
            doseHistory: makeEnvelope(rows: rows, now: now)
        )
        let state = store.complianceKPIState(now: now)
        #expect(state == .server(.init(inTime: 1, total: 2)))
    }

    @Test("Ledger wins even before settle (server value may paint early, client may not)")
    func ledgerPaintsImmediately() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [makeLedgerRow(id: "r1", status: .takenOnTime, at: now.addingTimeInterval(-86400))]
        let store = makeStore()
        store._testInject(
            intakes: [],
            doseHistory: makeEnvelope(rows: rows, now: now),
            settled: false
        )
        #expect(store.complianceKPIState(now: now) == .server(.init(inTime: 1, total: 1)))
    }

    @Test("Settled without any server payload: clearly-marked .localFallback")
    func localFallbackAfterSettleWithoutServer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        store._testInject(intakes: makeWindow(days: 10, now: now), settled: true)
        guard case let .localFallback(summary) = store.complianceKPIState(now: now) else {
            Issue.record("expected .localFallback when the load settled offline")
            return
        }
        #expect(summary.total == 10)
    }

    @Test("Settled with server window (old server, no ledger, no drained intakes): .server")
    func serverWindowWithoutLedger() {
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 4, taken: 3, skipped: 0, missed: 1, rate: 75, streak: 0
            ),
            dailyCompliance: [
                "2026-05-13": DailyComplianceBucket(
                    expected: 1, taken: 1, skipped: 0, onTime: 1, late: 0, veryLate: 0,
                    due: true, expectedCount: 1
                )
            ]
        )
        let store = makeStore()
        store._testInject(intakes: [], compliance: payload)
        #expect(store.complianceKPIState() == .server(.init(inTime: 3, total: 4)))
    }

    @Test("W-MEDVERIFY — capable server window paints .server even with drained intakes (never 'Offline – lokale Schätzung' while online)")
    func capableServerWindowBeatsDrainedIntakes() {
        // Demo-walkthrough regression (v0.14.8): ledger-less server, online,
        // `/compliance` landed AND the intake table drained — the old ordering
        // painted `.localFallback` ("Offline – lokale Schätzung") with a
        // re-derived 0 % while the med card showed the server 75 %. A
        // v1.7.0-capable payload must paint `.server` with its verbatim window.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 0, skipped: 0, missed: 1, rate: 0, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 4, taken: 3, skipped: 0, missed: 1, rate: 75, streak: 5
            ),
            dailyCompliance: [
                "2026-06-07": DailyComplianceBucket(
                    expected: 1, taken: 0, skipped: 0, onTime: 0, late: 0, veryLate: 0,
                    due: true, expectedCount: 1
                )
            ]
        )
        #expect(payload.isV170Capable)
        // Drained history present (10 in-window slots) — must NOT flip the
        // paint to the local estimate anymore.
        let store = makeStore()
        store._testInject(intakes: makeWindow(days: 10, now: now), compliance: payload)
        #expect(store.complianceKPIState(now: now) == .server(.init(inTime: 3, total: 4)))
    }

    @Test("State sequence over a simulated load: pending → pending → server (no value jump)")
    func paintSequenceHasNoValueJump() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore()
        var painted: [MedicationDetailStore.ComplianceKPIState] = []

        // t0 — screen pushed, nothing loaded.
        store._testInject(intakes: [], settled: false)
        painted.append(store.complianceKPIState(now: now))
        // t1 — first intake page drained.
        store._testInject(intakes: makeWindow(days: 5, now: now), settled: false)
        painted.append(store.complianceKPIState(now: now))
        // t2 — load settles with the server ledger.
        let rows = [
            makeLedgerRow(id: "r1", status: .takenOnTime, at: now.addingTimeInterval(-86400)),
            makeLedgerRow(id: "r2", status: .takenLate, at: now.addingTimeInterval(-2 * 86400))
        ]
        store._testInject(
            intakes: makeWindow(days: 5, now: now),
            doseHistory: makeEnvelope(rows: rows, now: now)
        )
        painted.append(store.complianceKPIState(now: now))

        // Exactly one numeric paint, and it is the server value.
        #expect(painted == [
            .pending,
            .pending,
            .server(.init(inTime: 1, total: 2))
        ])
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
