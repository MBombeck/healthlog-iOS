import Foundation

// W1 (1.3.0) — `runOnce` and the pass body, moved out of
// `OutboxReplayService.swift` for `file_length` / `type_body_length` discipline
// when the watchdog (`+Watchdog`) wrapped them. The pass itself is unchanged
// apart from the three W1 marks: the guard is taken and released through
// `beginRun`/`endRun`, a superseded pass sends nothing more, and `runPhase`
// names the step for the watchdog's log lines.

extension OutboxReplayService {
    /// One pass over the outbox. Re-entrant-safe via the `isRunning` guard,
    /// which the watchdog (`+Watchdog`) releases when a pass hangs.
    public func runOnce() async {
        guard let generation = beginRun() else { return }
        let startedAt = clock()
        defer { endRun(generation, startedAt: startedAt) }
        await requeueOverBudgetRowsOnce()
        await runPass(generation)
    }

    private func runPass(_ generation: UInt64) async {
        // W1 — `runPhase` names the step in the watchdog's log lines.
        runPhase = "snapshot"
        let snapshot = await outbox.snapshot
        guard !snapshot.isEmpty else {
            runPhase = "transfer unconfirmed HealthKit rows"
            return await transferUnconfirmedHealthKitRows(now: clock())
        }

        HLLog.outbox.info("Outbox-Replay startet (\(snapshot.count, privacy: .public) Operations)")

        // v0.13 WS — resolve the currently signed-in user ONCE per pass so a
        // foreign-owned row is never replayed under the wrong bearer token.
        let currentUser = currentUserProvider()
        // audit-v0162 H1 (Opt 3) — is the server confirmed-reachable but degraded?
        runPhase = "server health probe"
        let degraded = await serverHealthDegraded?() ?? false
        let now = clock()
        idRemap.removeAll()
        // audit-v0162 M2 — entity ids whose earlier op failed retriably THIS
        // pass. A later update/delete on the same entity is SKIPPED (not
        // attempted → never 404-dropped) so a dependent write can never fire
        // before its create lands. Keyed on `clientEntityId`, which a create and
        // its dependents all share while the create is still offline.
        var blockedEntities: Set<String> = []

        // W1 — a pass the watchdog superseded sends nothing more.
        for op in snapshot where isCurrentRun(generation) {
            // Phase 07 — quarantine gate, ahead of every other decision. Two
            // on-disk shapes cannot be attributed by this build: a row with no
            // recorded owner while a named account is signed in, and a row whose
            // `kindRaw` this build cannot name. Both are health writes whose
            // owner or meaning is unknown, so both are retained untouched:
            // never transmitted under the ambient account, never deleted, never
            // re-stamped. The row stays in the snapshot so it remains
            // inspectable, and it is skipped every pass until a build (or an
            // account) can attribute it. See `OutboxQueue+HealthKit.swift`.
            if let reason = op.quarantineReason(currentUserID: currentUser) {
                // Kind and reason are finite operator-grade vocabulary; no
                // owner id, no payload, no idempotency key.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.outbox.warning(
                    "Op \(op.kind.rawValue, privacy: .public) quarantined (\(reason.rawValue, privacy: .public)) — retained, not transmitted"
                )
                continue
            }

            // v0.13 WS — cross-user binding gate. A row carries the user-id that
            // owned it at enqueue. On a shared device, User A's queued write can
            // survive A's sign-out (the `.userInitiated`/`.tokenExpired` paths
            // KEEP the outbox + cipher key), so when User B signs in the replay
            // loop would otherwise POST A's health data under B's token. Skip +
            // dead-letter any row whose owner doesn't match the current user.
            // Build 273 (sync audit A11) — RETAIN, never delete. The row is
            // another user's health write; it replays when that user signs in
            // again and is invisible to everyone else meanwhile. Deleting it
            // here (the pre-273 behaviour, logged as "dead-lettered") destroyed
            // User A's queued writes the moment User B signed in.
            if let owner = op.ownerUserID, owner != currentUser {
                HLLog.outbox.warning(
                    "Op \(op.kind.rawValue, privacy: .public) owner-mismatch — retained for its owner, not transmitted"
                )
                continue
            }

            // Rows this pass does not send (`holdsThisPass`, in this order):
            // Audit B-2 — a row the server already has only owes its local
            // delete, finished ahead of the hold gate on purpose (a delivered
            // row is not failing and must never age into the DLQ); C4 — a row
            // unconfirmed past the server's idempotency window is dead-lettered
            // before it could go out as a second record; then the budget and
            // back-off holds of `isOnHoldThisPass`.
            //
            // One gate call, so the loop stays inside its complexity budget.
            if await holdsThisPass(op, now: now) { continue }

            // audit-v0162 M2 — dependent-op guard: an earlier op for this entity
            // failed retriably this pass, so skip its dependents entirely.
            if let key = op.clientEntityId, blockedEntities.contains(key) { continue }

            do {
                runPhase = "dispatch \(op.kind.rawValue)"
                let createdServerId = try await pausingOnRateLimit(op, passStartedAt: now) { try await dispatch(op) }
                try await onReplaySuccess(op, createdServerId: createdServerId, generation: generation)
            } catch let error where Self.isInterruption(error) {
                return onInterrupted(op) // C4 — "stopped", not "no": row untouched, the pass ends.
            } catch where !isCurrentRun(generation) {
                return onSuperseded(op) // 1.4 (S5) — the pass that replaced this one owns the row.
            } catch let err as HLError where err.shouldPersistToOutbox {
                // audit-v0162 M2 — block dependents of this entity for the pass.
                if let key = op.clientEntityId { blockedEntities.insert(key) }
                await onRetriableFailure(op, err: err, degraded: degraded, now: now)
            } catch let err as DecodingError {
                // Audit B-3 — our own stored payload no longer decodes: retained.
                await onUndecodablePayload(op, error: err, now: now)
            } catch {
                await blockedEntities.formUnion(holdingDependents(op, afterNonRetriable: error, now: now))
            }
        }

        await finishPass(generation, now: now)
    }
}
