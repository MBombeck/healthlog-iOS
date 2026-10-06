import Foundation

// #110 — the outbox replay against the server's rate limits.
//
// Server v1.39.0 put the per-record creates (measurements, mood entries,
// medication intakes, labs, biomarkers, custom-metric entries, cycle day logs,
// allergies, vaccinations, encounters) on one per-account bucket, 300 writes
// per 60 s, refused as 429 with `meta.errorCode == "record_write.rate_limited"`.
// The batch routes (measurements, nutrients, cycle bulk, workouts) keep their
// own 60-per-minute bucket and refuse without a code. A long offline backlog
// replays exactly the loop the new bucket exists to stop.
//
// Before this, a 429 that survived `APIClient`'s in-request retries was an
// ordinary retriable failure: the row's attempt was COUNTED, and every later
// row of the same pass met the same 429 and burned its attempt too. After
// eight such passes and seven days a row was dead-lettered — and a HealthKit
// page moved into the skip register as "not confirmed" — although the server
// had never refused it, only asked it to wait.
//
// Now a 429, with or without its code, is always "not yet":
//
//   * the row keeps its attempt count, its `lastAttemptAt` and its place;
//   * within one pass the replay sits the named wait out (up to
//     ``OutboxReplayService/rateLimitPauseBudget`` in total) and re-sends the
//     SAME row under the same idempotency key, then carries on with the rest;
//   * a wait the pass cannot absorb ends the pass and holds the whole queue
//     until the named instant; the next trigger after it resumes where this
//     one stopped.

/// #110 — the replay's rate-limit memory. Lives as long as the service (one
/// per process); a relaunch simply asks the server again.
struct OutboxRateLimitState {
    /// No row is sent before this instant.
    var holdUntil: Date?
    /// 429s in a row without a delivery in between — drives the fallback
    /// back-off when the server names no wait.
    var consecutive = 0
    /// The pass (by its start instant) the pause budget below belongs to.
    var passStartedAt: Date?
    /// Seconds this pass has already paused.
    var pausedThisPass: TimeInterval = 0
}

/// #110 — how the replay waits. Task-local so a test binds an instant,
/// recording sleeper instead of waiting on the wall clock.
enum OutboxReplayPause {
    @TaskLocal static var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

extension OutboxReplayService {
    /// Total seconds one pass may pause for 429s before it hands the wait to
    /// the next pass. One bucket window.
    static let rateLimitPauseBudget: TimeInterval = 60
    /// First fallback wait when a 429 names none; doubles per consecutive 429.
    static let rateLimitFallbackBase: TimeInterval = 30
    /// Ceiling of the fallback back-off.
    static let rateLimitFallbackCeiling: TimeInterval = 600
    /// Ceiling of any hold, so a garbled header cannot park the queue for days.
    static let rateLimitHoldCeiling: TimeInterval = 3600

    /// `true` while the server's named wait has not run out.
    func isRateLimitHeld(now: Date) -> Bool {
        guard let until = rateLimit.holdUntil else { return false }
        return now < until
    }

    /// Runs `dispatch` for `op`; on a 429 sits the named wait out and re-sends the same
    /// row, as long as this pass's pause budget allows. A wait beyond it is
    /// rethrown as `HLError.rateLimited` carrying the wait, which
    /// ``onRateLimited(_:retryAfter:)`` turns into a hold.
    func pausingOnRateLimit(
        _ op: OutboxQueue.Operation,
        passStartedAt: Date,
        dispatch: () async throws -> Void
    ) async throws {
        if rateLimit.passStartedAt != passStartedAt {
            rateLimit.passStartedAt = passStartedAt
            rateLimit.pausedThisPass = 0
        }
        while true {
            do {
                try await dispatch()
                rateLimit.consecutive = 0
                return
            } catch let HLError.rateLimited(retryAfter) {
                rateLimit.consecutive += 1
                let wait = rateLimitWait(retryAfter)
                guard rateLimit.pausedThisPass + wait <= Self.rateLimitPauseBudget else {
                    throw HLError.rateLimited(retryAfter: wait)
                }
                rateLimit.pausedThisPass += wait
                // Kind and a whole-second wait only — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.outbox.info(
                    "Op \(op.kind.rawValue, privacy: .public) rate-limited — pausing \(Int(wait.rounded(.up)), privacy: .public)s"
                )
                do {
                    try await OutboxReplayPause.sleep(wait)
                } catch {
                    // Cancelled mid-pause (a background window closing). Still
                    // a wait, never a refusal: the row must not reach the
                    // non-retriable delete.
                    throw HLError.rateLimited(retryAfter: wait)
                }
            }
        }
    }

    /// A 429 the pass could not sit out. Nothing about the row changes — no
    /// attempt counted, no `lastAttemptAt`, no `lastError` — so it can never age
    /// toward the dead-letter lane or the skip register on a rate limit, and it
    /// keeps its place ahead of anything queued after it. The whole queue holds
    /// until the named instant.
    func onRateLimited(_ op: OutboxQueue.Operation, retryAfter: TimeInterval?) {
        let wait = rateLimitWait(retryAfter)
        rateLimit.holdUntil = clock().addingTimeInterval(wait)
        // Kind and a whole-second wait only — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.warning(
            "Op \(op.kind.rawValue, privacy: .public) rate-limited — replay holds \(Int(wait.rounded(.up)), privacy: .public)s, attempt not counted"
        )
    }

    /// The server's wait (at least a second, at most ``rateLimitHoldCeiling``),
    /// or a doubling fallback when it named none.
    func rateLimitWait(_ retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite {
            return min(max(retryAfter, 1), Self.rateLimitHoldCeiling)
        }
        let exponent = Double(min(max(rateLimit.consecutive - 1, 0), 10))
        return min(Self.rateLimitFallbackBase * pow(2, exponent), Self.rateLimitFallbackCeiling)
    }
}
