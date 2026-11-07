import Foundation
@testable import HealthLog
import Testing

/// SYNC-HR (1.5, #159 / HealthLog#1326) — pull to refresh with a stuck
/// pass. Until 1.4.1 the forced call awaited the pass without a limit; the
/// dashboard's store refreshes come after it (`DashboardScreen` `.refreshable`),
/// so they never ran while the spinner still ended in a check mark.
@Suite("SYNC-HR — pull to refresh never waits on a stuck pass", .timeLimit(.minutes(1)))
struct PullToRefreshStallTests {
    actor Refreshes {
        private(set) var stores = 0
        func refreshStores() {
            stores += 1
        }
    }

    @Test("(c) with a pass that never returns, the stores refresh after the wait, not never")
    func storesRefreshAfterBoundedWait() async {
        let runner = DetachedHealthSyncRunner()
        let refreshes = Refreshes()
        let pull = Task {
            // The dashboard's order: the forced pass first, then the stores.
            let finished = await AppContainer.requestForegroundPass(
                runner: runner,
                force: true,
                wait: .milliseconds(300)
            ) { _, _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            await refreshes.refreshStores()
            return finished
        }
        var refreshed = false
        for _ in 0 ..< 250 where !refreshed {
            refreshed = await refreshes.stores == 1
            if !refreshed { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(refreshed, "the stores never refreshed behind a stuck pass")
        if refreshed { #expect(await pull.value == false) }
        #expect(AppContainer.pullToRefreshPassWait == .seconds(20))
    }

    @Test("a pass that finishes in time is waited for, and an unforced call never waits")
    func healthyPassIsAwaited() async {
        let runner = DetachedHealthSyncRunner()
        let finished = await AppContainer.requestForegroundPass(runner: runner, force: true, wait: .seconds(5)) { _, _ in
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(finished)
        let unforced = await AppContainer.requestForegroundPass(runner: DetachedHealthSyncRunner(), force: false) { _, _ in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        #expect(unforced)
    }
}
