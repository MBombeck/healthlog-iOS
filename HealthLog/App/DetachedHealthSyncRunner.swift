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
///
/// **SYNC-HR (1.5, #159 / HealthLog#1326):** the budget only stops
/// *admitting* capabilities. A pass whose capability never returned kept
/// `running` set, and every later request (pull to refresh included) was
/// folded into it until the app was restarted. A request that finds a pass
/// older than ``staleAfter`` now cancels it and starts a new one; the stale
/// pass is fenced by its generation, so it neither clears the new slot nor
/// takes the new pending request when it finally returns.
actor DetachedHealthSyncRunner {
    typealias Pass = @Sendable (HealthSyncTrigger, @escaping @Sendable () -> Bool) async -> Void

    /// Process-wide, like `ForegroundCoordinator.shared`: a process has one
    /// foreground, and two runners would be two passes over the same cursors.
    static let shared = DetachedHealthSyncRunner()

    /// How long one detached pass may keep admitting capabilities. Long enough
    /// for a normal incremental pass, short enough that a stuck request cannot
    /// keep the trailing pass waiting for minutes.
    static let defaultBudget: TimeInterval = 90

    /// SYNC-HR — three minutes: the budget plus the longest capability
    /// deadline a pass admitted just before it closed may still run into.
    static let defaultStaleAfter: TimeInterval = 180

    private let budget: TimeInterval
    private let staleAfter: TimeInterval
    private let clock: @Sendable () -> Date
    private var running: Run?

    private struct Run {
        let task: Task<Void, Never>
        let generation: UInt64
        var passStartedAt: Date
    }

    private var pending: (trigger: HealthSyncTrigger, pass: Pass)?
    private var generation: UInt64 = 0

    /// Test introspection: how many passes this runner has started.
    private(set) var passesStarted = 0

    init(
        budget: TimeInterval = DetachedHealthSyncRunner.defaultBudget,
        staleAfter: TimeInterval = DetachedHealthSyncRunner.defaultStaleAfter,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.budget = budget
        self.staleAfter = staleAfter
        self.clock = clock
    }

    /// Starts a pass for `trigger`, or folds the request into the pass in
    /// flight. Returns the task that runs it; awaiting it waits for the
    /// trailing pass too. The caller's own cancellation never reaches it.
    @discardableResult
    func request(_ trigger: HealthSyncTrigger, pass: @escaping Pass) -> Task<Void, Never> {
        if let running {
            let age = clock().timeIntervalSince(running.passStartedAt)
            guard age >= staleAfter else {
                if pending == nil { pending = (trigger, pass) }
                return running.task
            }
            running.task.cancel()
            self.running = nil
            pending = nil
            // Generation and age are counts.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.error(
                "detached pass \(running.generation, privacy: .public) stuck \(Int(age), privacy: .public)s: replaced"
            )
        }
        generation &+= 1
        let id = generation
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await drain(trigger, pass, generation: id)
        }
        running = Run(task: task, generation: id, passStartedAt: clock())
        return task
    }

    private func drain(_ trigger: HealthSyncTrigger, _ pass: @escaping Pass, generation id: UInt64) async {
        var next: (trigger: HealthSyncTrigger, pass: Pass)? = (trigger, pass)
        while let work = next, running?.generation == id {
            pending = nil
            passesStarted += 1
            running?.passStartedAt = clock()
            let clock = clock
            let deadline = clock().addingTimeInterval(budget)
            // A replaced pass closes its window at once: the orchestrator
            // admits nothing more for it.
            let handle = running?.task
            await work.pass(work.trigger) { clock() >= deadline || handle?.isCancelled == true }
            next = running?.generation == id ? pending : nil
        }
        if running?.generation == id { running = nil }
    }
}
