import Foundation

/// **W-B188 (AUDIT-SEC-b187 High — lock-screen PHI) — device-local privacy
/// opt-out for medication names on lock-screen surfaces.**
///
/// When ON, the medication-reminder notification (title + body) and the
/// medication Live Activity render a GENERIC label instead of the real drug
/// name / dose, so a stranger glancing at the locked phone cannot read a
/// sensitive (e.g. psychiatric / HIV) medication name. The action routing is
/// unaffected — the `medicationId` still travels in the notification
/// `userInfo` / the Live-Activity attributes, just not in the visible text.
///
/// **Default OFF** — the current behaviour (real name shown) is preserved
/// unless the user explicitly opts in, so no existing user sees a surprise
/// change.
///
/// **Storage tier — SHARED App-Group UserDefaults (device-local).** This is a
/// *this-device* lock-screen concern: the server cannot know which physical
/// device's lock screen a name surfaces on, so the flag lives in UserDefaults
/// per the project's storage rules (UI-prefs the server doesn't know). It holds
/// no PHI — only a single Bool.
///
/// **AUDIT-v0162 H2 — moved from `.standard` to the shared App-Group suite
/// (`group.dev.healthlog.app`).** The Notification Service Extension
/// (`NotificationService`) runs in a *separate process* and must read the same
/// opt-out the app writes; a per-process `.standard` domain is invisible across
/// the app↔appex boundary, so the flag now lives in the App-Group suite both
/// share. `migrateLegacyValueIfNeeded()` carries forward any value written to
/// `.standard` before this move.
enum LockScreenPrivacy {
    /// UserDefaults key for the "hide medication name on lock screen" opt-out.
    static let hideMedicationNameKey = "hl.privacy.hideMedicationNameOnLockScreen.v1"

    /// Shared App-Group identifier. Single source of truth is
    /// `WidgetAppGroup.identifier`; duplicated here as a bare constant so this
    /// type stays dependency-free and compiles into the Notification Service
    /// Extension without dragging the `WidgetShared` closure across the target
    /// boundary. MUST stay in lock-step with `WidgetAppGroup.identifier`.
    static let appGroupIdentifier = "group.dev.healthlog.app"

    /// The shared App-Group `UserDefaults` suite the app WRITES the opt-out to
    /// and the Notification Service Extension READS it from. Falls back to
    /// `.standard` only when the group container is unavailable (e.g. a unit
    /// test host or a build without the entitlement).
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// `true` when the user has opted in to hide medication names on
    /// lock-screen surfaces. Defaults to `false` (current behaviour).
    static func hideMedicationName(defaults: UserDefaults = LockScreenPrivacy.sharedDefaults) -> Bool {
        defaults.bool(forKey: hideMedicationNameKey)
    }

    /// Persist the opt-out choice.
    static func setHideMedicationName(_ hide: Bool, defaults: UserDefaults = LockScreenPrivacy.sharedDefaults) {
        defaults.set(hide, forKey: hideMedicationNameKey)
    }

    /// One-time migration: mirror a legacy value written to `.standard` (pre-
    /// v0141, before the flag moved to the App-Group suite the NSE reads) into
    /// the shared suite, so users who opted in before the extension existed keep
    /// their choice. No-op once the shared suite already holds a value. Called
    /// once at app launch (`HealthLogApp.init`).
    static func migrateLegacyValueIfNeeded(
        standard: UserDefaults = .standard,
        shared: UserDefaults = LockScreenPrivacy.sharedDefaults
    ) {
        guard shared.object(forKey: hideMedicationNameKey) == nil,
              let legacy = standard.object(forKey: hideMedicationNameKey) as? Bool else { return }
        shared.set(legacy, forKey: hideMedicationNameKey)
    }
}
