import Foundation

/// **V1 (1.2, #66 / HealthLog#1173) — the foreground HealthKit pass, outside the
/// 250 ms foreground deadline.**
///
/// Until 1.1.1 the foreground step awaited a whole orchestrated pass inside the
/// bounded foreground pass. `ForegroundCoordinator` cancels its legs after
/// 250 ms, and the orchestrator admits nothing once its task is cancelled, so
/// the pass named the day totals, the pulse buckets and the sample collection
/// `cancelled` on practically every app open. Those values then reached the
/// server only on "Sync all".
///
/// The runner owns that pass instead. It is a detached task, so the
/// foreground's cancellation does not reach it; it has its own budget, after
/// which the orchestrator stops admitting capabilities and names the rest
/// `expired`; and it is coalesced: while one pass runs, further requests fold
/// into exactly one trailing pass. A trailing pass keeps the first trigger that
/// asked for it, so a cold activation queued behind nothing is not renamed by a
/// foreground tick that arrives a moment later.
actor DetachedHealthSyncRunner {
    typealias Pass = @Sendable (HealthSyncTrigger, @escaping @Sendable () -> Bool) async -> Void

    /// Process-wide, like `ForegroundCoordinator.shared`: a process has one
    /// foreground, and two runners would be two passes over the same cursors.
    static let shared = DetachedHealthSyncRunner()

    /// How long one detached pass may keep admitting capabilities. Long enough
    /// for a normal incremental pass, short enough that a stuck request cannot
    /// keep the trailing pass waiting for minutes.
    static let defaultBudget: TimeInterval = 90

    private let budget: TimeInterval
    private let clock: @Sendable () -> Date
    private var running: Task<Void, Never>?
    private var pending: (trigger: HealthSyncTrigger, pass: Pass)?

    /// Test introspection: how many passes this runner has started.
    private(set) var passesStarted = 0

    init(budget: TimeInterval = DetachedHealthSyncRunner.defaultBudget, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.budget = budget
        self.clock = clock
    }

    /// Starts a pass for `trigger`, or folds the request into the pass in
    /// flight. Returns the task that runs it; awaiting it waits for the
    /// trailing pass too. The caller's own cancellation never reaches it.
    @discardableResult
    func request(_ trigger: HealthSyncTrigger, pass: @escaping Pass) -> Task<Void, Never> {
        if let running {
            if pending == nil { pending = (trigger, pass) }
            return running
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await drain(trigger, pass)
        }
        running = task
        return task
    }

    private func drain(_ trigger: HealthSyncTrigger, _ pass: @escaping Pass) async {
        var next: (trigger: HealthSyncTrigger, pass: Pass)? = (trigger, pass)
        while let work = next {
            pending = nil
            passesStarted += 1
            let clock = clock
            let deadline = clock().addingTimeInterval(budget)
            await work.pass(work.trigger) { clock() >= deadline }
            next = pending
        }
        running = nil
    }
}
