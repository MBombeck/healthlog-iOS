import Foundation

/// **CU-25 (#72) — the reconciliation moment: flow logged without a period.**
///
/// Logging menstrual flow on a day and marking a period start are two different
/// acts. A cycle span is created ONLY by `POST /api/cycle/period`
/// (`src/app/api/cycle/period/route.ts:99`); a day log is merely attached to the
/// latest span starting on or before its date
/// (`src/lib/cycle/cycle-attribution.ts:10` — "latest `startDate <= date`, else
/// null"). So flow recorded without a period start is filed against the
/// PREVIOUS cycle: the record then holds one very long cycle with bleeding
/// inside it, the prediction stays anchored to the old start, and everything
/// downstream reads "later than usual".
///
/// The server carries no reconciliation hint — there is no endpoint or response
/// field meaning "this day log has flow but no active period" (verified against
/// the server repo). So the client has to notice, and the honest response is to
/// **ask the user once** rather than file it silently.
///
/// "Once" is enforced structurally, not by a counter: only the FIRST bleeding
/// day of a run asks. Logging days 2…n of the same period never asks again,
/// because the preceding day already carries bleeding. A declined answer is
/// remembered for that date (in memory on ``CycleStore``, never persisted — a
/// date on which someone declined a period prompt is cycle data) so re-opening
/// the same day to edit it does not re-ask.
///
/// Pure + `nonisolated static` so the "exactly one prompt" contract is
/// unit-testable without a SwiftUI host.
public enum CycleFlowReconciliation {
    /// Should the capture sheet ask whether a period started before it saves?
    ///
    /// - Parameters:
    ///   - flow: the flow level about to be written.
    ///   - periodAction: the pending period choice in the form. Any explicit
    ///     choice means the user has already answered the question herself.
    ///   - date: the day key (`YYYY-MM-DD`) being written.
    ///   - days: the cached calendar days (server-labelled).
    ///   - declined: day keys the user already answered "no" for this session.
    public nonisolated static func shouldAskPeriodStarted(
        flow: CycleFlowLevel,
        periodAction: CyclePeriodAction?,
        date: String,
        days: [CalendarDayDTO],
        declined: Set<String>
    ) -> Bool {
        // Nothing to reconcile without bleeding — NONE is a valid "no flow" log.
        guard flow.isBleeding else { return false }
        // The user already made the call in the form; do not second-guess her.
        guard periodAction == nil else { return false }
        // Asked once for this day already, and told "no".
        guard !declined.contains(date) else { return false }

        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        // The server already labels this day menstrual → a span covers it, the
        // day log will be attributed correctly, there is nothing to ask.
        if byDate[date]?.phaseValue == .menstrual { return false }
        // Only the FIRST bleeding day of a run asks. Day 2…n of the same period
        // inherit the answer given on day 1 — this is what makes the prompt fire
        // exactly once instead of on every entry.
        let previous = CyclePredictionEngine.addDays(date, -1)
        if byDate[previous]?.flowLevel?.isBleeding == true { return false }
        return true
    }
}
