import Foundation

// `runOnce` and the pass body, moved out of
// `OutboxReplayService.swift` for `file_length` / `type_body_length` discipline
// when the watchdog (`+Watchdog`) wrapped them. The pass itself is unchanged
// apart from the three W1 marks: the guard is taken and released through
// `beginRun`/`endRun`, a superseded pass sends nothing more, and `runPhase`
// names the step for the watchdog's log lines.

extension OutboxReplayService {
    /// One pass over the outbox. Re-entrant-safe via the `isRunning` guard,
    /// which the watchdog (`+Watchdog`) releases when a pass hangs.
    public func runOnce() async {
        // An outside trigger: the self-armed passes may start counting again.
        rerun.streak = 0
        await runGuardedPass()
    }

    /// The pass behind every trigger, including the one the service arms for
    /// itself (`+Rerun`).
    func runGuardedPass() async {
        guard let generation = beginRun() else {
            // The running pass began with what was true then: the account
            // signed in, the rows queued. What this trigger had to add is
            // caught up on when that pass ends.
            rerun.triggerTurnedAway = true
            return
        }
        // A pass that begins now is later than every trigger so far.
        rerun.triggerTurnedAway = false
        rerun.failedThisPass = false
        let startedAt = clock()
        await requeueOverBudgetRowsOnce()
        // #6 — no pass without a session (every row would only meet a 401),
        // and an access token past its expiry is renewed first: the
        // owner-leased HealthKit routes never refresh on a 401 of their own.
        if await sessionGate?.admitsPass() ?? true {
            await runPass(generation)
        } else {
            HLLog.outbox.info("Outbox-Replay ohne Sitzung — Durchgang ausgelassen")
        }
        let ownedTheGuard = isCurrentRun(generation)
        endRun(generation, startedAt: startedAt)
        // One pass for all the triggers this one turned away. It is a pass
        // like any other, so it is followed by another only when a trigger of
        // its own was turned away: no pass arms the next by itself.
        guard ownedTheGuard, rerun.triggerTurnedAway else { return }
        await runGuardedPass()
    }

    private func runPass(_ generation: UInt64) async {
        // `runPhase` names the step in the watchdog's log lines.
        runPhase = "snapshot"
        let snapshot = await outbox.snapshot
        await reportUnreadableRows()
        guard !snapshot.isEmpty else {
            runPhase = "transfer unconfirmed HealthKit rows"
            return await transferUnconfirmedHealthKitRows(now: clock())
        }

        HLLog.outbox.info("Outbox-Replay startet (\(snapshot.count, privacy: .public) Operations)")

        // audit-v0162 H1 (Opt 3) — is the server confirmed-reachable but degraded?
        runPhase = "server health probe"
        let degraded = await serverHealthDegraded?() ?? false
        let now = clock()
        idRemap.removeAll()
        // Entity ids whose earlier op failed retriably THIS
        // pass. A later update/delete on the same entity is SKIPPED (not
        // attempted → never 404-dropped) so a dependent write can never fire
        // before its create lands. Keyed on `clientEntityId`, which a create and
        // its dependents all share while the create is still offline.
        var blockedEntities: Set<String> = []

        // A pass the watchdog superseded sends nothing more.
        for op in snapshot where isCurrentRun(generation) {
            // #2 — the signed-in user is read again for every row: a sign-out
            // and another sign-in can land while the pass works through a
            // backlog or sits out a 429 pause.
            let currentUser = currentUserProvider()
            // Quarantine gate, ahead of every other decision. Two
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

            // Cross-user binding gate. A row carries the user-id that
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
            // A row the server already has only owes its local
            // delete, finished ahead of the hold gate on purpose (a delivered
            // row is not failing and must never age into the DLQ); C4 — a row
            // unconfirmed past the server's idempotency window is dead-lettered
            // before it could go out as a second record; then the budget and
            // back-off holds of `isOnHoldThisPass`.
            //
            // One gate call, so the loop stays inside its complexity budget.
            if await holdsThisPass(op, now: now) { continue }

            // Dependent-op guard: an earlier op for this entity
            // failed retriably this pass, so skip its dependents entirely.
            if let key = op.clientEntityId, blockedEntities.contains(key) { continue }

            do {
                runPhase = "dispatch \(op.kind.rawValue)"
                let createdServerId = try await pausingOnRateLimit(op, passStartedAt: now) {
                    try await dispatchBoundToOwner(op)
                }
                try await onReplaySuccess(op, createdServerId: createdServerId, generation: generation)
            } catch let error where Self.isInterruption(error) {
                return onInterrupted(op) // "stopped", not "no": row untouched, the pass ends.
            } catch where !isCurrentRun(generation) {
                return onSuperseded(op) // The pass that replaced this one owns the row.
            } catch let err as HLError where err.shouldPersistToOutbox {
                // Block dependents of this entity for the pass.
                if let key = op.clientEntityId { blockedEntities.insert(key) }
                await onRetriableFailure(op, err: err, degraded: degraded, now: now)
            } catch let err as DecodingError {
                // Our own stored payload no longer decodes: retained.
                await onUndecodablePayload(op, error: err, now: now)
            } catch {
                await blockedEntities.formUnion(holdingDependents(op, afterNonRetriable: error, now: now))
            }
        }

        await finishPass(generation, now: now)
        armRerunIfWaiting(after: snapshot, currentUser: currentUserProvider(), generation: generation)
    }
}
