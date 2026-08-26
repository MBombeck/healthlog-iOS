import Foundation
@testable import HealthLog
import Testing

/// **v0.5.4.3 HP-6.** Operator screenshot showed
/// "Heute nichts geplant" on a Dashboard with demonstrably-scheduled
/// intakes. Root cause: server `compliance.scheduledToday` aggregator
/// uses a UTC day bucket; `/api/medications/intake?scope=today` uses
/// the user's timezone. The early-morning local window slips between
/// the two. `ComplianceSnapshot.reconciled(...)` overlays the local
/// snapshot derived from `todayIntakes` onto the server's snapshot.
///
/// Contract (v0.10 R5 — trust local, no per-axis `max`):
/// 1. When the local user-tz view produced any slot for today
///    (`localScheduled > 0`), return the local pair verbatim — it is
///    internally consistent (`taken ≤ scheduled`) and carries the
///    optimistic-taken count. The server snapshot is ignored on both axes.
/// 2. Only when the local view is empty (`localScheduled == 0`) fall back to
///    the server snapshot (cold-cache / "nothing scheduled").
/// 3. Intakes for archived medications never contribute to the local count.
/// 4. Intakes outside the user's tz day are ignored.
@Suite("ComplianceSnapshot.reconciled — v0.10 R5")
struct ComplianceSnapshotReconciledTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_715_990_400)

    /// Helper — build a today-window intake `offsetHours` after start-of-day.
    private func intake(
        id: String,
        medicationID: String = "med-A",
        offsetHours: Int,
        status: IntakeStatus = .pending,
        takenAt: Date? = nil
    ) throws -> MedicationIntake {
        let startOfDay = calendar.startOfDay(for: now)
        let scheduledAt = try #require(
            calendar.date(byAdding: .hour, value: offsetHours, to: startOfDay)
        )
        return MedicationIntake(
            id: id,
            medicationId: medicationID,
            scheduledAt: scheduledAt,
            takenAt: takenAt,
            status: status
        )
    }

    @Test("widens server zero with three local pending intakes")
    func widensServerZero() throws {
        let intakes = try (1 ... 3).map { try intake(id: "i\($0)", offsetHours: $0) }
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 3)
        #expect(reconciled.takenToday == 0)
        #expect(reconciled.hasSchedule == true)
    }

    @Test("widening counts taken intakes correctly")
    func widensWithTaken() throws {
        let intakes: [MedicationIntake] = try [
            intake(id: "1", offsetHours: 1, status: .taken, takenAt: now),
            intake(id: "2", offsetHours: 2),
            intake(id: "3", offsetHours: 3)
        ]
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 3)
        #expect(reconciled.takenToday == 1)
    }

    /// **v0.10 R5.** When local sees any slot, the local pair wins verbatim —
    /// the server's higher (UTC-bucketed) count is no longer merged in, because
    /// per-axis `max` over the UTC/user-tz seam produced phantom doses. Local
    /// 1 pending slot ⇒ `1/0`, regardless of the server's `4/2`.
    @Test("trusts local pair verbatim when local sees a slot, ignoring higher server")
    func localWinsOverHigherServer() throws {
        let intakes: [MedicationIntake] = try [intake(id: "1", offsetHours: 1)]
        let server = ComplianceSnapshot(scheduledToday: 4, takenToday: 2)
        let reconciled = ComplianceSnapshot.reconciled(
            server: server,
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 1)
        #expect(reconciled.takenToday == 0)
    }

    @Test("ignores intakes for archived medications")
    func ignoresArchivedMedications() throws {
        let intakes: [MedicationIntake] = try [
            intake(id: "1", medicationID: "med-active", offsetHours: 1),
            intake(id: "2", medicationID: "med-archived", offsetHours: 2),
            intake(id: "3", medicationID: "med-archived", offsetHours: 3)
        ]
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-active"],
            medicationsLoaded: true,
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 1)
    }

    @Test("ignores intakes outside today's calendar window")
    func ignoresIntakesOutsideToday() throws {
        let intakes: [MedicationIntake] = try [
            intake(id: "y", offsetHours: -2),
            intake(id: "t", offsetHours: 5),
            intake(id: "tm", offsetHours: 28)
        ]
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 1) // only the in-day intake
    }

    @Test("returns server snapshot when both sources are empty (truly nothing scheduled)")
    func emptyOnBothSides() {
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            todayIntakes: [],
            activeMedicationIDs: [],
            medicationsLoaded: false, // cold start: server snapshot wins
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 0)
        #expect(reconciled.takenToday == 0)
        #expect(reconciled.hasSchedule == false)
    }

    /// Regression mirror of the operator screenshot: 3 morning intakes
    /// scheduled for today, server reports 0 → reconciled snapshot
    /// surfaces "0/3" (not "Heute nichts geplant").
    @Test("operator regression: 3 planned intakes, server zero, ring shows 0/3")
    func operatorRegression() throws {
        let intakes = try (0 ..< 3).map { i in
            try intake(id: "morning-\(i)", offsetHours: 7 + i)
        }
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            now: now,
            calendar: calendar
        )
        #expect(reconciled.hasSchedule == true)
        #expect(reconciled.scheduledToday == 3)
        #expect(reconciled.takenToday == 0)
        #expect(reconciled.ratio == 0.0)
    }

    /// **v0.8.1 WC regression.** Twice-daily med (Lisinopril): the server has
    /// already emitted both rows, so `scheduledToday` is *equal* (2 == 2).
    /// The operator marks one dose taken — only local `todayIntakes` flips to
    /// `.taken` while `server.takenToday` stays a stale `0`. The previous
    /// `localScheduled > server.scheduledToday` guard returned the server
    /// snapshot verbatim, so the tile stuck at "0 von 2". Trusting the local
    /// pair surfaces the optimistic taken immediately.
    @Test("equal scheduled counts: optimistic local taken surfaces (0→1)")
    func equalScheduledOptimisticTaken() throws {
        let intakes: [MedicationIntake] = try [
            intake(id: "lisinopril-am", offsetHours: 8, status: .taken, takenAt: now),
            intake(id: "lisinopril-pm", offsetHours: 20)
        ]
        let reconciled = try ComplianceSnapshot.reconciled(
            // Server: both rows scheduled, takenToday still stale at 0.
            server: ComplianceSnapshot(scheduledToday: 2, takenToday: 0),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            // v0.14.1 DOSE-SAFETY: pin `now` to 12:00 so the 08:00 AM dose is
            // in the PAST (genuinely takeable) and the 20:00 PM dose is still
            // future — the previous `now` == start-of-day made the AM dose
            // future-taken, which the dose-safety guard now (correctly) drops.
            now: #require(calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))),
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 2)
        #expect(reconciled.takenToday == 1)
        #expect(reconciled.ratio == 0.5)
    }

    /// **v0.10 R5 — the "1 von 3" bug.** Twice-daily Lisinopril: the server's
    /// UTC-bucketed `compliance` aggregator leaks a phantom third dose across
    /// the UTC/CEST seam (`scheduledToday: 3`), while the local user-tz view
    /// correctly sees the two today slots (07:00 taken, 19:00 pending). The
    /// old per-axis `max(3, 2) = 3`, `max(1, 1) = 1` produced the impossible
    /// "1 von 3". The fix trusts the coherent local pair ⇒ `2/1`.
    @Test("regression: server 3/1 + local 2/1 ⇒ 2/1 (no phantom dose)")
    func phantomDoseDropped() throws {
        let intakes: [MedicationIntake] = try [
            intake(id: "lisinopril-am", offsetHours: 7, status: .taken, takenAt: now),
            intake(id: "lisinopril-pm", offsetHours: 19)
        ]
        let reconciled = try ComplianceSnapshot.reconciled(
            // Server over-counts: 3 scheduled (phantom yesterday-19:00 row),
            // 1 taken.
            server: ComplianceSnapshot(scheduledToday: 3, takenToday: 1),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            // v0.14.1 DOSE-SAFETY: pin `now` to 12:00 so the 07:00 AM dose is
            // genuinely takeable (past) while the 19:00 PM dose stays pending.
            now: #require(calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))),
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 2)
        #expect(reconciled.takenToday == 1)
        #expect(reconciled.ratio == 0.5)
    }

    /// **v0.10 R5.** Local view is empty (no slot fired today / meds not yet
    /// loaded) ⇒ fall back to the server snapshot so a cold-cache first-paint
    /// still renders the server's view.
    @Test("falls back to server when local is empty")
    func fallbackToServerWhenLocalEmpty() throws {
        let intakes: [MedicationIntake] = try [intake(id: "y", offsetHours: -2)]
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 2, takenToday: 1),
            todayIntakes: intakes, // only an out-of-window intake → localScheduled == 0
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: false, // cold start: meds not loaded → server wins
            now: now,
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 2)
        #expect(reconciled.takenToday == 1)
    }

    /// **v0.14.1 DOSE-SAFETY.** A `.taken` intake whose `scheduledAt` is in
    /// the FUTURE must never count toward `takenToday`. Twice-daily Lisinopril
    /// 07:00/19:00, viewed before 19:00: the morning dose is genuinely taken,
    /// but the server has stamped the 19:00 slot `taken` too (the ±6h
    /// afternoon→19:00 explicit-write snap). Without the guard,
    /// `taken == scheduled` (2/2) → the card reads "alles eingenommen" and the
    /// real evening dose is masked. The future row must count as not-yet-taken
    /// ⇒ 2 scheduled / 1 taken.
    @Test("DOSE-SAFETY: a future-scheduled .taken row is NOT counted as taken")
    func futureTakenNotCounted() throws {
        let intakes: [MedicationIntake] = try [
            // `now` is start-of-day + 0h in the fixture, so any positive offset
            // is in the future relative to `now`.
            intake(id: "lisinopril-am", offsetHours: 7, status: .taken, takenAt: now),
            intake(id: "lisinopril-pm", offsetHours: 19, status: .taken, takenAt: now)
        ]
        let reconciled = try ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 2, takenToday: 2),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            // Pin `now` to 12:00 — between the 07:00 (past) and 19:00 (future)
            // slots — so the morning dose counts and the evening one does not.
            now: #require(calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))),
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 2)
        #expect(reconciled.takenToday == 1)
        #expect(reconciled.ratio == 0.5)
    }

    /// Complement of the dose-safety guard: a `.taken` row whose `scheduledAt`
    /// is at or before `now` still counts as taken (the guard is strictly a
    /// future filter, it must not drop legitimately-taken past doses).
    @Test("DOSE-SAFETY: a .taken row scheduled at-or-before now IS counted")
    func pastTakenStillCounted() throws {
        let intakes: [MedicationIntake] = try [
            intake(id: "lisinopril-am", offsetHours: 7, status: .taken, takenAt: now),
            intake(id: "lisinopril-pm", offsetHours: 19)
        ]
        let reconciled = try ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 2, takenToday: 1),
            todayIntakes: intakes,
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true,
            now: #require(calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))),
            calendar: calendar
        )
        #expect(reconciled.scheduledToday == 2)
        #expect(reconciled.takenToday == 1)
    }
}
