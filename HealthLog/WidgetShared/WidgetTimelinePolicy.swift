import Foundation

/// **v0.8.4 WWIDGET-2 — pure timeline-refresh decisions for the widgets.**
///
/// Extracted from the `TimelineProvider`s (which live in the extension and
/// can't be unit-tested from the app test target) into a shared
/// Foundation-only enum so the reload cadence is verifiable. The providers
/// are thin shells that read the App Group snapshot + call these.
public enum WidgetTimelinePolicy {
    /// Periodic backstop for the next-dose widget when no future dose
    /// anchors a precise reload (e.g. an overdue dose). 30 min.
    public static let nextDoseBackstop: TimeInterval = 30 * 60

    /// When WidgetKit should rebuild the next-dose timeline absent an
    /// app-driven reload: at the dose's scheduled instant if it's still in
    /// the future (so the countdown flips to "now"/overdue precisely),
    /// else the periodic backstop so an overdue dose doesn't sit stale.
    public static func nextDoseReload(
        after now: Date,
        scheduledAt: Date?
    ) -> Date {
        let backstop = now.addingTimeInterval(nextDoseBackstop)
        guard let scheduledAt, scheduledAt > now else { return backstop }
        return min(scheduledAt, backstop)
    }

    /// When the compliance widget should rebuild: the next local midnight,
    /// when "today's" taken/scheduled counts roll over. Falls back to a
    /// +6h reload if the calendar can't produce a start-of-tomorrow.
    public static func complianceReload(
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let startOfTomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        )
        return startOfTomorrow ?? now.addingTimeInterval(6 * 60 * 60)
    }

    // MARK: - Staleness (audit-v0162 M3)

    // The snapshot carries `generatedAt` precisely so a widget can tell when
    // the app last refreshed it. When iOS grants no BGTask (Low Power /
    // Background-App-Refresh off) across a weekend, the app may not run for
    // days — the 30-min timeline backstop then just re-reads the SAME stale
    // snapshot. Without a staleness cutoff the Lock-Screen next-dose widget
    // keeps showing Friday's dose as "fällig um HH:mm" with a LIVE "Genommen"
    // button that would record an intake against a slot that has long passed,
    // and the compliance ring paints Friday's counts as today's. These rules
    // are the single source of truth the providers + watch complications apply
    // so no surface renders — or lets the user act on — an untrustworthy slot.

    /// How old a snapshot's `nextDose` may be before it is no longer trusted.
    ///
    /// **16 h.** A medication cadence means a "next dose" that was resolved
    /// more than ~⅔ of a day ago is untrustworthy: its scheduled slot has very
    /// likely already passed (recorded or missed) without the app getting a
    /// chance to rewrite the snapshot. 16 h is deliberately > a normal
    /// overnight gap (an evening snapshot naming tomorrow's morning dose stays
    /// valid through the night, so the widget doesn't flap) yet comfortably
    /// < 24 h, so a Friday-evening snapshot is flagged stale by Saturday
    /// mid-day — before the widget can mislead across a no-refresh weekend.
    public static let nextDoseStaleThreshold: TimeInterval = 16 * 60 * 60

    /// `true` when a snapshot generated at `generatedAt` is too old for its
    /// `nextDose` to be trusted. The provider must then render the neutral
    /// "open the app" state and SUPPRESS the interactive intent button, so no
    /// dose is ever recorded against a stale slot.
    public static func isNextDoseStale(
        generatedAt: Date,
        now: Date,
        threshold: TimeInterval = nextDoseStaleThreshold
    ) -> Bool {
        now.timeIntervalSince(generatedAt) > threshold
    }

    /// Belt-and-suspenders age cap for the compliance surface (the local-day
    /// check below is the primary rule). 24 h — one full day.
    public static let complianceStaleMaxAge: TimeInterval = 24 * 60 * 60

    /// `true` when the snapshot's compliance counts can no longer be shown as
    /// "today's". Compliance is a per-local-day figure, so the cut is at the
    /// **local-day rollover**: a snapshot generated on an earlier local day
    /// (the classic midnight-rollover / weekend case) paints yesterday's ring
    /// as today's and is treated as stale. A same-day snapshot older than
    /// ``complianceStaleMaxAge`` (should not normally happen within a day) is
    /// also treated as stale as a guard. Uses the caller-supplied calendar so
    /// the day boundary honours the user's time zone (never a wall-clock read).
    public static func isComplianceStale(
        generatedAt: Date,
        now: Date,
        calendar: Calendar = .current,
        maxAge: TimeInterval = complianceStaleMaxAge
    ) -> Bool {
        if !calendar.isDate(generatedAt, inSameDayAs: now) { return true }
        return now.timeIntervalSince(generatedAt) > maxAge
    }
}
