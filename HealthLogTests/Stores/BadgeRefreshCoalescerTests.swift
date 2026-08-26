import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog

    /// **v0.6.1.9 Y8 — BadgeRefreshCoalescer behaviour.**
    ///
    /// AppContainer wires `MedicationsStore.onIntakesDidChange` through a
    /// single-slot `BadgeRefreshCoalescer` so a Genommen-tap burst (which
    /// fires the callback 2-3 times per mark: optimistic patch → server
    /// confirm → invalidate) does not hammer
    /// `UNUserNotificationCenter.setBadgeCount` with N redundant Tasks.
    /// Only the last-scheduled work item runs; iOS still coalesces
    /// identical badge values internally so behaviour-correctness is
    /// preserved.
    @Suite("BadgeRefreshCoalescer — single-slot dispatch")
    @MainActor
    struct BadgeRefreshCoalescerTests {
        /// A single schedule call runs to completion.
        @Test("schedule fires the work item")
        func scheduleFires() async {
            let coalescer = BadgeRefreshCoalescer()
            let counter = Counter()
            coalescer.schedule { await counter.bump() }
            // Yield repeatedly so the scheduled Task gets a chance to run.
            for _ in 0 ..< 16 {
                await Task.yield()
            }
            await #expect(counter.value == 1)
        }

        /// Burst of N consecutive schedules collapses to a single
        /// completed work item — the earlier Tasks get cancelled before
        /// they observe their `await Task.yield()` checkpoint, so only
        /// the last winner bumps the counter.
        @Test("burst of N schedules coalesces to last-winner")
        func burstCoalesces() async {
            let coalescer = BadgeRefreshCoalescer()
            let counter = Counter()
            // Schedule 5 items back-to-back. Each work closure yields
            // first so the cancellation has a chance to land before the
            // bump runs.
            for _ in 0 ..< 5 {
                coalescer.schedule {
                    await Task.yield()
                    if Task.isCancelled { return }
                    await counter.bump()
                }
            }
            for _ in 0 ..< 32 {
                await Task.yield()
            }
            // Only the last-scheduled Task observes "not cancelled"
            // beyond the yield; the prior four were replaced.
            let value = await counter.value
            #expect(value == 1, "Expected coalesced to 1, got \(value)")
        }

        /// Sequential (await-completed) schedules each run to completion;
        /// only overlapping bursts are coalesced.
        @Test("sequential schedules each fire")
        func sequentialSchedules() async {
            let coalescer = BadgeRefreshCoalescer()
            let counter = Counter()
            coalescer.schedule { await counter.bump() }
            for _ in 0 ..< 16 {
                await Task.yield()
            }
            coalescer.schedule { await counter.bump() }
            for _ in 0 ..< 16 {
                await Task.yield()
            }
            await #expect(counter.value == 2)
        }
    }

    private actor Counter {
        private(set) var value: Int = 0
        func bump() {
            value += 1
        }
    }
#endif
