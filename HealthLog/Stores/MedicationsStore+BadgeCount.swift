import Foundation

/// **v0.6.1.3 Y4.1 — App-Badge source-of-truth for fällige + verpasste meds.**
///
/// The Home-screen app icon surfaces a numeric badge that counts the
/// medication doses the operator still needs to act on. The source of
/// truth lives on `MedicationsStore` so a single recompute pass
/// produces the same number every consumer (BadgeService, willPresent
/// foreground hook, BG refresh) reads.
///
/// **Counting rule — operator-explicit:**
/// 1. Walk `derivedTodayIntakes` (the union of server-emitted +
///    synthesised placeholder rows the rest of the medication UI
///    already drives off — keeps the badge in lock-step with the
///    "Anstehende Einnahmen" surface).
/// 2. A dose counts as **fällig** (due) when its window is open: the
///    `scheduledAt` lies in the past **or** within the next 15 minutes
///    AND the row is `pending` AND the dose hasn't been snoozed
///    forward of `now`.
/// 3. A dose counts as **verpasst** (missed) when `scheduledAt` lies
///    more than 15 minutes in the past AND the row is still `pending`.
///    Missed is a strict subset of due — the badge collapses both
///    semantically because both demand the operator's attention.
/// 4. Snoozed rows are **excluded** until the snooze elapses
///    (`snoozedUntil <= now` ⇒ snooze has expired ⇒ counts as due
///    again). Taken / skipped rows never count.
///
/// **Why merge fällig + verpasst into one count?** The badge is a
/// single integer surface. Splitting it would mean the operator sees
/// "3" but can't tell whether three doses are coming up soon or three
/// were missed an hour ago. The "Überfällig" banner on Home already
/// carries the strict-missed-only count for the user-facing strip; the
/// badge stays the catch-all "you have N doses pending" signal.
///
/// `nonisolated` so the badge service can call this off the MainActor
/// without dragging the store's default isolation into every recompute
/// site; the pure-helper splits out the math from the property reads.
public extension MedicationsStore {
    /// Number of medication doses the operator still needs to act on.
    /// Reads `derivedTodayIntakes` (which respects the synth-placeholder
    /// merge) and applies the due-or-missed predicate documented above.
    /// Default `at: .now` so the call-site doesn't have to thread the
    /// clock; tests override the parameter for ladder verification.
    func dueOrMissedCount(at moment: Date = .now) -> Int {
        Self.computeDueOrMissedCount(
            intakes: derivedTodayIntakes,
            now: moment
        )
    }

    /// Pure-function seam consumed by `dueOrMissedCount` + the unit
    /// tests. Deterministic given `(intakes, now)`.
    ///
    /// **Grace window:** the 15-minute `dueGraceSeconds` lets a dose
    /// scheduled for 08:00 register as "due" between 07:45 and the next
    /// status mutation. Without it, an operator who taps Genommen at
    /// 07:46 would still see the badge tick down a minute later when
    /// the dose's scheduled minute arrives. The grace is the same
    /// window the reminder-worker honours server-side for the RED-phase
    /// banner, so badge + banner converge.
    nonisolated static func computeDueOrMissedCount(
        intakes: [MedicationIntake],
        now: Date,
        dueGraceSeconds: TimeInterval = 15 * 60
    ) -> Int {
        let upperBound = now.addingTimeInterval(dueGraceSeconds)
        return intakes.lazy
            .filter { $0.status == .pending }
            .filter { intake in
                // Snoozed-forward rows stay invisible to the badge
                // until the snooze elapses. `snoozedUntil > now` means
                // the operator chose to defer this dose; respect that.
                if let snoozedUntil = intake.snoozedUntil, snoozedUntil > now {
                    return false
                }
                // Dose is "due" the moment its window opens — 15 min
                // before the scheduled minute — and stays due until
                // explicitly marked taken / skipped (or snoozed).
                return intake.scheduledAt <= upperBound
            }
            .count
    }
}
