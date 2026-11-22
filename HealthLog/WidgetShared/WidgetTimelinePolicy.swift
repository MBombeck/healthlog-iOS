import Foundation

/// **Pure timeline-refresh decisions for the widgets.**
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

    // MARK: - Staleness

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

    /// **#189 (7)** — how long before its due time a snapshot may have been
    /// written and still be trusted once that time has come. A dose can be
    /// taken elsewhere (pill box, Telegram) around its slot; a snapshot from
    /// the evening before cannot know. Past this lead the due dose shows no
    /// button until the app has written a newer snapshot.
    public static let dueSnapshotMaxLead: TimeInterval = 2 * 60 * 60

    /// `true` when the next dose must not be acted on at `now`: the snapshot
    /// is older than ``nextDoseStaleThreshold``, or the dose is due and the
    /// snapshot predates it by more than ``dueSnapshotMaxLead``.
    public static func isNextDoseUntrusted(generatedAt: Date, scheduledAt: Date?, now: Date) -> Bool {
        if isNextDoseStale(generatedAt: generatedAt, now: now) { return true }
        guard let scheduledAt, now >= scheduledAt else { return false }
        return scheduledAt.timeIntervalSince(generatedAt) > dueSnapshotMaxLead
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

    // MARK: - Two-tap confirm frames

    /// The armed "Confirm?" state as timeline frames: armed from `now`, plain
    /// again at the moment the confirm window closes. WidgetKit shows a frame
    /// no earlier than its date, so the button can never read "Taken" while the
    /// intent would still treat the next tap as the confirming one. A reload
    /// request at the window edge carried no such guarantee.
    public static func pendingConfirmFrames(
        now: Date,
        armedAt: Date?,
        window: TimeInterval
    ) -> [(date: Date, armed: Bool)] {
        guard let armedAt else { return [(now, false)] }
        let closes = armedAt.addingTimeInterval(window)
        guard closes > now else { return [(now, false)] }
        return [(now, true), (closes, false)]
    }

    // MARK: - Snapshot stamp

    /// How old `generatedAt` may grow while the medication content stays the
    /// same before the writer stamps it anew.
    public static let snapshotStampRefreshInterval: TimeInterval = 60 * 60

    /// `true` when an unchanged snapshot still needs a fresh `generatedAt`.
    /// The stamp is what the widgets read as "the app looked at this", so an
    /// app that ran and found nothing new must still move it forward, or a
    /// quiet day turns into "open the app".
    public static func needsFreshStamp(
        previous: Date,
        now: Date,
        calendar: Calendar = .current,
        interval: TimeInterval = snapshotStampRefreshInterval
    ) -> Bool {
        if !calendar.isDate(previous, inSameDayAs: now) { return true }
        return now.timeIntervalSince(previous) >= interval
    }
}
