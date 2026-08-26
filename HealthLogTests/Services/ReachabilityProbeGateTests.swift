import Foundation
@testable import HealthLog
import Testing

/// v0.7.1 QoL-3-H-3 — captive-portal probe gate for `Reachability`.
///
/// `NWPathMonitor` reports `.satisfied` on captive-portal Wi-Fi even when
/// real API traffic is blocked, so the Outbox replay loop used to fire
/// writes that hang then fail. `Reachability.confirmedReachable()` now
/// gates on an injected `/api/health` probe. These tests pin the gate
/// decision by stubbing the probe (and the clock for the debounce window)
/// rather than touching the live `NWPathMonitor`, which a unit runner
/// cannot drive deterministically.
///
/// A freshly constructed `Reachability` reports `currentlyOnline == true`
/// (the optimistic default until the first path update), so the interface
/// gate is satisfied and `confirmedReachable()` defers to the probe.
@Suite("Reachability — captive-portal probe gate")
struct ReachabilityProbeGateTests {
    /// Mutable, Sendable probe counter + verdict the tests drive.
    private actor ProbeBox {
        private(set) var calls = 0
        private var verdict: Bool
        init(verdict: Bool) {
            self.verdict = verdict
        }

        func setVerdict(_ value: Bool) {
            verdict = value
        }

        func probe() -> Bool {
            calls += 1
            return verdict
        }
    }

    @Test("No probe wired → degrades to interface signal (true)")
    func noProbeDegradesToInterface() async {
        let reach = Reachability()
        // No `setProbe` — default-online interface should pass through.
        #expect(await reach.confirmedReachable())
    }

    @Test("Probe reports unreachable → gate is false (captive portal)")
    func captivePortalProbeBlocksGate() async {
        let box = ProbeBox(verdict: false)
        let reach = Reachability()
        await reach.setProbe { await box.probe() }

        #expect(await reach.confirmedReachable() == false)
        #expect(await box.calls == 1)
    }

    @Test("Probe reports reachable → gate is true (real network)")
    func realNetworkProbePassesGate() async {
        let box = ProbeBox(verdict: true)
        let reach = Reachability()
        await reach.setProbe { await box.probe() }

        #expect(await reach.confirmedReachable())
        #expect(await box.calls == 1)
    }

    @Test("Verdict is debounced within the TTL — no probe storm")
    func debounceReusesVerdictWithinTTL() async {
        nonisolated(unsafe) var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let box = ProbeBox(verdict: true)
        let reach = Reachability(probeTTL: 10, clock: { fakeNow })
        await reach.setProbe { await box.probe() }

        #expect(await reach.confirmedReachable())
        // Second call 5 s later is inside the 10 s TTL → cached, no re-probe.
        fakeNow = fakeNow.addingTimeInterval(5)
        #expect(await reach.confirmedReachable())
        #expect(await box.calls == 1)
    }

    @Test("Verdict is re-probed once the TTL elapses")
    func reProbesAfterTTL() async {
        nonisolated(unsafe) var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let box = ProbeBox(verdict: true)
        let reach = Reachability(probeTTL: 10, clock: { fakeNow })
        await reach.setProbe { await box.probe() }

        #expect(await reach.confirmedReachable())
        // Past the TTL → re-probe. Flip the verdict to confirm the fresh
        // result (not the stale cache) is what the gate returns.
        await box.setVerdict(false)
        fakeNow = fakeNow.addingTimeInterval(11)
        #expect(await reach.confirmedReachable() == false)
        #expect(await box.calls == 2)
    }
}
