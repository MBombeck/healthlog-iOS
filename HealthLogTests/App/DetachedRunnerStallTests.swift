import Foundation
@testable import HealthLog
import Testing

/// SYNC-HR (1.5, #159 / HealthLog#1326) — the foreground pass runner.
///
/// Its budget only stops *admitting* capabilities. A pass whose capability
/// never returned kept the runner's slot, and every later request was folded
/// into it until the app was restarted. A request that finds a pass older
/// than the deadline now replaces it.
@Suite("SYNC-HR — detached runner never stalls", .timeLimit(.minutes(1)))
struct DetachedRunnerStallTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_793_000_000)
        var now: Date {
            lock.withLock { value }
        }

        func advance(by seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }

    /// Counts passes and keeps the first one open until released.
    final class Passes: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [String] = []
        private var finished: [String] = []
        private var hold: CheckedContinuation<Void, Never>?
        private var sawClosedWindow = false

        var startedTriggers: [String] {
            lock.withLock { started }
        }

        var finishedTriggers: [String] {
            lock.withLock { finished }
        }

        var firstSawClosedWindow: Bool {
            lock.withLock { sawClosedWindow }
        }

        func run(_ trigger: HealthSyncTrigger, isExpired: @escaping @Sendable () -> Bool) async {
            let first = lock.withLock {
                started.append(trigger.rawValue)
                return started.count == 1
            }
            if first {
                await withCheckedContinuation { continuation in lock.withLock { hold = continuation } }
                lock.withLock { sawClosedWindow = isExpired() }
            }
            lock.withLock { finished.append(trigger.rawValue) }
        }

        func release() {
            let held = lock.withLock {
                let held = hold
                hold = nil
                return held
            }
            held?.resume()
        }
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0 ..< 250 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("(b) a pass stuck past the deadline is replaced by the next request; the stuck one returns quietly")
    func stuckPassIsReplaced() async {
        let clock = Clock()
        let runner = DetachedHealthSyncRunner(clock: { clock.now })
        let passes = Passes()
        let pass: DetachedHealthSyncRunner.Pass = { trigger, isExpired in
            await passes.run(trigger, isExpired: isExpired)
        }

        let stuck = await runner.request(.coldActivation, pass: pass)
        #expect(await eventually { passes.startedTriggers.count == 1 })

        // Inside the deadline: folded, as before.
        clock.advance(by: 60)
        await runner.request(.foreground, pass: pass)
        #expect(passes.startedTriggers == ["coldActivation"])

        // Past it: a new pass runs at once.
        clock.advance(by: DetachedHealthSyncRunner.defaultStaleAfter)
        let fresh = await runner.request(.manual, pass: pass)
        #expect(await eventually { passes.finishedTriggers == ["manual"] }, "the request after the deadline did not run a pass")
        #expect(await runner.passesStarted == 2)

        // The stuck pass comes back late. Its window reads closed, it does
        // not run the folded request, and the slot is free afterwards.
        passes.release()
        await stuck.value
        await fresh.value
        #expect(passes.firstSawClosedWindow)
        #expect(passes.startedTriggers == ["coldActivation", "manual"])
        await runner.request(.foreground, pass: pass).value
        #expect(passes.startedTriggers == ["coldActivation", "manual", "foreground"])
        #expect(DetachedHealthSyncRunner.defaultStaleAfter == 180)
    }
}
