import Foundation

/// **W-FOCUS-FILTER (v0.15.2)** — the app-side mirror of the HealthLog *Focus
/// filter* config the user attaches to a system Focus (Sleep, Work, …).
///
/// **What the filter does.** While the Focus is on, HealthLog holds back its
/// *routine* local reminders — medication local-backups, the evening mood
/// nudge, preventive-care (Vorsorge) reminders, low-supply heads-ups — and,
/// optionally, the proactive coach cadence cards. Urgent health escalations
/// (critical alerts + the illness "seek care" `SYSTEM_ALERT`) are **never**
/// suppressed — that is a hard safety invariant (see ``FocusFilterSuppression``).
///
/// **Source of truth = the system.** iOS hands the active config to the
/// ``HealthLogFocusFilterIntent`` while the Focus is on and clears it when the
/// Focus turns off. The intent persists the active config here; the delivery /
/// scheduling path reads it. We never poll the Focus state ourselves.
///
/// **Storage = shared App Group `UserDefaults`.** The config is a tiny,
/// non-PHI UI preference (two bools + an active flag). It lives in the shared
/// suite so both the app process and the Focus-filter intent's lightweight
/// execution context read/write the same value. No health data, no tokens —
/// nothing PHI ever touches this surface.
public struct FocusFilterConfig: Sendable, Equatable, Codable {
    /// `true` while a HealthLog Focus filter is attached to a *currently active*
    /// Focus. Set by the intent when the system activates the filter; cleared
    /// when the Focus turns off (the intent's config is removed → we clear).
    public var isActive: Bool

    /// Hold back routine (non-critical) reminders while the Focus is on. Default
    /// **on** when the filter is added — the whole point of attaching it.
    public var suppressNonCriticalReminders: Bool

    /// Also pause the proactive coach cadence suggestion cards while the Focus
    /// is on. Default **on** so a "quiet" Focus is genuinely quiet; the user can
    /// untick it in the Focus filter config to keep coach nudges flowing.
    public var pauseCoachNudges: Bool

    public init(
        isActive: Bool = false,
        suppressNonCriticalReminders: Bool = true,
        pauseCoachNudges: Bool = true
    ) {
        self.isActive = isActive
        self.suppressNonCriticalReminders = suppressNonCriticalReminders
        self.pauseCoachNudges = pauseCoachNudges
    }

    /// The neutral "no filter active" config — nothing is held back.
    public static let inactive = FocusFilterConfig(
        isActive: false,
        suppressNonCriticalReminders: true,
        pauseCoachNudges: true
    )

    /// `true` when routine reminders should be held back right now.
    public var suppressesRoutineReminders: Bool {
        isActive && suppressNonCriticalReminders
    }

    /// `true` when proactive coach nudges should be held back right now.
    public var suppressesCoachNudges: Bool {
        isActive && suppressNonCriticalReminders && pauseCoachNudges
    }
}

/// **W-FOCUS-FILTER** — shared App Group store for ``FocusFilterConfig``.
///
/// Reads/writes the JSON-encoded config under one key in the shared suite so
/// the app + the Focus-filter intent agree on the live value. Defaults to
/// ``FocusFilterConfig/inactive`` when nothing is written (no filter attached
/// to any Focus, or the suite is unavailable in tests / macOS).
public enum FocusFilterConfigStore {
    /// UserDefaults key inside the shared App Group suite. Versioned so a future
    /// schema change can migrate forward without a stale-decode crash.
    static let configKey = "hl.focusFilter.config.v1"

    /// The shared App Group suite, falling back to `.standard` when the group
    /// container is unavailable (unit tests / macOS / un-provisioned build).
    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: WidgetAppGroup.identifier) ?? .standard
    }

    /// The current config, or ``FocusFilterConfig/inactive`` when none is set.
    public static func current(defaults: UserDefaults = sharedDefaults()) -> FocusFilterConfig {
        guard let data = defaults.data(forKey: configKey),
              let config = try? JSONDecoder().decode(FocusFilterConfig.self, from: data) else
        {
            return .inactive
        }
        return config
    }

    /// Persist the active config (the intent calls this when the Focus turns on
    /// or its config changes).
    public static func set(_ config: FocusFilterConfig, defaults: UserDefaults = sharedDefaults()) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKey)
    }

    /// Clear back to inactive (the intent calls this when the Focus turns off).
    /// We persist an explicit *inactive* config rather than removing the key so
    /// a reader never has to distinguish "never set" from "explicitly off".
    public static func clear(defaults: UserDefaults = sharedDefaults()) {
        set(.inactive, defaults: defaults)
    }
}
