import Foundation
@testable import HealthLog
import Testing

/// **W3-MEDCONTRACT (v0.14.8) — ledger-first detail-store derivations.**
///
/// When the server dose-history ledger is loaded, `complianceSummary()` and
/// `verlaufGlyphs()` must read it verbatim instead of re-deriving from the
/// current schedule — the ledger is era-aware (v1.16.3): after a schedule
/// edit the server keeps grading past days against the schedule live THEN,
/// which no client projection can reproduce. With no ledger (older server,
/// standalone, fetch hiccup) the legacy local derivation stays in charge.
/// Also locks the `takenAt` clamp/pre-flight on retro-marks (server 422s
/// future + >5 y past instants since v1.15.19).
@MainActor
@Suite("MedicationDetailStore — W3 dose-history ledger")
struct MedicationDetailStoreLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Ledger-first compliance KPI

    @Test("Ledger KPI: on-time/late/missed count, skipped+upcoming+ad-hoc don't")
    func ledgerComplianceCounting() {
        let rows: [MedicationDoseHistoryRow] = [
            slotRow(daysAgo: 1, status: "taken_on_time"),
            slotRow(daysAgo: 2, status: "taken_on_time"),
            slotRow(daysAgo: 3, status: "taken_late"),
            slotRow(daysAgo: 4, status: "missed"),
            // Deliberate skip leaves the denominator (W19e doctrine).
            slotRow(daysAgo: 5, status: "skipped"),
            // b162 dose-safety: a future slot never reads as taken/missed.
            slotRow(daysAgo: -1, status: "upcoming"),
            // Off-schedule take — no punctuality semantics.
            adHocRow(daysAgo: 6)
        ]
        let store = makeStore(doseHistory: envelope(rows: rows))
        let summary = store.complianceSummary(now: now)
        #expect(summary.inTime == 2)
        #expect(summary.total == 4, "2 on-time + 1 late + 1 missed; skip/upcoming/ad-hoc excluded")
    }

    @Test("Ledger rows older than the trailing 30 d stay out of the KPI window")
    func ledgerComplianceWindow() {
        let rows: [MedicationDoseHistoryRow] = [
            slotRow(daysAgo: 1, status: "taken_on_time"),
            slotRow(daysAgo: 45, status: "missed"),
            slotRow(daysAgo: 90, status: "missed")
        ]
        let store = makeStore(doseHistory: envelope(rows: rows))
        let summary = store.complianceSummary(now: now)
        #expect(summary.inTime == 1)
        #expect(summary.total == 1)
        #expect(summary.percentage == 100)
    }

    // MARK: - Era boundary (glyph track)

    @Test("Era boundary: days without minted ledger rows render noSchedule, not missed")
    func eraBoundaryGlyphs() {
        // Scenario: the medication's daily schedule was created/edited two
        // days ago. The CURRENT schedule (daily 12:00) would project slots
        // across all 14 days — a local derivation would paint 12 false
        // misses. The era-aware ledger minted rows only inside the live
        // era, so everything before the boundary must stay `.noSchedule`.
        let rows: [MedicationDoseHistoryRow] = [
            slotRow(daysAgo: 0, status: "taken_on_time"),
            slotRow(daysAgo: 1, status: "missed")
        ]
        let store = makeStore(doseHistory: envelope(rows: rows))
        let glyphs = store.verlaufGlyphs(days: 14, now: now)
        #expect(glyphs.count == 14)
        #expect(glyphs[13] == .onTime, "today — ledger graded taken_on_time")
        #expect(glyphs[12] == .missed, "yesterday — ledger graded missed")
        #expect(
            glyphs[0 ..< 12].allSatisfy { $0 == .noSchedule },
            "pre-era days carry no minted rows → noSchedule, never a false miss"
        )
    }

    @Test("Ledger glyph day-reduction: missed dominates, late beats on-time")
    func ledgerGlyphReduction() {
        let rows: [MedicationDoseHistoryRow] = [
            // Day 1: one on-time + one missed → missed dominates.
            slotRow(daysAgo: 1, status: "taken_on_time", timeOfDay: "08:00"),
            slotRow(daysAgo: 1, status: "missed", timeOfDay: "20:00"),
            // Day 2: one on-time + one late → late.
            slotRow(daysAgo: 2, status: "taken_on_time", timeOfDay: "08:00"),
            slotRow(daysAgo: 2, status: "taken_late", timeOfDay: "20:00"),
            // Day 3: all skipped → deliberate decision, renders onTime.
            slotRow(daysAgo: 3, status: "skipped")
        ]
        let store = makeStore(doseHistory: envelope(rows: rows))
        let glyphs = store.verlaufGlyphs(days: 4, now: now)
        #expect(glyphs[2] == .missed)
        #expect(glyphs[1] == .late)
        #expect(glyphs[0] == .onTime)
    }

    // MARK: - Fallback (≤ v1.15.17 / standalone / fetch hiccup)

    @Test("No ledger → legacy intake-derived compliance stays in charge")
    func fallbackWithoutLedger() {
        // Two intakes taken exactly on schedule — the legacy ±30 min local
        // derivation grades both in-time. `doseHistory` nil simulates a 404
        // from a ≤ v1.15.17 server (repo throw → store keeps nil).
        let intakes = (1 ... 2).map { offset -> PaginatedIntakeEvent in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return PaginatedIntakeEvent(
                id: "evt-\(offset)",
                takenAt: scheduled,
                skipped: false,
                scheduledFor: scheduled,
                injectionSite: nil
            )
        }
        let store = makeStore(intakes: intakes, doseHistory: nil)
        let summary = store.complianceSummary(now: now)
        #expect(summary.inTime == 2)
        #expect(summary.total == 2)
        let glyphs = store.verlaufGlyphs(days: 3, now: now)
        #expect(glyphs[1] == .onTime, "legacy glyph path keeps rendering from intakes")
    }

    @Test("Ledger beats a divergent legacy derivation when both could answer")
    func ledgerWinsOverLocal() {
        // Local intakes say "all on time"; the era-aware ledger says one
        // slot was missed (a schedule edit moved the slot the local math
        // can't see). The KPI must repeat the ledger.
        let scheduled = now.addingTimeInterval(-24 * 60 * 60)
        let intakes = [PaginatedIntakeEvent(
            id: "evt-1", takenAt: scheduled, skipped: false,
            scheduledFor: scheduled, injectionSite: nil
        )]
        let ledger = envelope(rows: [
            slotRow(daysAgo: 1, status: "taken_on_time"),
            slotRow(daysAgo: 2, status: "missed")
        ])
        let store = makeStore(intakes: intakes, doseHistory: ledger)
        let summary = store.complianceSummary(now: now)
        #expect(summary.inTime == 1)
        #expect(summary.total == 2)
        #expect(summary.percentage == 50)
    }

    // MARK: - takenAt cap / clamp (server 422s future instants, v1.15.19)

    @Test("Retro-mark taken with a future scheduledAt clamps takenAt to now")
    func retroMarkClampsFutureTakenAt() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        let captured = CapturedBody()

        let scheduledAt = now.addingTimeInterval(60 * 60) // 1 h in the future
        await api.setHandler { request in
            if let typed = request as? APIRequest<MedicationIntakeWireDTO> {
                await captured.set(typed.body)
                return MedicationIntakeWireDTO(
                    id: "intake-1",
                    medicationId: "med-1",
                    scheduledFor: scheduledAt,
                    takenAt: now,
                    skipped: false,
                    snoozedUntil: nil
                )
            }
            throw HLError.unknown("unexpected request type")
        }

        let outcome = await store.markIntakeRetroactively(
            medicationId: "med-1",
            eventId: "intake-1",
            status: .taken,
            scheduledAt: scheduledAt,
            now: now
        )
        #expect(outcome == .success)

        let body = try #require(await captured.body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let patch = try decoder.decode(MedicationsRepository.IntakePatch.self, from: body)
        #expect(patch.takenAt == .value(now), "future scheduledAt must clamp to now — server 422s otherwise")
        #expect(patch.skipped == false)
    }

    @Test("Retro-mark beyond the 5-year floor fails locally with 422 — no round-trip")
    func retroMarkPreflightsAncientTakenAt() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        let called = CapturedBody()
        await api.setHandler { _ in
            await called.set(Data())
            throw HLError.unknown("must not be reached")
        }

        let ancient = now.addingTimeInterval(-6 * 365 * 24 * 60 * 60)
        let outcome = await store.markIntakeRetroactively(
            medicationId: "med-1",
            eventId: "intake-1",
            status: .taken,
            scheduledAt: ancient,
            now: now
        )
        if case let .failed(err) = outcome, case let .server(status, _, _) = err {
            #expect(status == 422)
        } else {
            Issue.record("expected local .failed(422), was \(outcome)")
        }
        #expect(await called.body == nil, "pre-flight must not burn a server round-trip")
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "a locally invalid write must never park on the outbox")
    }

    // MARK: - Helpers

    private actor CapturedBody {
        private(set) var body: Data?
        func set(_ data: Data?) {
            body = data
        }
    }

    private func envelope(rows: [MedicationDoseHistoryRow]) -> MedicationDoseHistoryEnvelope {
        MedicationDoseHistoryEnvelope(
            from: now.addingTimeInterval(-90 * 24 * 60 * 60),
            to: now,
            family: "daily",
            hasExpectedSlots: true,
            rows: rows
        )
    }

    private func slotRow(
        daysAgo: Int,
        status: String,
        timeOfDay: String = "08:00"
    ) -> MedicationDoseHistoryRow {
        let at = now.addingTimeInterval(Double(-daysAgo) * 24 * 60 * 60)
        let intake: MedicationDoseHistoryRow.Intake? = status.hasPrefix("taken") || status == "skipped"
            ? .init(
                id: "evt-d\(daysAgo)-\(timeOfDay)",
                scheduledFor: at,
                takenAt: status.hasPrefix("taken") ? at : nil,
                skipped: status == "skipped",
                autoMissed: false
            )
            : nil
        return MedicationDoseHistoryRow(
            kind: "slot",
            at: at,
            timeOfDay: timeOfDay,
            statusRaw: status,
            intake: intake
        )
    }

    private func adHocRow(daysAgo: Int) -> MedicationDoseHistoryRow {
        let at = now.addingTimeInterval(Double(-daysAgo) * 24 * 60 * 60)
        return MedicationDoseHistoryRow(
            kind: "ad_hoc",
            at: at,
            timeOfDay: nil,
            statusRaw: "ad_hoc",
            intake: .init(id: "adhoc-\(daysAgo)", scheduledFor: at, takenAt: at, skipped: false, autoMissed: false)
        )
    }

    private func makeStore(
        intakes: [PaginatedIntakeEvent] = [],
        doseHistory: MedicationDoseHistoryEnvelope?
    ) -> MedicationDetailStore {
        let medication = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 12, minute: 0)])
        )
        let api = LedgerStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationDetailStore(medication: medication, repo: repo)
        store._testInject(intakes: intakes, doseHistory: doseHistory)
        return store
    }
}

/// Inert client for derivation-only tests — every call throws, mirroring a
/// ≤ v1.15.17 server where the dose-history route does not exist (404).
private final class LedgerStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.server(status: 404, code: "NOT_FOUND", message: "no route")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.server(status: 404, code: "NOT_FOUND", message: "no route")
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.server(status: 404, code: "NOT_FOUND", message: "no route")
    }
}
