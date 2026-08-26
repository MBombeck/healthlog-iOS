import Foundation

/// **The dead-letter surface of `OutboxReplayService`.**
///
/// Split out of `OutboxReplayService.swift` for the same reason
/// `OutboxQueue+WriteAhead.swift` was: `file_length` and `type_body_length`
/// discipline. Nothing here changed isolation — every member is still on the
/// actor — and the four members it reaches (`outbox`, `maxAttempts`,
/// `deadLetterMinAge`, `onDeadLettered`, `deadLetteredBeforeSink`) are
/// `internal` rather than `private` for exactly this file, mirroring the
/// `measurementsRepo` / `illnessRepo` seams the dispatch extensions already use.
///
/// **Phase 09 / plan 09-05 — the ordering this file exists to make true.**
/// `runOnce` is reachable from three production routes, and only one of them is
/// the bootstrap task that attaches the sink:
///
/// * `AppContainer.startOutboxReplayBootstrap` — attaches, *then* replays;
/// * `AppContainer.wireOutboxBGDrainHook` — a `BGProcessingTask` wake, which
///   calls `runOnce` directly;
/// * `AppContainer.foregroundDrainOutboxIfReachable` — the A7-M2 re-drain,
///   likewise direct.
///
/// The last two can win the race against a composition that has only just
/// started its detached bootstrap. A pass that wins it used to hand its
/// dead-letter count to `nil`, and that count was gone for good: the rows are
/// flagged on disk by the same pass, so no later pass ever reports them "newly"
/// dead again, and `SyncStateStore` went on showing a drained success that never
/// happened. The count is now retained until a sink exists.
public extension OutboxReplayService {
    /// Whether an honest DLQ sink is installed. The launch-order contract is a
    /// statement about this flag at a moment in time: the bootstrap owner must
    /// have attached before it awaits anything else.
    var isDeadLetterSinkAttached: Bool {
        onDeadLettered != nil
    }

    /// Composition-root wiring — attach the honest DLQ sink after construction
    /// (the `SyncStateStore` is built after this service). Idempotent.
    ///
    /// Also the flush point for anything a pass dead-lettered before a sink
    /// existed, so the first replay of a launch cannot outrun its observer. The
    /// retained count is cleared **before** the `await`, so a second attach
    /// racing the first cannot publish the same rows twice.
    ///
    /// The retained value is a running total rather than a queue of events: the
    /// sink's contract is "N rows were newly abandoned", and two publications of
    /// 1 say the same thing to it as one publication of 2.
    func attachDeadLetterSink(_ sink: @escaping @Sendable (Int) async -> Void) async {
        onDeadLettered = sink
        let buffered = deadLetteredBeforeSink
        deadLetteredBeforeSink = 0
        guard buffered > 0 else { return }
        await sink(buffered)
    }

    /// audit-v0162 H1 (Opt 3 + Opt 1) — gated dead-letter sweep: flag (never
    /// delete) rows that have BOTH exhausted the retry budget AND aged past
    /// `deadLetterMinAge`. Flagged rows stay recoverable (count + re-submit);
    /// surface an HONEST failure count so the footer never fakes success.
    ///
    /// Split out of `runOnce` when Phase 07 added the quarantine gate, so the
    /// pass loop stays inside its complexity budget.
    internal func sweepDeadLetters(now: Date) async {
        guard let newlyDead = try? await outbox.markDeadLetters(
            maxAttempts: maxAttempts, minAge: deadLetterMinAge, now: now
        ), !newlyDead.isEmpty else { return }
        for op in newlyDead {
            HLLog.outbox.error(
                "Op \(op.kind.rawValue, privacy: .public) dead-lettered after \(op.attempts, privacy: .public) attempts (recoverable)"
            )
        }
        guard let sink = onDeadLettered else {
            deadLetteredBeforeSink += newlyDead.count
            return
        }
        await sink(newlyDead.count)
    }
}
