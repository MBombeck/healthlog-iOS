import Foundation
@testable import HealthLog

// swiftlint:disable force_unwrapping
import Testing

/// Build 273 (sync audit B3) — `transferUserInfo` is at-least-once. The phone
/// must handle each watch action id once and answer a redelivery with the
/// outcome it already produced, instead of recording the intake twice.
@Suite("Watch action replay guard (B3)")
struct WatchActionReplayGuardTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "watch-guard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("the first delivery is admitted, the redelivery is answered from memory")
    func redeliveryIsNotAdmittedTwice() {
        let guardStore = WatchActionReplayGuard(defaults: makeDefaults())
        #expect(guardStore.priorOutcome(for: "a1") == nil)
        guardStore.remember("a1", outcome: .saved)
        #expect(guardStore.priorOutcome(for: "a1") == .saved)
        #expect(guardStore.priorOutcome(for: "a2") == nil)
    }

    @Test("outcomes survive a relaunch and the memory stays bounded")
    func persistedAndBounded() {
        let defaults = makeDefaults()
        let first = WatchActionReplayGuard(defaults: defaults)
        for i in 0 ..< (WatchActionReplayGuard.capacity + 5) {
            first.remember("id-\(i)", outcome: .queued)
        }
        let second = WatchActionReplayGuard(defaults: defaults)
        #expect(second.priorOutcome(for: "id-\(WatchActionReplayGuard.capacity + 4)") == .queued)
        #expect(second.priorOutcome(for: "id-0") == nil, "the oldest ids are evicted")
    }
}
