import Foundation

/// **#190 5.4 and 20:09 — the stale date and the local state changes of a
/// medication Live Activity.**
///
/// The `end` push can travel through the relay and get lost, so a local
/// update never leaves the Activity without a stale date. With the server's
/// window on the today row the stale date is `missedAfter`, the instant the
/// dose counts as missed; a stale Activity says "Check status", never "due".
/// Between the updates the app schedules the next state change on the
/// window's instants (`dueAt`, `overdueSince`, `missedAfter`), not by polling.
/// A server without the window keeps the fallback of one hour after the due
/// time.
extension MedicationLiveActivityPlan {
    /// Only for a server that sends no window.
    static let intakeWindow: TimeInterval = 60 * 60

    static func staleDate(countdownTarget: Date, now: Date, band: ServerDoseState?) -> Date {
        let end = band?.missedAfter ?? countdownTarget.addingTimeInterval(intakeWindow)
        return max(end, now)
    }

    /// The next instant at which the dose changes its state locally, `nil`
    /// when none lies ahead or the row has no window.
    static func nextTransition(band: ServerDoseState?, now: Date) -> Date? {
        guard let band else { return nil }
        return [band.dueAt, band.overdueSince, band.missedAfter].compactMap(\.self).filter { $0 > now }.min()
    }

    /// The overdue styling at `now`, from the same window the cards grade by;
    /// `fallback` when the row has none.
    static func isOverdue(band: ServerDoseState?, now: Date, fallback: Bool) -> Bool {
        guard let phase = band?.phase(at: now) else { return fallback }
        return phase == .overdue || phase == .missed
    }
}
