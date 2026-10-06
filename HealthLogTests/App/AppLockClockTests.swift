// J1 / F3 — when the biometric app lock is due.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    @MainActor
    @Suite("App lock clock (J1 / F3)")
    struct AppLockClockTests {
        private let user = User(id: "u1", email: nil, username: "demo", displayName: nil, createdAt: nil)
        private let start = Date(timeIntervalSince1970: 1_800_000_000)

        /// Walks a scene phase through the clock as `RootView` does.
        private func scene(
            _ clock: inout AppLockClock,
            _ phase: ScenePhase,
            at seconds: TimeInterval,
            eligible: Bool = true,
            lockEnabled: Bool = true
        ) -> Bool {
            clock.scenePhaseChanged(
                to: phase,
                now: start.addingTimeInterval(seconds),
                eligible: eligible,
                lockEnabled: lockEnabled,
                lockBusy: false
            )
        }

        private func auth(
            _ clock: inout AppLockClock,
            _ phase: AuthStore.Phase,
            lockEnabled: Bool = true
        ) -> Bool {
            clock.authPhaseChanged(to: phase, lockEnabled: lockEnabled)
        }

        // MARK: Rule 1 — only `.background` starts the clock

        @Test("a system dialog open longer than the grace period does not lock")
        func inactiveDoesNotLock() {
            var clock = AppLockClock()
            #expect(!scene(&clock, .inactive, at: 0))
            // Notification permission dialog left open for five minutes.
            #expect(!scene(&clock, .active, at: 300))
        }

        @Test("a real background trip past the grace period locks, once")
        func backgroundLocks() {
            var clock = AppLockClock()
            #expect(!scene(&clock, .inactive, at: 0))
            #expect(!scene(&clock, .background, at: 1))
            #expect(!scene(&clock, .inactive, at: 60))
            #expect(scene(&clock, .active, at: 61))
            // The stamp is consumed — a fast second `.active` does not re-fire.
            #expect(!scene(&clock, .active, at: 62))
        }

        @Test("a short background trip stays unlocked")
        func shortBackgroundStaysUnlocked() {
            var clock = AppLockClock()
            #expect(!scene(&clock, .background, at: 0))
            #expect(!scene(&clock, .active, at: 10))
        }

        @Test("the lock's own Face ID sheet never re-arms it")
        func lockBusyDoesNotStamp() {
            var clock = AppLockClock()
            _ = clock.scenePhaseChanged(
                to: .background, now: start, eligible: true, lockEnabled: true, lockBusy: true
            )
            #expect(!scene(&clock, .active, at: 120))
        }

        @Test("lock setting off: never locks")
        func settingOff() {
            var clock = AppLockClock()
            #expect(!scene(&clock, .background, at: 0, lockEnabled: false))
            #expect(!scene(&clock, .active, at: 600, lockEnabled: false))
            #expect(!auth(&clock, .authenticated(user), lockEnabled: false))
        }

        // MARK: Rule 2 — no lock during or right after onboarding

        @Test("sign-in in this process: no lock on reaching the dashboard")
        func noLockAfterOnboarding() {
            var clock = AppLockClock()
            #expect(!auth(&clock, .unknown, lockEnabled: true))
            #expect(!auth(&clock, .unauthenticated, lockEnabled: true))
            #expect(!auth(&clock, .authenticating(user), lockEnabled: true))
            #expect(!auth(&clock, .authenticated(user), lockEnabled: true))
        }

        @Test("standalone onboarding in this process: no lock either")
        func noLockAfterStandaloneOnboarding() {
            var clock = AppLockClock()
            #expect(!auth(&clock, .unauthenticated, lockEnabled: true))
            #expect(!auth(&clock, .standalone, lockEnabled: true))
        }

        @Test("a background trip during onboarding does not lock the first foreground after sign-in")
        func onboardingBackgroundDoesNotCarryOver() {
            var clock = AppLockClock()
            _ = clock.authPhaseChanged(to: .authenticating(user), lockEnabled: true)
            // Person leaves for iOS Settings mid-onboarding (not unlock-eligible).
            #expect(!scene(&clock, .background, at: 0, eligible: false))
            #expect(!scene(&clock, .active, at: 120, eligible: false))
            _ = clock.authPhaseChanged(to: .authenticated(user), lockEnabled: true)
            // Notification dialog → back: must not lock.
            #expect(!scene(&clock, .inactive, at: 130))
            #expect(!scene(&clock, .active, at: 200))
        }

        @Test("after onboarding, a later background trip still locks")
        func laterBackgroundStillLocks() {
            var clock = AppLockClock()
            _ = clock.authPhaseChanged(to: .unauthenticated, lockEnabled: true)
            _ = clock.authPhaseChanged(to: .authenticated(user), lockEnabled: true)
            #expect(!scene(&clock, .background, at: 0))
            #expect(scene(&clock, .active, at: 45))
        }

        // MARK: Update path — an installation with "lock on"

        @Test("update path: cold launch with a stored session still locks, once")
        func coldLaunchWithSessionLocks() {
            var clock = AppLockClock()
            #expect(!auth(&clock, .unknown, lockEnabled: true))
            #expect(auth(&clock, .authenticated(user), lockEnabled: true))
            #expect(!auth(&clock, .authenticated(user), lockEnabled: true))
        }

        @Test("update path: cold launch in standalone mode still locks")
        func coldLaunchStandaloneLocks() {
            var clock = AppLockClock()
            #expect(auth(&clock, .standalone, lockEnabled: true))
        }
    }

#endif
