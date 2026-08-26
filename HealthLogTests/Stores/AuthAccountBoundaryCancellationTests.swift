import Foundation
@testable import HealthLog
import Testing

@MainActor
@Suite("Auth account boundary cancellation", .serialized)
struct AuthAccountBoundaryCancellationTests {
    @MainActor
    private final class CompletionProbe {
        var liveWaiterAcquired = false
        var cancelledCompletions = 0
    }

    @Test("cancelled waiter never acquires boundary")
    func cancelledWaiterNeverAcquiresBoundary() async {
        let transition = AuthAccountBoundaryTransition()
        let probe = CompletionProbe()
        #expect(await transition.acquireOwnership(.authentication))

        let cancelled = Task { @MainActor in
            let acquired = await transition.acquireOwnership(.deletedAccount)
            probe.cancelledCompletions += 1
            guard acquired else { return }
            transition.release(.deletedAccount)
        }
        await letCancelledWaiterQueue()
        cancelled.cancel()

        let live = Task { @MainActor in
            guard await transition.acquireOwnership(.authentication) else { return }
            probe.liveWaiterAcquired = true
            transition.release(.authentication)
        }
        await letCancelledWaiterQueue()
        transition.release(.authentication)
        await drainMainActorJobs()

        if !probe.liveWaiterAcquired {
            Issue.record("EXPECTED_RED: cancelled waiter acquired boundary")
        }

        _ = await cancelled.result
        _ = await live.result
        #expect(probe.cancelledCompletions == 1)
    }

    @Test("cancellation racing release completes exactly once")
    func cancellationRacingReleaseCompletesExactlyOnce() async {
        let transition = AuthAccountBoundaryTransition()
        let probe = CompletionProbe()
        #expect(await transition.acquireOwnership(.authentication))

        let cancelled = Task { @MainActor in
            let acquired = await transition.acquireOwnership(.deletedAccount)
            probe.cancelledCompletions += 1
            guard acquired else { return }
            transition.release(.deletedAccount)
        }
        await letCancelledWaiterQueue()

        // Both operations are issued without a suspension between them. Main-
        // actor arbitration must choose exactly one terminal path for the
        // queued continuation and must not transfer ownership to cancelled work.
        cancelled.cancel()
        transition.release(.authentication)

        let live = Task { @MainActor in
            guard await transition.acquireOwnership(.authentication) else { return }
            probe.liveWaiterAcquired = true
            transition.release(.authentication)
        }
        await drainMainActorJobs()

        if !probe.liveWaiterAcquired || probe.cancelledCompletions != 1 {
            Issue.record("EXPECTED_RED: waiter completed more than once")
        }

        _ = await cancelled.result
        _ = await live.result
        #expect(probe.cancelledCompletions == 1)
    }

    /// Gives the newly-created main-actor task an execution turn so its
    /// continuation is queued before cancellation/release is issued.
    private func letCancelledWaiterQueue() async {
        await Task.yield()
        await Task.yield()
    }

    /// Drains resumed main-actor continuations without wall-clock timing.
    private func drainMainActorJobs() async {
        for _ in 0 ..< 8 {
            await Task.yield()
        }
    }
}
