import Foundation

// A pass that ends with rows it may send again later used to leave them to the
// next outside trigger: a foreground, a network edge, a background window.
// With the app open on a stable connection none of those comes, so a write
// that met one timeout sat in the queue although the server had long been
// back. The service now wakes itself once the wait is over.
//
// It is not a poll. A pass arms at most one wake-up, each self-armed pass
// waits twice as long as the one before, and after
// ``OutboxReplayService/maxRerunsInARow`` of them the service is quiet again
// until something outside starts a pass.

/// The service's own wake-up: the armed task and how often it has fired since
/// the last outside trigger.
struct OutboxRerunState {
    var task: Task<Void, Never>?
    /// Self-armed passes in a row.
    var streak = 0
    /// A row failed retriably in the running pass and now sits in its back-off.
    var failedThisPass = false
    /// A trigger came while the running pass held the guard.
    var triggerTurnedAway = false
}

extension OutboxReplayService {
    /// Self-armed passes before the service waits for an outside trigger:
    /// with the default back-off that is half an hour of trying.
    static let maxRerunsInARow = 5

    /// Arms one wake-up when the pass left rows that only wait for time: a
    /// back-off or the server's rate-limit hold. Rows nothing but a person or
    /// another account can move (parked, over budget, foreign) arm nothing.
    func armRerunIfWaiting(after snapshot: [OutboxQueue.Operation], currentUser: String?, generation: UInt64) {
        let failed = rerun.failedThisPass
        rerun.failedThisPass = false
        guard let sleep = rerunSleep, isCurrentRun(generation) else { return }
        rerun.task?.cancel()
        rerun.task = nil
        let now = clock()
        guard rerun.streak < Self.maxRerunsInARow,
              let wake = nextSendInstant(in: snapshot, currentUser: currentUser, failedThisPass: failed, now: now) else { return }
        let floor = rerun.streak == 0 ? 1 : attemptBackoff * pow(2, Double(rerun.streak))
        let delay = max(wake.timeIntervalSince(now), floor)
        // Detached: the wake-up outlives the trigger that armed it and must not
        // carry that trigger's task-local context into its own pass.
        rerun.task = Task.detached(priority: .utility) { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.runAfterWait()
        }
    }

    /// The armed wake-up, for a test that has to see its pass end.
    var armedRerun: Task<Void, Never>? {
        rerun.task
    }

    private func runAfterWait() async {
        // Replaced while it slept: the newer wake-up owns the next pass.
        guard !Task.isCancelled else { return }
        rerun.task = nil
        rerun.streak += 1
        await runGuardedPass()
    }

    /// The earliest instant a waiting row of the signed-in account may go out
    /// again, or `nil` when no row waits for time alone.
    private func nextSendInstant(
        in snapshot: [OutboxQueue.Operation],
        currentUser: String?,
        failedThisPass: Bool,
        now: Date
    ) -> Date? {
        var candidates: [Date] = []
        if failedThisPass { candidates.append(now.addingTimeInterval(attemptBackoff)) }
        for op in snapshot where op.belongs(to: currentUser) && op.holdReason(maxAttempts: maxAttempts) == nil {
            guard let last = op.lastAttemptAt else { continue }
            let free = last.addingTimeInterval(attemptBackoff)
            if free > now { candidates.append(free) }
        }
        guard let earliest = candidates.min() else {
            // Nothing in a back-off: only the queue-wide hold can still be the reason.
            guard let hold = rateLimit.holdUntil, hold > now else { return nil }
            return hold
        }
        if let hold = rateLimit.holdUntil, hold > earliest { return hold }
        return earliest
    }
}
