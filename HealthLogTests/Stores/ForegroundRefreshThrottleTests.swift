import Foundation
@testable import HealthLog
import Testing

/// W8-A1 — locks the foreground-refresh dedup: when both scenePhase observers
/// fire on the same `.active` transition, the HK-stats sync runs ONCE, not
/// twice; an explicit pull-to-refresh always runs.
///
/// `shouldRun` is `mutating`, so each call is hoisted out of the `#expect`
/// autoclosure (which captures its value immutably) into a local `let`.
@Suite("ForegroundRefreshThrottle (W8-A1 foreground dedup)")
struct ForegroundRefreshThrottleTests {
    @Test("Two near-simultaneous foreground calls run only once")
    func doubleForegroundCoalescesToOne() {
        var throttle = ForegroundRefreshThrottle(window: 10)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        // RootView observer fires.
        let first = throttle.shouldRun(now: t0)
        // DashboardScreen observer fires ~immediately after on the same
        // `.active` — must be suppressed.
        let second = throttle.shouldRun(now: t0.addingTimeInterval(0.05))
        let third = throttle.shouldRun(now: t0.addingTimeInterval(2))
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test("A call after the window elapses runs again")
    func windowExpiryAllowsRerun() {
        var throttle = ForegroundRefreshThrottle(window: 10)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        let first = throttle.shouldRun(now: t0)
        // A genuine later foreground (> window) must run.
        let later = throttle.shouldRun(now: t0.addingTimeInterval(11))
        #expect(first)
        #expect(later)
    }

    @Test("force bypasses the throttle even inside the window")
    func forceBypassesWindow() {
        var throttle = ForegroundRefreshThrottle(window: 10)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        let first = throttle.shouldRun(now: t0)
        // Pull-to-refresh inside the window still runs.
        let forced = throttle.shouldRun(force: true, now: t0.addingTimeInterval(1))
        #expect(first)
        #expect(forced)
    }

    @Test("force re-arms the window so an immediate bounce is suppressed")
    func forceRearmsWindow() {
        var throttle = ForegroundRefreshThrottle(window: 10)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        let forced = throttle.shouldRun(force: true, now: t0)
        // A foreground bounce right after the forced run is coalesced away.
        let bounce = throttle.shouldRun(now: t0.addingTimeInterval(0.5))
        #expect(forced)
        #expect(!bounce)
    }

    @Test("first ever call always runs")
    func firstCallRuns() {
        var throttle = ForegroundRefreshThrottle(window: 10)
        let ran = throttle.shouldRun(now: Date(timeIntervalSinceReferenceDate: 0))
        #expect(ran)
    }
}
