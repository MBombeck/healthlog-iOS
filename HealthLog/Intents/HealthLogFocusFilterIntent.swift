import AppIntents
import Foundation

/// **W-FOCUS-FILTER (v0.15.2)** — the HealthLog *Focus filter* the user attaches
/// to a system Focus (Sleep, Work, Personal Time, …) in **Settings → Focus →
/// [a Focus] → Add Filter → HealthLog**.
///
/// **What it does.** While that Focus is on, HealthLog holds back its routine
/// reminders — medication local-backups, the evening mood nudge, preventive-care
/// reminders, low-supply heads-ups — and (optionally) the proactive coach
/// nudges. **Urgent health alerts still come through**: critical medication
/// alarms and illness "seek care" escalations are never suppressed (the safety
/// invariant lives in ``FocusFilterSuppression``).
///
/// **How the system drives it.** iOS instantiates this intent with the user's
/// chosen parameter values and calls ``perform()`` whenever the Focus turns on
/// (or the config changes). We persist the active config into the shared App
/// Group (``FocusFilterConfigStore``) so the app's local-scheduling + coach
/// paths read it. When the Focus turns off, the system sets `current = nil` and
/// we clear back to inactive on the next app foreground (see
/// ``AppContainer`` reconcile) — and, defensively, the gate reads a *fresh*
/// config on every `add()`, so a stale "active" can never outlive the Focus by
/// more than one scheduling tick.
///
/// **No PHI.** The config is two bools + an active flag — a pure UI preference.
/// No health data, no tokens, nothing PHI ever rides this surface.
struct HealthLogFocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "focus.filter.title"

    static let description = IntentDescription("focus.filter.description")

    /// Hold back routine (non-critical) reminders while the Focus is on. Default
    /// **on** — the whole reason to attach the filter. Urgent health alerts are
    /// exempt regardless of this toggle.
    @Parameter(title: "focus.filter.param.suppressReminders.title", default: true)
    var suppressNonCriticalReminders: Bool

    /// Also pause the proactive coach nudge cards + dot while the Focus is on.
    /// Default **on** so a quiet Focus is genuinely quiet.
    @Parameter(title: "focus.filter.param.pauseCoach.title", default: true)
    var pauseCoachNudges: Bool

    /// The summary shown in the Focus-filter row in Settings. Reflects the
    /// user's current toggle choices so the configured behaviour is legible at a
    /// glance.
    var displayRepresentation: DisplayRepresentation {
        let subtitleKey: LocalizedStringResource = suppressNonCriticalReminders
            ? (pauseCoachNudges
                ? "focus.filter.summary.remindersAndCoach"
                : "focus.filter.summary.remindersOnly")
            : "focus.filter.summary.off"
        return DisplayRepresentation(
            title: "focus.filter.title",
            subtitle: subtitleKey
        )
    }

    func perform() async throws -> some IntentResult {
        // iOS calls this while the Focus is ON with the user's chosen values.
        // Persist the active config so the local-scheduling + coach paths read
        // it; clearing happens when the system tears the filter down (and the
        // gate re-reads on every add, so a held-back state never outlives the
        // Focus). No PHI — two bools + an active flag.
        let config = FocusFilterConfig(
            isActive: true,
            suppressNonCriticalReminders: suppressNonCriticalReminders,
            pauseCoachNudges: pauseCoachNudges
        )
        FocusFilterConfigStore.set(config)
        return .result()
    }
}
