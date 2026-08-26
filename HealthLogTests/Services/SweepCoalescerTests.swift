import Foundation
@testable import HealthLog
import Testing

/// **Audit v0.14.8 N5.3** — pins the anchored-sweep interleave guard the HK
/// importers (`WorkoutHealthKitImporter`, `CycleHealthKitImporter`) route every
/// sweep through: one body at a time per key, a mid-flight trigger coalesces
/// into exactly one trailing re-run (never dropped, never interleaved), and
/// distinct keys (cycle per-type sweeps) don't serialize against each other.
@Suite("SweepCoalescer — N5.3 sweep interleave guard")
struct SweepCoalescerTests {
    /// Counts concurrent + total executions of the guarded body.
    private actor Probe {
        private(set) var current = 0
        private(set) var maxConcurrent = 0
        private(set) var runs = 0

        func enter() {
            current += 1
            runs += 1
            maxConcurrent = max(maxConcurrent, current)
        }

        func exit() {
            current -= 1
        }
    }

    /// Manual latch so a test can hold the first sweep open deterministically.
    private actor Latch {
        private var opened = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            opened = true
            continuations.forEach { $0.resume() }
            continuations = []
        }
    }

    @Test("concurrent triggers never run the body concurrently")
    func noConcurrentBodies() async {
        let gate = SweepCoalescer()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    await gate.run {
                        await probe.enter()
                        await Task.yield()
                        await probe.exit()
                    }
                }
            }
        }
        #expect(await probe.maxConcurrent == 1, "two sweeps must never interleave from the same anchor")
    }

    @Test("mid-flight trigger coalesces into exactly one trailing re-run")
    func trailingRerun() async {
        let gate = SweepCoalescer()
        let probe = Probe()
        let latch = Latch()

        let first = Task {
            await gate.run {
                await probe.enter()
                await latch.wait()
                await probe.exit()
            }
        }
        // Wait until the first sweep is provably in flight.
        while await probe.runs < 1 {
            await Task.yield()
        }

        // Three observer fires land mid-sweep — all must return immediately
        // (coalesced), none may start a body while the first one is parked.
        for _ in 0 ..< 3 {
            await gate.run {
                await probe.enter()
                await probe.exit()
            }
        }
        #expect(await probe.runs == 1, "coalesced triggers must not start a second body mid-flight")

        await latch.open()
        await first.value
        #expect(await probe.runs == 2, "exactly ONE trailing re-run, no matter how many triggers coalesced")
        #expect(await probe.maxConcurrent == 1)
    }

    @Test("distinct keys run independently and do not coalesce each other")
    func distinctKeysIndependent() async {
        let gate = SweepCoalescer()
        let probe = Probe()
        let latch = Latch()

        let blocked = Task {
            await gate.run(key: "typeA") {
                await probe.enter()
                await latch.wait()
                await probe.exit()
            }
        }
        while await probe.runs < 1 {
            await Task.yield()
        }

        // A different type's sweep must run to completion while typeA is parked.
        await gate.run(key: "typeB") {
            await probe.enter()
            await probe.exit()
        }
        #expect(await probe.runs == 2, "typeB must not serialize behind typeA")

        await latch.open()
        await blocked.value
        #expect(await probe.runs == 2, "typeB's pass must not queue a trailing re-run for typeA")
    }

    @Test("cancellation suppresses a queued trailing re-run")
    func cancellationSuppressesTrailingRerun() async {
        let gate = SweepCoalescer()
        let probe = Probe()
        let latch = Latch()

        let first = Task {
            await gate.run {
                await probe.enter()
                await withTaskCancellationHandler {
                    await latch.wait()
                } onCancel: {
                    Task { await latch.open() }
                }
                await probe.exit()
            }
        }
        while await probe.runs < 1 {
            await Task.yield()
        }
        await gate.run {
            await probe.enter()
            await probe.exit()
        }

        first.cancel()
        await first.value

        #expect(await probe.runs == 1)
    }
}
