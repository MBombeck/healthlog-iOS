import Foundation
@testable import HealthLog
import Testing

/// **v0.5.6 HOME-COMPLIANCE-SHEET — sheet snapshot contract.**
///
/// Pins the pure snapshot/sort/overdue rules for
/// `AnstehendeEinnahmenSheet`. The view layer is exercised at the
/// snapshot/UAT level — these tests guard the data-mapping rules:
///
/// - Today-only calendar-day window (no tomorrow/yesterday bleed).
/// - Pending-overdue rows lead, then pending-upcoming, then
///   taken/skipped collapsed to the bottom in chronological order.
/// - Archived (`active == false`) medications are dropped.
/// - Subtitle counts only count remaining pending rows on top of the
///   total day-row count.
/// - `overdueCount` matches the rows the banner is supposed to surface.
@Suite("AnstehendeEinnahmenSheet — snapshot contract")
struct AnstehendeEinnahmenSheetTests {
    // MARK: - Fixtures

    /// Parity 1.9 — `nextDueAt` + `nextDueOverdue` are how the SERVER says
    /// "this slot is overdue". The sheet reads that flag now instead of
    /// comparing `scheduledAt` against the wall clock, so every fixture that
    /// wants an overdue row has to say so the way the server would.
    private func med(
        id: String,
        name: String = "Lisinopril",
        active: Bool = true,
        overdueSlotAt: Date? = nil
    ) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: "5 mg",
            schedule: MedicationSchedule(times: []),
            notificationsEnabled: true,
            active: active,
            nextDueAt: overdueSlotAt,
            nextDueOverdue: overdueSlotAt != nil
        )
    }

    private func intake(
        id: String,
        medId: String,
        scheduledAt: Date,
        status: IntakeStatus = .pending
    ) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medId,
            scheduledAt: scheduledAt,
            takenAt: status == .taken ? scheduledAt : nil,
            status: status
        )
    }

    private var now: Date {
        // 2026-05-22, 12:00 local time — deterministic baseline.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 22
        comps.hour = 12
        return Calendar.current.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    private func at(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) ?? now
        return cal.date(byAdding: .init(hour: hour, minute: minute), to: day) ?? day
    }

    // MARK: - Tests

    @Test("Empty intakes → empty snapshot + empty subtitle")
    func emptyDay() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [],
            medications: [med(id: "m1")],
            now: now
        )
        #expect(snap.rows.isEmpty)
        #expect(snap.totalCount == 0)
        #expect(snap.pendingCount == 0)
    }

    @Test("Rows from tomorrow / yesterday are filtered out")
    func todayWindowOnly() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                intake(id: "yesterday", medId: "m1", scheduledAt: at(hour: 8, dayOffset: -1)),
                intake(id: "today-morning", medId: "m1", scheduledAt: at(hour: 8)),
                intake(id: "tomorrow", medId: "m1", scheduledAt: at(hour: 8, dayOffset: 1))
            ],
            medications: [med(id: "m1")],
            now: now
        )
        #expect(snap.rows.map(\.id) == ["today-morning"])
    }

    @Test("Archived medications are dropped from rows")
    func archivedMedDropped() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [intake(id: "i1", medId: "archived", scheduledAt: at(hour: 8))],
            medications: [med(id: "archived", active: false)],
            now: now
        )
        #expect(snap.rows.isEmpty)
    }

    @Test("Sort: overdue-pending first, then upcoming-pending, then taken/skipped")
    func sortRanking() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                intake(id: "upcoming-18", medId: "m1", scheduledAt: at(hour: 18)),
                intake(id: "overdue-08", medId: "m1", scheduledAt: at(hour: 8)),
                intake(id: "taken-09", medId: "m1", scheduledAt: at(hour: 9), status: .taken),
                intake(id: "overdue-10", medId: "m1", scheduledAt: at(hour: 10))
            ],
            // The server flags the 08:00 slot as the open overdue dose.
            medications: [med(id: "m1", overdueSlotAt: at(hour: 8))],
            now: now
        )
        #expect(snap.rows.map(\.id) == [
            "overdue-08",
            "overdue-10",
            "upcoming-18",
            "taken-09"
        ])
    }

    /// **Parity 1.9 — the doctrine test.** A pending slot whose time has passed
    /// is NOT overdue unless the SERVER says so. The old implementation read
    /// `scheduledAt < now` and painted this row red; the server, which knows the
    /// catch-up band, considers it closed and ships no flag.
    @Test("A passed pending slot the server did NOT flag is not overdue")
    func passedSlotWithoutServerFlagIsNotOverdue() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [intake(id: "i1", medId: "m1", scheduledAt: at(hour: 8))],
            medications: [med(id: "m1")], // no nextDueOverdue
            now: now
        )
        #expect(snap.rows.first?.isOverdue == false)
    }

    /// The flag addresses ONE slot by its instant — it must not bleed onto the
    /// medication's other pending rows, or a still-upcoming evening dose would
    /// be painted overdue and sorted to the top.
    @Test("The server overdue flag marks only the slot it names")
    func serverFlagMarksOnlyItsOwnSlot() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                intake(id: "flagged-08", medId: "m1", scheduledAt: at(hour: 8)),
                intake(id: "upcoming-18", medId: "m1", scheduledAt: at(hour: 18))
            ],
            medications: [med(id: "m1", overdueSlotAt: at(hour: 8))],
            now: now
        )
        #expect(snap.rows.first { $0.id == "flagged-08" }?.isOverdue == true)
        #expect(snap.rows.first { $0.id == "upcoming-18" }?.isOverdue == false)
    }

    /// `nextDueOverdue: true` with a `nil` instant is a malformed payload and
    /// must never claim overdue (mirrors `Medication.hasOpenOverdueDose`).
    @Test("A flag without an instant claims nothing")
    func flagWithoutInstantClaimsNothing() {
        let malformed = Medication(
            id: "m1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: []),
            nextDueAt: nil,
            nextDueOverdue: true
        )
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [intake(id: "i1", medId: "m1", scheduledAt: at(hour: 8))],
            medications: [malformed],
            now: now
        )
        #expect(snap.rows.first?.isOverdue == false)
    }

    @Test("isOverdue requires pending status — taken rows never read as overdue")
    func overdueRequiresPending() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                intake(id: "i1", medId: "m1", scheduledAt: at(hour: 8), status: .taken)
            ],
            // The server still names this slot — the `.taken` status must veto it.
            medications: [med(id: "m1", overdueSlotAt: at(hour: 8))],
            now: now
        )
        #expect(snap.rows.count == 1)
        #expect(snap.rows.first?.isOverdue == false)
    }

    @Test("Subtitle counts pending only on top of total today-rows")
    func subtitleCounts() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                intake(id: "i1", medId: "m1", scheduledAt: at(hour: 8), status: .taken),
                intake(id: "i2", medId: "m1", scheduledAt: at(hour: 18))
            ],
            medications: [med(id: "m1")],
            now: now
        )
        #expect(snap.totalCount == 2)
        #expect(snap.pendingCount == 1)
        #expect(snap.subtitleKey.contains("1"))
        #expect(snap.subtitleKey.contains("2"))
    }

    /// **v0.14.1 DOSE-SAFETY.** A `.taken` intake scheduled LATER than `now`
    /// (the server's ±6h afternoon→19:00 snap, or a clock-skew edge) must not
    /// read as done: the row is flagged `isFutureTaken` so the glyph shows the
    /// neutral empty circle and it sorts with the upcoming-pending doses, never
    /// collapsed to the taken bottom.
    @Test("DOSE-SAFETY: a future-scheduled taken row is flagged + sorts as upcoming")
    func futureTakenFlaggedAndSortedAsUpcoming() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                // 08:00 genuinely taken (past), 19:00 stamped taken but still
                // future at the 12:00 `now`.
                intake(id: "taken-08", medId: "m1", scheduledAt: at(hour: 8), status: .taken),
                intake(id: "future-taken-19", medId: "m1", scheduledAt: at(hour: 19), status: .taken)
            ],
            medications: [med(id: "m1")],
            now: now
        )
        let futureRow = snap.rows.first { $0.id == "future-taken-19" }
        let pastRow = snap.rows.first { $0.id == "taken-08" }
        #expect(futureRow?.isFutureTaken == true)
        #expect(pastRow?.isFutureTaken == false)
        // future-taken (rank 1, upcoming) sorts above past-taken (rank 2).
        #expect(snap.rows.map(\.id) == ["future-taken-19", "taken-08"])
    }

    @Test("DOSE-SAFETY: a past taken row is NOT flagged as future-taken")
    func pastTakenNotFlagged() {
        let snap = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: [
                intake(id: "taken-08", medId: "m1", scheduledAt: at(hour: 8), status: .taken)
            ],
            medications: [med(id: "m1")],
            now: now
        )
        #expect(snap.rows.first?.isFutureTaken == false)
    }

    @Test("overdueCount mirrors the row predicate the sheet uses")
    func overdueCountHelper() {
        let count = AnstehendeEinnahmenSheet.overdueCount(
            todayIntakes: [
                intake(id: "i1", medId: "m1", scheduledAt: at(hour: 8)), // server-flagged overdue
                intake(id: "i2", medId: "m1", scheduledAt: at(hour: 18)), // upcoming
                intake(id: "i3", medId: "m1", scheduledAt: at(hour: 9), status: .taken) // taken
            ],
            medications: [med(id: "m1", overdueSlotAt: at(hour: 8))],
            now: now
        )
        #expect(count == 1)
    }
}

// MARK: - v0.6.1.7 Y7 — Compliance-Haken trailing-glyph contract

/// Locks the `TrailingPresentation` descriptor for the five
/// `IntakeStatus` cases. Operator-facing rule (handbook §5.5 / AP-014):
/// a pending dose must render an **empty** circle so the Haken is
/// reserved for the actually-taken state. These tests pin the symbol,
/// the token-tint, and the accessibility-label key per status so a
/// future drive-by edit that resurrects the "Haken-everywhere" pattern
/// trips a red diff.
@Suite("AnstehendeEinnahmenSheet — Y7 trailing presentation")
struct AnstehendeEinnahmenSheetTrailingPresentationTests {
    typealias Presentation = AnstehendeEinnahmenSheet.TrailingPresentation
    typealias Tint = AnstehendeEinnahmenSheet.HLTrailingTint

    @Test("Pending → empty circle in tertiary tint, points the a11y label at the mark-taken key")
    func pendingIsEmptyCircle() {
        let p = Presentation.resolve(status: .pending)
        #expect(p.symbolName == "circle")
        #expect(p.tint == Tint.tertiary)
        #expect(p.accessibilityLabelKey == "dashboard.intakesSheet.action.markTaken")
    }

    @Test("Taken → filled checkmark.circle in statusOK")
    func takenIsFilledCheckmarkInStatusOK() {
        let p = Presentation.resolve(status: .taken)
        #expect(p.symbolName == "checkmark.circle.fill")
        #expect(p.tint == Tint.statusOK)
        #expect(p.accessibilityLabelKey == "dashboard.intakesSheet.status.taken")
    }

    @Test("Skipped → outlined xmark.circle (no .fill) in secondary tint")
    func skippedIsOutlinedXmark() {
        let p = Presentation.resolve(status: .skipped)
        #expect(p.symbolName == "xmark.circle")
        #expect(p.symbolName.hasSuffix(".fill") == false)
        #expect(p.tint == Tint.secondary)
        #expect(p.accessibilityLabelKey == "dashboard.intakesSheet.status.skipped")
    }

    @Test("Snoozed → outlined moon.zzz in tertiary tint")
    func snoozedIsOutlinedMoon() {
        let p = Presentation.resolve(status: .snoozed)
        #expect(p.symbolName == "moon.zzz")
        #expect(p.tint == Tint.tertiary)
        #expect(p.accessibilityLabelKey == "dashboard.intakesSheet.status.snoozed")
    }

    @Test("Missed → filled xmark in statusBad and stays read-only")
    func missedIsTerminalStatusBad() {
        let p = Presentation.resolve(status: .missed)
        #expect(p.symbolName == "xmark.circle.fill")
        #expect(p.tint == Tint.statusBad)
        #expect(p.accessibilityLabelKey == "med.heatmap.status.missed")
    }

    @Test("Pending and taken never share the same symbol — the canonical Y7 invariant")
    func pendingAndTakenAreDistinct() {
        let pending = Presentation.resolve(status: .pending)
        let taken = Presentation.resolve(status: .taken)
        #expect(pending.symbolName != taken.symbolName)
        #expect(pending.tint != taken.tint)
    }

    /// **v0.14.1 DOSE-SAFETY.** A `.taken` intake whose scheduled time is still
    /// in the future must render the neutral empty-circle "upcoming" glyph —
    /// never the green checkmark — so a not-yet-due dose is never shown done.
    @Test("DOSE-SAFETY: future-scheduled taken resolves to the empty-circle upcoming glyph")
    func futureTakenResolvesToUpcoming() {
        let p = Presentation.resolve(status: .taken, isFutureScheduled: true)
        #expect(p.symbolName == "circle")
        #expect(p.symbolName.hasSuffix(".fill") == false)
        #expect(p.tint == Tint.tertiary)
        #expect(p.accessibilityLabelKey == "dashboard.intakesSheet.status.upcoming")
    }

    /// The future guard is opt-in: a `.taken` row that is NOT future (the
    /// default) still renders the canonical checkmark, so the existing
    /// status-only contract is unchanged.
    @Test("DOSE-SAFETY: non-future taken still resolves to the checkmark (default unchanged)")
    func nonFutureTakenStillCheckmark() {
        let p = Presentation.resolve(status: .taken, isFutureScheduled: false)
        #expect(p.symbolName == "checkmark.circle.fill")
        #expect(p.tint == Tint.statusOK)
        // The default-arg call (status-only) must agree with the explicit false.
        #expect(Presentation.resolve(status: .taken) == p)
    }
}
