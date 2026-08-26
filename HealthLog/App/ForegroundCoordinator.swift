import Foundation
import Synchronization

// **Phase 09 / plan 09-06 — the foreground pass, as one bounded structure.**
//
// Until this plan the `.active` scene-phase transition fanned out into a dozen
// free-standing `Task { … }` siblings inside `RootView.handle(scenePhase:)`.
// That shape has four properties worth naming, because all four are defects
// rather than trade-offs:
//
// - **Nothing is ordered.** A comment in `RootView` claimed the badge recompute
//   "runs AFTER the force-load above settles (separate Task)". Two sibling
//   tasks are not ordered by being written next to each other; the badge read
//   `dueOrMissedCount` off whichever snapshot happened to be there.
// - **Nothing is cancelled.** Backgrounding the app, or signing out, left every
//   sibling running. A `Task { }` created inside another task does *not*
//   inherit its cancellation.
// - **Nothing is bounded.** The pass could run for as long as the slowest
//   network call, and the `foreground.pass` interval closed when one
//   arbitrarily chosen sibling finished.
// - **Nothing is fenced.** A result computed for the previous account could
//   publish into the current one, because no member compared the session it
//   started in against the session it finished in.
//
// This coordinator replaces the fan-out with a task group whose children are
// structured, a deadline that is a real cancellation rather than a log line,
// and a session token that a member must consult before it publishes. It moves
// orchestration only: every adapter body is the body `RootView` already had.
//
// **What it may claim.** Counts and orderings — how many passes ran, in which
// order the members started and finished, how many children were still in
// flight when the pass returned. The `≤ 300 ms p95` foreground budget (B2) is a
// *duration* and stays physical-device evidence for plan 09-09. What is
// claimable here is that the pass is **bounded by construction** at
// ``Budget/deadline`` plus ``Budget/drainAllowance``, and that a pass which hit
// that bound closes its interval with a non-`completed` outcome, so a trace can
// tell a fast pass from a truncated one instead of reporting both as "within
// budget".

// MARK: - The clock the deadline is measured against

/// The only thing the pass needs a clock for.
///
/// Injected rather than called directly so a contract test can prove *which*
/// budget was requested without spending any of it — a test that actually slept
/// 250 ms would be asserting the scheduler's punctuality, not the coordinator's
/// contract.
protocol ForegroundClock: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Production's clock. `ContinuousClock` keeps running while the device is
/// asleep, which is the correct reading of "the user has been waiting".
struct ContinuousForegroundClock: ForegroundClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

// MARK: - What a pass is made of

/// A named member of the foreground pass.
///
/// Naming them is what makes an ordering claim checkable: "medication before
/// badge" is a statement about two of these, and the pass records every start
/// and every end against them.
enum ForegroundMember: String, Sendable, CaseIterable {
    case webDeletionReconcile
    case focusFilter
    case networkRevalidate
    case healthKitReadiness
    case medicationLoad
    case badgeRefresh
    case moodReminder
    case moodRevalidate
    case cycleGate
    case outboxDrain
    case healthKitStats
    case dashboardSummary
    case insightsWarm
    case swrCacheSweep
    case doctorReportSweep
}

/// One member and the work it performs.
///
/// The work is `async throws` because the group is a `withThrowingTaskGroup`: a
/// member that fails ends the pass rather than being swallowed, and the pass
/// still closes its interval. Production's adapters are all fail-quiet today and
/// none of them throws; the capability exists so a future one cannot fail
/// silently.
struct ForegroundStep: Sendable {
    let member: ForegroundMember
    let work: @Sendable (ForegroundSession) async throws -> Void

    init(_ member: ForegroundMember, _ work: @escaping @Sendable (ForegroundSession) async throws -> Void) {
        self.member = member
        self.work = work
    }
}

/// A sequence of steps that must run **in order**.
///
/// Legs run concurrently with each other; steps inside a leg do not. That is the
/// whole ordering vocabulary of this plan, and it is deliberately the smallest
/// one that expresses the two real dependencies the foreground has: the
/// medication load before the badge that reads its count, and the HealthKit
/// daily-stats POST before the dashboard summary that re-reads those rows.
struct ForegroundLeg: Sendable {
    let steps: [ForegroundStep]
    /// An interval that spans this leg only. `scenephase.revalidate` is a leg
    /// interval rather than a pass interval: it is the project-guide budget for
    /// the *existing revalidation chain*, and if it were co-extensive with the
    /// bounded pass it would be truncated by the pass deadline and would pass
    /// its own budget by construction — a measurement that cannot fail.
    let interval: HLPerfSignpost.Interval?

    init(_ steps: [ForegroundStep], interval: HLPerfSignpost.Interval? = nil) {
        self.steps = steps
        self.interval = interval
    }
}

/// Everything one foreground pass will do.
struct ForegroundPlan: Sendable {
    let legs: [ForegroundLeg]
    /// **14-05 (D-09-06-A) — what the plan owes its gates once the pass is over.**
    ///
    /// A plan is built by reading gates, and reading a throttle gate STAMPS it —
    /// before a single member has run. Only the pass knows whether that stamp
    /// turned out to be true, so the plan carries a hook that receives the
    /// report and can put a gate back.
    ///
    /// `nil` report means the pass never ran at all (it was superseded or
    /// cancelled before `run`), which is the strongest case of "spent nothing".
    /// It is invoked exactly once, from inside the pass's own task, so it needs
    /// no `Task { }` of its own and cannot outlive the pass.
    let onSettle: (@Sendable (ForegroundPassReport?) async -> Void)?

    init(legs: [ForegroundLeg], onSettle: (@Sendable (ForegroundPassReport?) async -> Void)? = nil) {
        self.legs = legs
        self.onSettle = onSettle
    }

    var members: [ForegroundMember] {
        legs.flatMap { $0.steps.map(\.member) }
    }
}

// MARK: - The session a member runs inside

/// The identity a pass belongs to, and the only gate through which a member may
/// publish.
///
/// Two fences, deliberately both: the coordinator's own pass generation (a newer
/// foreground has superseded this one) and the app-wide
/// ``AuthenticatedSessionLease`` (a different account, or the same account after
/// a re-admission). Cancellation alone is not enough — a member that has already
/// completed its `await` is not cancelled, it is simply late.
final class ForegroundSession: Sendable {
    let generation: UInt64
    private let lease: AuthenticatedSessionLease?
    private let generationIsCurrent: @Sendable (UInt64) -> Bool

    init(
        generation: UInt64,
        lease: AuthenticatedSessionLease?,
        generationIsCurrent: @escaping @Sendable (UInt64) -> Bool
    ) {
        self.generation = generation
        self.lease = lease
        self.generationIsCurrent = generationIsCurrent
    }

    /// Whether this pass still owns the foreground.
    var isCurrent: Bool {
        !Task.isCancelled && generationIsCurrent(generation) && (lease?.isCurrent ?? true)
    }

    /// Runs `body` only if this session is still the current one, and reports
    /// whether it ran.
    ///
    /// Publication is a **comparison**, never an assignment — 09-04's
    /// presenter shape. The check happens after the member's own `await`s have
    /// already returned, which is exactly the window a stale result arrives in.
    @discardableResult
    func publish(_ body: () async -> Void) async -> Bool {
        guard isCurrent else { return false }
        await body()
        return true
    }
}

// MARK: - What a pass reports

/// How a pass ended.
enum ForegroundPassOutcome: String, Sendable {
    /// Every member ran to completion.
    case completed
    /// A member threw.
    case failed
    /// The deadline fired before the members finished.
    case deadlineExpired
    /// The owner was cancelled — a scene change, or a new pass superseding this
    /// one.
    case cancelled
}

/// One observed transition of one member.
struct ForegroundPassEvent: Sendable, Equatable {
    enum Phase: String, Sendable {
        case started
        case finished
        case cancelled
        case failed
        /// Never started, because the session was no longer current when the
        /// leg reached it.
        case skipped
    }

    let member: ForegroundMember
    let phase: Phase
}

/// The census of one pass. Every figure in it is a count or an ordering.
struct ForegroundPassReport: Sendable {
    let generation: UInt64
    let outcome: ForegroundPassOutcome
    let events: [ForegroundPassEvent]
    /// Whether the children were still draining when the drain allowance
    /// elapsed. A non-cooperative adapter is a failing contract, not work to
    /// detach, so this is reported rather than worked around.
    let drainOverran: Bool

    func members(in phase: ForegroundPassEvent.Phase) -> [ForegroundMember] {
        events.filter { $0.phase == phase }.map(\.member)
    }

    func count(_ member: ForegroundMember, _ phase: ForegroundPassEvent.Phase) -> Int {
        events.filter { $0.member == member && $0.phase == phase }.count
    }

    /// Members that started and produced no terminal event — the ones that were
    /// still in flight when the pass returned. Must always be empty: a pass that
    /// returns while a child is still running has detached that child.
    var stillInFlight: [ForegroundMember] {
        members(in: .started).filter { member in
            count(member, .finished) + count(member, .cancelled) + count(member, .failed) == 0
        }
    }
}

/// The event log a pass writes as it runs.
///
/// A `Mutex` rather than an actor for 09-04's reason: it is written from inside
/// the members' own tasks, where an `await` would change the interleaving being
/// recorded.
final class ForegroundPassLedger: Sendable {
    private let storage = Mutex<[ForegroundPassEvent]>([])

    init() {}

    func record(_ member: ForegroundMember, _ phase: ForegroundPassEvent.Phase) {
        storage.withLock { $0.append(ForegroundPassEvent(member: member, phase: phase)) }
    }

    var events: [ForegroundPassEvent] {
        storage.withLock { $0 }
    }
}

// MARK: - The coordinator

/// The single owner of the foreground pass.
final class ForegroundCoordinator: Sendable {
    /// The bound a pass runs under.
    ///
    /// `250 + 50 = 300` is not a coincidence: B2, the project-guide foreground
    /// budget carried forward by 09-01, is 300 ms p95. Splitting it into a
    /// deadline and a cooperative drain allowance is what turns that budget from
    /// a hope into a structure — and a pass that reaches the deadline says so in
    /// its outcome rather than quietly reporting a 300 ms success.
    struct Budget: Sendable, Equatable {
        var deadline: Duration
        var drainAllowance: Duration

        static let standard = Budget(deadline: .milliseconds(250), drainAllowance: .milliseconds(50))
    }

    /// A process has exactly one foreground, which is what a type-level `let`
    /// says. It is reached this way rather than as a stored property on
    /// `AppContainer`, whose `file_length` is baselined at 812 and whose every
    /// added line raises that recorded ceiling — the same reasoning, and the
    /// same resolution, 09-05 recorded for `FirstFrameSignal.shared`. Every seam
    /// that consumes a coordinator takes one as a parameter, so nothing in a
    /// test touches this one.
    static let shared = ForegroundCoordinator()

    private struct State {
        var generation: UInt64 = 0
        var owner: Task<ForegroundPassReport?, Never>?
    }

    private let state = Mutex(State())
    private let clock: ForegroundClock
    let budget: Budget

    init(clock: ForegroundClock = ContinuousForegroundClock(), budget: Budget = .standard) {
        self.clock = clock
        self.budget = budget
    }

    var currentGeneration: UInt64 {
        state.withLock { $0.generation }
    }

    /// Starts a pass, retiring and draining any predecessor first.
    ///
    /// Synchronous on purpose: the scene-phase handler that calls it is a
    /// synchronous SwiftUI `onChange` closure, and a boundary that has to be
    /// awaited from there is a boundary that gets a fire-and-forget `Task`
    /// wrapped around it — which is the very shape this plan removes.
    @discardableResult
    func begin(_ plan: ForegroundPlan, lease: AuthenticatedSessionLease? = nil) -> Task<ForegroundPassReport?, Never> {
        let (generation, predecessor) = state.withLock { state -> (UInt64, Task<ForegroundPassReport?, Never>?) in
            state.generation &+= 1
            let prior = state.owner
            state.owner = nil
            return (state.generation, prior)
        }
        predecessor?.cancel()
        let task = Task { [weak self] () -> ForegroundPassReport? in
            // The explicit predecessor chain: the prior pass is cancelled above
            // and *awaited* here, so two passes can never be in flight at once.
            _ = await predecessor?.value
            guard let self, currentGeneration == generation, !Task.isCancelled else {
                // 14-05 — the pass never ran. That is still an outcome its plan
                // has to hear about: whatever the plan stamped when it was
                // built was stamped for work that did not happen.
                await plan.onSettle?(nil)
                return nil
            }
            let report = await run(plan, generation: generation, lease: lease)
            await plan.onSettle?(report)
            return report
        }
        let adopted = state.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.owner = task
            return true
        }
        if !adopted { task.cancel() }
        return task
    }

    /// Retires the current generation and cancels the pass that owns it.
    ///
    /// Called on an authentication change: the members of a pass that started
    /// under the previous account must not publish into the next one.
    func retire() {
        let prior = state.withLock { state -> Task<ForegroundPassReport?, Never>? in
            state.generation &+= 1
            let prior = state.owner
            state.owner = nil
            return prior
        }
        prior?.cancel()
    }

    /// Awaits whichever pass currently owns the foreground.
    func drain() async {
        _ = await state.withLock { $0.owner }?.value
    }

    // MARK: - One pass

    /// One foreground pass, from `.active` to a settled or truncated end.
    ///
    /// The `foreground.pass` interval is opened here and closed from a `defer`
    /// that is the only exit, so a thrown member, an expired deadline and a
    /// cancelled owner all close it — and all three close it *saying so*, which
    /// is what lets a trace tell a fast pass from a truncated one.
    private func run(
        _ plan: ForegroundPlan,
        generation: UInt64,
        lease: AuthenticatedSessionLease?
    ) async -> ForegroundPassReport {
        let ledger = ForegroundPassLedger()
        let session = ForegroundSession(generation: generation, lease: lease) { [weak self] candidate in
            self?.currentGeneration == candidate
        }
        let drain = ForegroundDrainFlag()
        let token = HLPerfSignpost.open(.foregroundPass)
        var outcome = ForegroundPassOutcome.completed
        defer { HLPerfSignpost.close(token, completed: outcome == .completed) }

        outcome = await drive(plan, session: session, ledger: ledger, drain: drain)
        let report = ForegroundPassReport(
            generation: generation,
            outcome: outcome,
            events: ledger.events,
            drainOverran: drain.overran
        )
        // 14-05 (J3) — say out loud what the pass did. Until now the ledger knew
        // which members never ran and nothing read it, so "did the dashboard
        // refresh run?" was answerable only from vibes. One line per pass, in
        // the diagnostics vocabulary 13-03 introduced: an outcome word, two
        // counts and closed-set member names. No identifier, no payload, no
        // route — a pass census is about SHAPE, and the shape is all an operator
        // needs.
        StoreEffectDiagnostics.recordForegroundPass(
            outcome: report.outcome.rawValue,
            finished: report.members(in: .finished).map(\.rawValue),
            skipped: report.members(in: .skipped).map(\.rawValue)
        )
        return report
    }

    /// The task group, its deadline child, and the drain that follows a
    /// cancellation.
    ///
    /// The legs are structured children, so they are cancelled with the group
    /// and awaited by it — there is no path on which this function returns while
    /// a member is still running. The deadline is a child too rather than a
    /// wrapper, because a wrapper that abandons its body is precisely the
    /// detachment this plan removes.
    private func drive(
        _ plan: ForegroundPlan,
        session: ForegroundSession,
        ledger: ForegroundPassLedger,
        drain: ForegroundDrainFlag
    ) async -> ForegroundPassOutcome {
        var outcome = ForegroundPassOutcome.completed
        var watchdog: Task<Void, Never>?
        await withThrowingTaskGroup(of: ForegroundChildResult.self) { group in
            for leg in plan.legs {
                group.addTask {
                    try await Self.runLeg(leg, session: session, ledger: ledger)
                    return .leg
                }
            }
            group.addTask { [clock, budget] in
                do {
                    try await clock.sleep(for: budget.deadline)
                } catch {
                    return .deadlineCancelled
                }
                return .deadlineExpired
            }
            var finishedLegs = 0
            var draining = false
            while true {
                do {
                    guard let result = try await group.next() else { break }
                    switch result {
                    case .leg:
                        finishedLegs += 1
                        // The last leg cancels the deadline child; without this
                        // the group would sit on a timer nobody is waiting for.
                        if finishedLegs == plan.legs.count, !draining { group.cancelAll() }
                    case .deadlineExpired:
                        outcome = .deadlineExpired
                        draining = true
                        group.cancelAll()
                        watchdog = watchdog ?? startDrainWatchdog(drain)
                    case .deadlineCancelled:
                        break
                    }
                } catch {
                    outcome = .failed
                    draining = true
                    group.cancelAll()
                    watchdog = watchdog ?? startDrainWatchdog(drain)
                }
            }
        }
        watchdog?.cancel()
        await watchdog?.value
        if Task.isCancelled { outcome = .cancelled }
        return outcome
    }

    /// The drain allowance, as a thing that can be observed to have elapsed.
    ///
    /// It is a plain `Task` owned by ``drive(_:session:ledger:drain:)`` and
    /// cancelled before that function returns, so it cannot outlive the pass. It
    /// is deliberately *not* a way to abandon a child: an adapter that is still
    /// running when its allowance elapses is a failing contract, reported
    /// through ``ForegroundPassReport/drainOverran``, not work to detach.
    private func startDrainWatchdog(_ drain: ForegroundDrainFlag) -> Task<Void, Never> {
        Task { [clock, budget] in
            do {
                try await clock.sleep(for: budget.drainAllowance)
            } catch {
                return
            }
            drain.markOverran()
        }
    }

    /// One leg: its steps in order, its own interval, and the session check that
    /// stands between two of them.
    private static func runLeg(
        _ leg: ForegroundLeg,
        session: ForegroundSession,
        ledger: ForegroundPassLedger
    ) async throws {
        let opened = leg.interval.map { (interval: $0, state: HLPerfSignpost.begin($0)) }
        defer {
            if let opened { HLPerfSignpost.end(opened.interval, opened.state) }
        }
        for step in leg.steps {
            // The check *before* the await. `ForegroundSession.publish` is the
            // check after it; a member needs both, because a pass can be retired
            // either while a step is running or between two of them.
            guard session.isCurrent else {
                ledger.record(step.member, .skipped)
                continue
            }
            ledger.record(step.member, .started)
            do {
                try await step.work(session)
            } catch {
                ledger.record(step.member, .failed)
                throw error
            }
            ledger.record(step.member, Task.isCancelled ? .cancelled : .finished)
        }
    }
}

/// What a group child reports back.
private enum ForegroundChildResult: Sendable {
    case leg
    case deadlineExpired
    case deadlineCancelled
}

/// Whether the drain allowance elapsed before the children finished draining.
private final class ForegroundDrainFlag: Sendable {
    private let flag = Mutex(false)

    func markOverran() {
        flag.withLock { $0 = true }
    }

    var overran: Bool {
        flag.withLock { $0 }
    }
}
