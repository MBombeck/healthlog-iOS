import Foundation

/// **H4 (server v1.16.11) — "take all due doses" batch confirm.**
///
/// When ≥2 doses are due, the operator can confirm them all in one action. Each
/// dose still rides the EXISTING single-intake path (`markIntakeQuick`), which
/// owns its own optimistic patch, idempotency key, and Outbox enqueue — so the
/// batch is just a sequential fan-out, never a client-side dedup or recompute
/// (the double-dose hazard stays the server's `(med, scheduledFor)` upsert).
/// Failures are counted, not swallowed: the caller surfaces the tally.
public extension MedicationsStore {
    /// Result of a batch take-all: how many doses landed (success OR queued for
    /// replay) vs. hard-failed.
    struct BatchIntakeOutcome: Sendable, Equatable {
        public let confirmed: Int
        public let failed: Int
        public var total: Int {
            confirmed + failed
        }

        public var allConfirmed: Bool {
            failed == 0 && confirmed > 0
        }
    }

    /// Mark every supplied intake as taken, sequentially, through the canonical
    /// `markIntakeQuick` path. `.success` and `.queued` both count as confirmed
    /// (queued replays on reachability); `.failed` increments the failure tally.
    func markAllDueQuick(intakeIds: [String], now: Date = .now) async -> BatchIntakeOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            return BatchIntakeOutcome(confirmed: 0, failed: intakeIds.count)
        }
        var confirmed = 0
        var failed = 0
        for intakeId in intakeIds {
            let outcome = await markIntakeQuick(intakeId: intakeId, status: .taken, now: now)
            guard authenticatedEffectIsCurrent(sessionLease) else {
                return BatchIntakeOutcome(confirmed: confirmed, failed: failed + 1)
            }
            switch outcome {
            case .success, .queued:
                confirmed += 1
            case .failed:
                failed += 1
            }
        }
        return BatchIntakeOutcome(confirmed: confirmed, failed: failed)
    }
}
