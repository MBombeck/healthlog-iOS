import Foundation
@testable import HealthLog
import Testing

/// **v0.6.1.3 Y4.1 — App-Badge count tests.**
///
/// Pins the `MedicationsStore.computeDueOrMissedCount` predicate at the
/// window boundaries the brief calls out: just-opened, mid-window,
/// just-closed, deeply-missed, snoozed-but-not-due-yet.
///
/// The pure-function seam takes `(intakes, now, dueGraceSeconds)` so
/// each test pins the wall-clock against a frozen moment, builds the
/// intake set against that moment, and asserts the count.
@Suite("MedicationsStore — due-or-missed count snapshot")
struct MedicationsStoreBadgeCountTests {
    /// Reference moment: 2026-05-23 12:00:00 UTC. Plain `Date(timeIntervalSince1970:)`
    /// so the test is wall-clock-independent.
    private let now = Date(timeIntervalSince1970: 1_716_465_600)

    /// 15 minutes — the default grace window the store uses.
    private let grace: TimeInterval = 15 * 60

    /// A dose scheduled exactly at `now` is in its open window — count = 1.
    @Test("Just-opened dose at now is due")
    func justOpenedDoseIsDue() {
        let intake = makeIntake(scheduledOffset: 0, status: .pending)
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 1)
    }

    /// A dose scheduled 5 minutes in the future, inside the 15-min
    /// grace, still counts as due (window is "open" early so the
    /// operator can act on a coming-up dose).
    @Test("Dose 5 min in the future, inside grace, is due")
    func futureDoseInsideGraceIsDue() {
        let intake = makeIntake(scheduledOffset: 5 * 60, status: .pending)
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 1)
    }

    /// A dose scheduled 20 minutes in the future is outside the grace
    /// window — no longer counted. Otherwise the badge would tick up
    /// while the operator is asleep before their morning Lisinopril.
    @Test("Dose 20 min in the future, outside grace, is NOT due")
    func futureDoseOutsideGraceIsNotDue() {
        let intake = makeIntake(scheduledOffset: 20 * 60, status: .pending)
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 0)
    }

    /// A dose scheduled an hour ago that the operator never marked is
    /// "missed" — still pending, still counts as due-or-missed.
    @Test("Deeply-missed dose still counts")
    func deeplyMissedDoseStillCounts() {
        let intake = makeIntake(scheduledOffset: -60 * 60, status: .pending)
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 1)
    }

    /// A snoozed dose that is still inside its snooze window does NOT
    /// count — the operator explicitly deferred this one.
    @Test("Snoozed-forward dose is NOT due")
    func snoozedDoseIsExcluded() {
        let intake = MedicationIntake(
            id: "snooze-1",
            medicationId: "lisinopril",
            scheduledAt: now.addingTimeInterval(-30 * 60),
            takenAt: nil,
            status: .pending,
            snoozedUntil: now.addingTimeInterval(20 * 60)
        )
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 0)
    }

    /// A snoozed dose whose snooze has elapsed (`snoozedUntil < now`)
    /// surfaces as due again — the snooze ran out, the operator should
    /// see the badge climb.
    @Test("Snoozed dose with elapsed snooze counts as due")
    func snoozedDoseWithElapsedSnoozeIsDue() {
        let intake = MedicationIntake(
            id: "snooze-2",
            medicationId: "lisinopril",
            scheduledAt: now.addingTimeInterval(-30 * 60),
            takenAt: nil,
            status: .pending,
            snoozedUntil: now.addingTimeInterval(-5 * 60)
        )
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 1)
    }

    /// Taken intakes never count, regardless of timing.
    @Test("Taken doses are excluded")
    func takenDoseIsExcluded() {
        let intake = makeIntake(scheduledOffset: -30 * 60, status: .taken)
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 0)
    }

    /// Skipped intakes never count either.
    @Test("Skipped doses are excluded")
    func skippedDoseIsExcluded() {
        let intake = makeIntake(scheduledOffset: -30 * 60, status: .skipped)
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [intake],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 0)
    }

    /// Mixed set: 2 missed pending + 1 taken + 1 future-outside-grace +
    /// 1 snoozed-forward → count is 2.
    @Test("Mixed set surfaces only pending past-due rows")
    func mixedSetCountsOnlyPendingPastDue() {
        let intakes: [MedicationIntake] = [
            makeIntake(scheduledOffset: -60 * 60, status: .pending), // missed
            makeIntake(scheduledOffset: -30 * 60, status: .pending), // missed
            makeIntake(scheduledOffset: -45 * 60, status: .taken), // excluded
            makeIntake(scheduledOffset: 30 * 60, status: .pending), // future, outside grace
            MedicationIntake(
                id: "snoozed-future",
                medicationId: "x",
                scheduledAt: now.addingTimeInterval(-10 * 60),
                takenAt: nil,
                status: .pending,
                snoozedUntil: now.addingTimeInterval(30 * 60)
            )
        ]
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: intakes,
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 2)
    }

    /// Empty set returns zero — the badge clears when there is nothing
    /// to do.
    @Test("Empty intake list reports zero")
    func emptyIntakesReportZero() {
        let count = MedicationsStore.computeDueOrMissedCount(
            intakes: [],
            now: now,
            dueGraceSeconds: grace
        )
        #expect(count == 0)
    }

    // MARK: - Helpers

    private func makeIntake(
        scheduledOffset: TimeInterval,
        status: IntakeStatus
    ) -> MedicationIntake {
        MedicationIntake(
            id: "intake-\(scheduledOffset)-\(status.rawValue)",
            medicationId: "lisinopril",
            scheduledAt: now.addingTimeInterval(scheduledOffset),
            takenAt: status == .taken ? now : nil,
            status: status,
            snoozedUntil: nil
        )
    }
}
