import Foundation

/// **v0.8.4 WWIDGET-1 — pure Live-Activity lifecycle decisions.**
///
/// The `ActivityKit`-touching controller (``MedicationLiveActivityController``)
/// is hard to unit-test because `Activity.request` needs a live OS surface.
/// This enum holds the **pure** decisions that drive it — given the
/// medications + today's intakes + a clock, which dose (if any) deserves a
/// Live Activity right now, and what status/end-action a given intake maps
/// to. Unit tests cover this directly; the controller is a thin imperative
/// shell over these decisions.
///
/// Deliberately `Foundation`-only and free of `ActivityKit` so it compiles
/// in plain `swift test` and in the app target identically.
enum MedicationLiveActivityPlan {
    /// A concrete instruction to surface a Live Activity for one dose.
    struct DoseActivity: Equatable {
        let medicationId: String
        let medicationName: String
        let doseText: String
        let scheduledFireDate: Date
        /// **W-B183** — the server-gated overdue verdict for this dose, computed
        /// in the app process via ``isOverdue(medication:now:calendar:)`` so the
        /// widget extension (which cannot call the server) renders danger styling
        /// from the SAME truth the in-app card uses, not its own
        /// `Date.now > countdownTarget`. Defaults `false` for back-compat callers.
        var isOverdue: Bool = false
    }

    /// Window (seconds) **before** the scheduled fire time at which the
    /// Live Activity should appear. A dose due in > this many seconds is
    /// not yet surfaced (avoids an all-day countdown for a 22:00 dose at
    /// 07:00). Default: 2 h — long enough that the banner is genuinely a
    /// "coming up" affordance, short enough not to clutter the Lock Screen.
    static let leadWindow: TimeInterval = 2 * 60 * 60

    /// How long **after** the scheduled time a still-untaken dose keeps its
    /// Live Activity before it is considered expired and ended. Default
    /// 3 h mirrors the missed-dose grace the reminder pipeline uses.
    static let overdueGrace: TimeInterval = 3 * 60 * 60

    /// Pick the single dose (if any) that should currently own a Live
    /// Activity: the soonest dose whose scheduled fire time falls inside
    /// `[now - overdueGrace, now + leadWindow]`, that is not already
    /// taken/skipped in today's intakes, whose medication has notifications
    /// enabled + is active, **and** whose per-medication Live-Activity
    /// toggle is on.
    ///
    /// **Per-medication gate (v0.8.5 WFIX-LA):** `isLiveActivityEnabled` is a
    /// pure predicate keyed by medication id (backed by
    /// `DeliveryPreferencesStore.enabledPredicate(for: .liveActivity)`, default
    /// OFF). Only medications the user
    /// explicitly opted in surface a Live Activity — time-critical meds
    /// yes, the long tail no. Defaults to "all enabled" so existing callers
    /// / tests that don't pass it keep their prior behaviour; the live
    /// reconcile path always passes the real preference snapshot.
    ///
    /// Returns `nil` when nothing qualifies — the caller ends any running
    /// Activity in that case.
    static func doseToSurface(
        medications: [Medication],
        intakes: [MedicationIntake],
        now: Date,
        calendar: Calendar = .current,
        isLiveActivityEnabled: (String) -> Bool = { _ in true }
    ) -> DoseActivity? {
        var best: (date: Date, activity: DoseActivity)?
        for medication in medications
            where medication.active
            && medication.notificationsEnabled
            && isLiveActivityEnabled(medication.id)
        {
            guard let occurrence = nextOrCurrentOccurrence(
                medication: medication,
                now: now,
                calendar: calendar
            ) else { continue }
            let fire = occurrence.at

            // Inside the surface window? The overdue cutoff is per-occurrence:
            // a dose stays surfaced until its own `graceUntil` (driven by the
            // schedule's `reminderGraceMinutes`), not a hardcoded global grace.
            if fire > now.addingTimeInterval(leadWindow) { continue }
            if now > occurrence.graceUntil { continue }

            // Already acted on for this scheduled instant?
            if isResolved(medicationId: medication.id, scheduledFor: fire, intakes: intakes, calendar: calendar) {
                continue
            }

            let activity = DoseActivity(
                medicationId: medication.id,
                medicationName: medication.name,
                doseText: medication.dose,
                scheduledFireDate: fire,
                isOverdue: isOverdue(medication: medication, now: now, calendar: calendar)
            )
            if let current = best {
                if fire < current.date { best = (fire, activity) }
            } else {
                best = (fire, activity)
            }
        }
        return best?.activity
    }

    /// **v0.10 R1 §3.6 — the nearest occurrence to surface for a medication,
    /// across every `ScheduleEntry`, via `MedicationRecurrenceEngine`.**
    ///
    /// Replaces the prior day-walk: for each entry we ask the engine for the
    /// next occurrence after `now - leadWindow` so a currently-overdue dose
    /// (still inside its per-schedule grace) is surfaced, and pick the one
    /// closest to `now`. Rolling surfaces its single overdue/next slot;
    /// one-shot surfaces once. Returns `nil` when nothing is schedulable.
    static func nextOrCurrentOccurrence(
        medication: Medication,
        now: Date,
        calendar: Calendar = .current
    ) -> MedicationRecurrenceEngine.Occurrence? {
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: calendar.timeZone,
            now: now
        )
        // Look back far enough that a just-overdue dose (up to a day) is still
        // returned; the per-occurrence grace gate in `doseToSurface` then
        // decides whether it is still worth showing.
        let lookback = now.addingTimeInterval(-overdueGrace - leadWindow)
        var best: MedicationRecurrenceEngine.Occurrence?
        for entry in medication.schedule.entries {
            guard let occurrence = MedicationRecurrenceEngine.nextOccurrence(
                after: lookback,
                entry: entry,
                context: context
            ) else { continue }
            if let current = best {
                if closer(to: now, between: current.at, and: occurrence.at) == occurrence.at {
                    best = occurrence
                }
            } else {
                best = occurrence
            }
        }
        return best
    }

    /// **Deprecated shim** — the legacy day-walk fire-date resolver, kept for
    /// any caller still on the flat schedule surface. Prefer
    /// ``nextOrCurrentOccurrence(medication:now:calendar:)``.
    static func nextOrCurrentFireDate(
        schedule: MedicationSchedule,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard !schedule.times.isEmpty else { return nil }
        let sortedTimes = schedule.times.sorted()
        var candidate: Date?
        for offset in -1 ... 14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
                continue
            }
            guard schedule.fires(on: day, calendar: calendar) else { continue }
            for time in sortedTimes {
                guard let instant = calendar.date(
                    bySettingHour: time.hour,
                    minute: time.minute,
                    second: 0,
                    of: day
                ) else { continue }
                if instant < now.addingTimeInterval(-overdueGrace) { continue }
                candidate = closer(to: now, between: candidate, and: instant)
            }
        }
        return candidate
    }

    /// Prefer a currently-due/overdue instant over a far-future one: pick
    /// the instant whose absolute distance to `now` is smallest (so a
    /// dose due 1 h ago beats one due 23 h from now). On an exact tie —
    /// e.g. a 07:00 and a 09:00 dose viewed at 08:00 — the **upcoming**
    /// instant wins, because a not-yet-due dose is the more useful thing to
    /// surface than a just-missed one.
    private static func closer(to now: Date, between current: Date?, and next: Date) -> Date {
        guard let current else { return next }
        let curDist = abs(current.timeIntervalSince(now))
        let nextDist = abs(next.timeIntervalSince(now))
        if curDist == nextDist {
            // Tie → prefer the future (upcoming) instant.
            return next.timeIntervalSince(now) >= 0 ? next : current
        }
        return curDist <= nextDist ? current : next
    }

    /// Whether today's intakes already record a taken/skipped/snoozed
    /// resolution for `(medicationId, scheduledFor)`. Matching is by
    /// medication id + same calendar minute so a server `scheduledAt`
    /// that differs by seconds still matches.
    static func isResolved(
        medicationId: String,
        scheduledFor: Date,
        intakes: [MedicationIntake],
        calendar: Calendar = .current
    ) -> Bool {
        intakes.contains { intake in
            guard intake.medicationId == medicationId else { return false }
            guard intake.status == .taken || intake.status == .skipped else { return false }
            return calendar.isDate(
                intake.scheduledAt,
                equalTo: scheduledFor,
                toGranularity: .minute
            )
        }
    }

    /// **W-B183 (dose-safety coherence)** — the server-gated overdue verdict the
    /// Live Activity must carry into the widget extension.
    ///
    /// Starts with the server-authoritative `nextDueOverdue` fallback for
    /// cadences the local grid cannot see. Otherwise the local current-window
    /// reducer supplies the severity while honouring a strictly-future server
    /// due, so rolling/weekly off-days stay neutral.
    ///
    /// Only `.late` / `.veryLate` are danger affordances. `.inWindow` means
    /// the dose is actionable but still on time, so the widget must keep its
    /// neutral countdown styling — never derive danger from the bare
    /// `Date.now > countdownTarget` value that bypassed the server gate.
    static func isOverdue(
        medication: Medication,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        if MedicationWindowStatus.serverOverdueFallback(
            medication: medication,
            now: now
        ) != nil {
            return true
        }
        let status = MedicationWindowStatus.reduce(
            medication: medication,
            now: now,
            timeZone: calendar.timeZone
        )
        switch status {
        case .late, .veryLate:
            return true
        case .inWindow, nil:
            return false
        }
    }
}
