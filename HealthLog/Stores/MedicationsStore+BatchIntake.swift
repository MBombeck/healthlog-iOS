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
    /// quick-mark path. `.success` and `.queued` both count as confirmed
    /// (queued replays on reachability); `.failed` increments the failure tally.
    ///
    /// **#191 point 8 — one Undo for the whole batch.** Each landed mark
    /// keeps its exact inverse; one toast ("3 intakes recorded") offers a
    /// single Undo that reverses every one of them, instead of a toast per
    /// dose of which only the last could be undone.
    func markAllDueQuick(intakeIds: [String], now: Date = .now) async -> BatchIntakeOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            return BatchIntakeOutcome(confirmed: 0, failed: intakeIds.count)
        }
        var confirmed = 0
        var failed = 0
        var undos: [IntakeMarkUndo] = []
        for intakeId in intakeIds {
            let (outcome, undo) = await markIntakeQuickReturningUndo(intakeId: intakeId, status: .taken, now: now)
            guard authenticatedEffectIsCurrent(sessionLease) else {
                return BatchIntakeOutcome(confirmed: confirmed, failed: failed + 1)
            }
            switch outcome {
            case .success, .queued:
                confirmed += 1
                if let undo { undos.append(undo) }
            case .failed:
                failed += 1
            }
        }
        if !undos.isEmpty {
            let batch = undos
            undoCoordinator?.enqueue(message: Self.batchUndoMessage(count: batch.count)) { [weak self] in
                guard let self, sessionLease.isCurrent else { return }
                await undoBatch(batch)
            }
        }
        return BatchIntakeOutcome(confirmed: confirmed, failed: failed)
    }

    /// "3 intakes recorded" (the web's toast after "take all due").
    nonisolated static func batchUndoMessage(count: Int) -> String {
        String(format: String(localized: "med.take_all.recorded", defaultValue: "%lld intakes recorded"), count)
    }

    /// Reverses a batch, newest first, each through its own exact inverse.
    func undoBatch(_ undos: [IntakeMarkUndo]) async {
        for undo in undos.reversed() {
            await undoIntakeMark(undo)
        }
    }
}
