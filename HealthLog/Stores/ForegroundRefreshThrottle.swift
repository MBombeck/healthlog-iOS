import Foundation

/// W8-A1 — small coalescer for the foreground refresh fan-out.
///
/// Both `RootView` and `DashboardScreen` historically fired the HK daily-stats
/// sync on every `scenePhase == .active`, so on a foreground while the Home tab
/// was visible the live HK read + server-sync ran twice concurrently against
/// the ≤300ms foreground budget. This value type records the last accepted run
/// and answers "should this call actually run?" — a non-forced call inside the
/// throttle window is suppressed (the prior run's data is still warm); an
/// explicit user-driven refresh (`force: true`) always runs and re-arms the
/// window so an immediately-following bounce doesn't double up.
///
/// It is a pure value type (deterministic `now` seam) so the dedup decision is
/// unit-testable without standing up the whole composition root.
struct ForegroundRefreshThrottle {
    /// Suppression window. A non-forced call within this interval of the last
    /// accepted run is coalesced away.
    let window: TimeInterval

    /// Wall-clock of the last accepted run. `nil` until the first run.
    private(set) var lastRunAt: Date?

    init(window: TimeInterval) {
        self.window = window
    }

    /// Decides whether a refresh should run, mutating the throttle state to
    /// record an accepted run.
    ///
    /// - Parameters:
    ///   - force: bypass the window (explicit pull-to-refresh / retry).
    ///   - now: injected clock for deterministic tests.
    /// - Returns: `true` if the caller should perform the refresh.
    mutating func shouldRun(force: Bool = false, now: Date = .now) -> Bool {
        if !force, let last = lastRunAt, now.timeIntervalSince(last) < window {
            return false
        }
        lastRunAt = now
        return true
    }

    /// **14-05 (D-09-06-A) — hand a stamp back.**
    ///
    /// ``shouldRun(force:now:)`` stamps the window at the moment it admits a
    /// caller, which is correct for a caller that then does the work, and a lie
    /// for one that is cancelled before it does any. The caller that can tell
    /// the difference is the one that saw the outcome, so it gets a way to
    /// restore the stamp it replaced: the window then belongs to whoever
    /// actually spends it.
    ///
    /// Restoring is deliberately dumb — it writes the value it is given and
    /// makes no judgement. The judgement lives with the caller that has the
    /// pass report (`ForegroundPassPlan.passSpentTheThrottleWindow`).
    mutating func restore(_ stamp: Date?) {
        lastRunAt = stamp
    }
}
