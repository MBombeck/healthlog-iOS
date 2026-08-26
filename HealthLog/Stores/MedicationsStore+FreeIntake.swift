import Foundation

/// **Build 6.1 — free / back-dated intake logging.** Split out of
/// `MedicationsStore+IntakeMutations.swift` so that file stays under SwiftLint's
/// `file_length` ceiling (pure code movement, no behaviour change).
public extension MedicationsStore {
    /// Log a free, back-datable intake for `medicationId` — the "ich habe eine
    /// Dosis genommen/ausgelassen, trage sie nach"-flow that does NOT need a
    /// pending slot row. Routes to `MedicationsRepository.logIntake`
    /// (`POST /api/medications/{id}/intake`, idempotency + outbox); standalone
    /// mode persists to the local mirror instead.
    ///
    /// Optimistic-write contract mirrors the other mark paths:
    /// - `.success` — the server (or mirror) accepted; the today-intakes key is
    ///   invalidated so the next observe pulls the canonical row (the logged
    ///   dose may or may not fall on today), and the card compliance snapshot
    ///   for the medication is refreshed.
    /// - `.queued` — a retriable network error; the repo durably enqueued the
    ///   exact wire body on the outbox (replays on next reachability).
    /// - `.failed` — a non-retriable server error (typically a 422 schema/slot
    ///   reject); surfaced on `error` for the caller to render inline.
    ///
    /// `takenAt` is the back-datable administration instant (ignored on a skip);
    /// `scheduledFor` defaults to `takenAt` server-side when nil. `doseTaken` is
    /// the optional actual-dose deviation; `forceSlotInstant` an optional
    /// late-take pin onto a real slot anchor.
    @discardableResult
    func logIntakeFree(
        medicationId: String,
        takenAt: Date,
        skipped: Bool,
        scheduledFor: Date? = nil,
        doseTaken: String? = nil,
        injectionSite: InjectionSite? = nil,
        forceSlotInstant: Date? = nil
    ) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        do {
            if isStandalone() {
                // Standalone has no server route — persist to the local mirror
                // (the free-log maps to a taken/skipped dose at `takenAt`).
                _ = try await repo.recordStandaloneIntake(
                    medicationId: medicationId,
                    scheduledAt: scheduledFor ?? takenAt,
                    status: skipped ? .skipped : .taken,
                    takenAt: takenAt,
                    injectionSite: injectionSite
                )
            } else {
                _ = try await repo.logIntake(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    takenAt: takenAt,
                    skipped: skipped,
                    doseTaken: doseTaken,
                    injectionSite: injectionSite,
                    forceSlotInstant: forceSlotInstant
                )
            }
            try sessionLease.requireCurrent()
            // The logged dose may land on today or a past day; invalidate the
            // today key (pull the canonical row on next observe) + the intake
            // aggregates rather than optimistically patching a possibly-off-day
            // row into `todayIntakes`.
            if let swr {
                await swr.invalidate([todayIntakesKey] + intakeSiblingKeys)
                try sessionLease.requireCurrent()
            }
            await refreshCardComplianceSnapshot(for: medicationId, sessionLease: sessionLease)
            try sessionLease.requireCurrent()
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = err
            return err.shouldPersistToOutbox ? .queued : .failed(err)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            return .failed(wrapped)
        }
    }
}
