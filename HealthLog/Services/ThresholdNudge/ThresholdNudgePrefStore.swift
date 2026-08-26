import Foundation

/// **W-THRESHOLD-NUDGE — device-local opt-in for the out-of-range nudge.**
///
/// **Default OFF (opt-in).** The nudge is the app's most regulatory-sensitive
/// surface, so it never fires unless the user explicitly turns it on in
/// Settings → Notifications. The toggle copy sets expectations: what it does,
/// that it is NOT medical advice, and that it only uses ranges the user / their
/// own data define.
///
/// **Storage tier — UserDefaults (device-local).** This is a per-device
/// notification preference the server does not own; it holds no PHI (a single
/// Bool). Mirrors the `LockScreenPrivacy` precedent.
enum ThresholdNudgePrefStore {
    /// UserDefaults key for the out-of-range nudge opt-in.
    static let enabledKey = "hl.threshold.outOfRangeNudge.enabled.v1"

    /// `true` when the user has opted in to the out-of-range nudge. Defaults to
    /// `false` (off) when never written.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Persist the opt-in choice.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }
}
