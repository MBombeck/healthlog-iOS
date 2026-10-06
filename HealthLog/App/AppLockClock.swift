import Foundation
import SwiftUI

/// J1 / F3 — when the biometric app lock is due. `RootView` owns one of these
/// as `@State` and asks it on every scene-phase change and every auth-phase
/// change; the view only turns its answers into `locked = true` +
/// `tryUnlock()`. Pure value type so both rules are testable without a scene.
///
/// **Rule 1 — only a real trip to the background starts the clock.** Before
/// J1 `RootView` stamped the clock on `.inactive` too. `.inactive` is what a
/// system dialog on top of the app produces (notification permission, the
/// HealthKit sheet, Control Center, a Face ID prompt of another app), and the
/// app never left the screen. A permission dialog left open for more than the
/// 30-second grace period therefore demanded Face ID the moment it closed —
/// in the middle of onboarding, in front of App Review. Now only
/// `.background` stamps, and only while the lock can apply at all.
///
/// **Rule 2 — no lock for a person who just signed in.** The cold-launch lock
/// exists for a launch that *resumes* a stored session: nobody proved who is
/// holding the phone. A person who walked through onboarding in this process
/// just typed the password (or chose standalone), so asking for Face ID on
/// the first frame of the dashboard only interrupts them. The initial lock
/// therefore fires only when the process reaches an unlock-eligible phase
/// without having shown the sign-in flow first. Background → foreground after
/// the grace period still locks as before.
///
/// **Update path.** Nothing here is persisted and the setting
/// (`SettingsStore.biometricLockEnabled`) is read as it is: an installation
/// with "lock on" still locks on every cold launch with a stored session and
/// after every background trip longer than the grace period.
struct AppLockClock: Equatable {
    /// Background pause below this stays unlocked.
    static let defaultGracePeriod: TimeInterval = 30

    private(set) var backgroundedAt: Date?
    /// The process has shown the pre-auth flow (`.unauthenticated` /
    /// `.authenticating`), i.e. the person signed in during this launch.
    private(set) var sawSignInFlow = false
    /// The initial-launch decision has been taken (locked or waived).
    private(set) var initialDecisionTaken = false

    let gracePeriod: TimeInterval

    init(gracePeriod: TimeInterval = AppLockClock.defaultGracePeriod) {
        self.gracePeriod = gracePeriod
    }

    /// The auth phase settled on a new value. Returns `true` when the view
    /// must lock now (the cold-launch lock).
    mutating func authPhaseChanged(to phase: AuthStore.Phase, lockEnabled: Bool) -> Bool {
        switch phase {
        case .unauthenticated, .authenticating:
            sawSignInFlow = true
            return false
        case .unknown:
            return false
        case .authenticated, .standalone:
            guard lockEnabled, !initialDecisionTaken else { return false }
            initialDecisionTaken = true
            // Rule 2 — a sign-in in this process is proof enough.
            return !sawSignInFlow
        }
    }

    /// The scene phase changed. Returns `true` when the view must lock now.
    ///
    /// - Parameters:
    ///   - eligible: `AuthStore.Phase.isUnlockEligible` right now.
    ///   - lockEnabled: the user's setting.
    ///   - lockBusy: the lock is already shown or Face ID is in flight — its
    ///     own system sheet makes the scene inactive and must not re-arm it.
    mutating func scenePhaseChanged(
        to scenePhase: ScenePhase,
        now: Date,
        eligible: Bool,
        lockEnabled: Bool,
        lockBusy: Bool
    ) -> Bool {
        switch scenePhase {
        case .background:
            // Rule 1 — the only phase that starts the clock. Not during
            // onboarding: a stamp from there would lock the first foreground
            // after sign-in.
            guard eligible, lockEnabled, !lockBusy else { return false }
            backgroundedAt = now
            return false
        case .inactive:
            // Rule 1 — a dialog over the app is not "away".
            return false
        case .active:
            guard eligible, lockEnabled else {
                backgroundedAt = nil
                return false
            }
            guard let since = backgroundedAt else { return false }
            // Consume the stamp either way, so a fast scene-phase cycle
            // cannot fire twice.
            backgroundedAt = nil
            return now.timeIntervalSince(since) > gracePeriod
        @unknown default:
            return false
        }
    }

    /// The person unlocked; no pending re-lock survives it.
    mutating func didUnlock() {
        backgroundedAt = nil
    }
}
