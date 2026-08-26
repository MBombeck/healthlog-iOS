import Foundation
@testable import HealthLog
import Testing

/// A2-M4 — locks the appear-revalidation freshness gate that lets list stores
/// re-validate the *partial-then-stale* case (data went stale after a partial
/// success) instead of only reloading when empty. `isStale` is a pure function
/// of the recorded load time and an injected `now`.
@Suite("RevalidationGate (A2-M4 appear-revalidate)")
struct RevalidationGateTests {
    @Test("Stale before the first load")
    func staleWhenNeverLoaded() {
        let gate = RevalidationGate(ttl: 60)
        #expect(gate.isStale(now: Date(timeIntervalSinceReferenceDate: 0)))
    }

    @Test("Fresh immediately after a load")
    func freshRightAfterLoad() {
        var gate = RevalidationGate(ttl: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        gate.markLoaded(now: t0)
        #expect(!gate.isStale(now: t0.addingTimeInterval(1)))
    }

    @Test("Fresh anywhere inside the window")
    func freshInsideWindow() {
        var gate = RevalidationGate(ttl: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        gate.markLoaded(now: t0)
        #expect(!gate.isStale(now: t0.addingTimeInterval(59)))
    }

    @Test("Stale exactly at and past the window boundary")
    func staleAtBoundary() {
        var gate = RevalidationGate(ttl: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        gate.markLoaded(now: t0)
        #expect(gate.isStale(now: t0.addingTimeInterval(60)))
        #expect(gate.isStale(now: t0.addingTimeInterval(120)))
    }

    @Test("markLoaded re-arms the window from the latest load")
    func reloadResetsWindow() {
        var gate = RevalidationGate(ttl: 60)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        gate.markLoaded(now: t0)
        // A second load 90s later (after going stale) re-arms freshness.
        let t1 = t0.addingTimeInterval(90)
        #expect(gate.isStale(now: t1))
        gate.markLoaded(now: t1)
        #expect(!gate.isStale(now: t1.addingTimeInterval(10)))
    }
}
