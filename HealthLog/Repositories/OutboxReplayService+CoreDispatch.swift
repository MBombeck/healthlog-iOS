import Foundation

// audit-v0162 — split out of `OutboxReplayService.swift` to keep the actor body
// under the `type_body_length` + `file_length` budgets (mirrors `+Records` /
// `+LabsIllness`). Holds (a) the per-op replay-outcome helpers the `runOnce`
// loop delegates to and (b) the lower-coupling dispatch arms (cycle / workout /
// coach / therapy-log). Pure move — behaviour-identical.

extension OutboxReplayService {
    // MARK: - Per-op replay outcome (audit-v0162 H1 / H-4)

    /// audit-v0162 H1 — the two reasons to leave a live row untouched this pass.
    /// Over budget: the age-gated sweep at the end of the pass owns it, and it is
    /// never deleted here, so the write stays recoverable. Inside the back-off
    /// window: rapid replay triggers (a foreground edge and a reachability edge
    /// seconds apart) must not burn several attempts within minutes.
    func isOnHoldThisPass(_ op: OutboxQueue.Operation, now: Date) -> Bool {
        if op.attempts >= maxAttempts { return true }
        if let last = op.lastAttemptAt { return now.timeIntervalSince(last) < attemptBackoff }
        return false
    }

    /// Audit B-2 — has the server already taken this operation? True from the
    /// persisted stamp, or from this process' own record when the stamp itself
    /// could not be written.
    func isDelivered(_ op: OutboxQueue.Operation) -> Bool {
        op.delivered || deliveredIDs.contains(op.id)
    }

    /// A dispatch succeeded — and the order of what follows is the fix.
    ///
    /// **Audit B-11 (remap first).** When the op was a `create` that just landed
    /// with a real server id, every sibling (a queued update/delete on the same
    /// `optimistic-<uuid>`) is retargeted so the dependent write addresses the
    /// real record, not a 404-ing optimistic id. A remap that FAILS used to be
    /// swallowed by `try?`, which left the dependents pointing at an id the
    /// server never had — they replayed into a 404 and were discarded (B-3).
    /// It is now a replay failure of this op: the create keeps its row, the
    /// attempt is counted, and the next pass re-sends it under the SAME
    /// idempotency key — which the server answers with the first response
    /// (`X-Idempotent-Replay: true`), so the remap gets another chance without a
    /// second record ever being created.
    ///
    /// **Audit B-2 (delivered before remove).** Only then is the row marked
    /// delivered and removed — in that order, so a `remove` that fails cannot
    /// put an operation the server already has back on the wire.
    func onReplaySuccess(_ op: OutboxQueue.Operation) async throws {
        if let serverId = lastCreatedServerId,
           let optimisticId = op.clientEntityId,
           optimisticId.hasPrefix("optimistic-")
        {
            idRemap[optimisticId] = serverId
            do {
                _ = try await outbox.applyEntityRemap(from: optimisticId, to: serverId)
            } catch {
                // Retriable protocol uncertainty, not a verdict: the write
                // landed, but the queue is not yet consistent with it. Same
                // posture the workout-batch arm uses; the message names no id.
                throw HLError.network(.other("entity remap not persisted"))
            }
        }
        deliveredIDs.insert(op.id)
        do {
            try await outbox.markDelivered(id: op.id)
        } catch {
            // The in-memory record above still guards this process; a restart
            // before the row is removed is the residual window, and it is the
            // one the persisted stamp exists to close.
            let sanitized = LogSanitizer.redact(String(describing: error))
            // Kind is public operator state; even sanitized error text stays private.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.error(
                "Op \(op.kind.rawValue, privacy: .public) delivered-Marke nicht persistiert: \(sanitized, privacy: .private)"
            )
        }
        // Kind is a finite operator-grade enum; no operation id or payload.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info("Op \(op.kind.rawValue, privacy: .public) erfolgreich repliziert")
        await completeDelivery(op)
    }

    /// **Audit B-2 — finish a write the server already took.** Removes the row;
    /// a failure leaves it in place, still stamped delivered, so the next drain
    /// lands here again instead of on the wire. Never counts an attempt and
    /// never reports a discard: nothing was lost, a local delete is merely owed.
    func completeDelivery(_ op: OutboxQueue.Operation) async {
        do {
            try await outbox.remove(id: op.id)
            deliveredIDs.remove(op.id)
        } catch {
            let sanitized = LogSanitizer.redact(String(describing: error))
            // Kind is public operator state; even sanitized error text stays private.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.warning(
                "Op \(op.kind.rawValue, privacy: .public) zugestellt, lokales Entfernen offen: \(sanitized, privacy: .private)"
            )
        }
    }

    /// A retriable failure (`shouldPersistToOutbox`): keep the row. When the
    /// server is KNOWN-degraded and the failure is a 5xx/429, stamp the attempt
    /// time (back-off) but do NOT burn the retry budget toward dead-lettering —
    /// the write did not fail on its own merits (audit-v0162 H1 Opt 3).
    func onRetriableFailure(_ op: OutboxQueue.Operation, err: HLError, degraded: Bool) async {
        let sanitized = LogSanitizer.redact(err.localizedDescription)
        if degraded, err.is5xxOrRateLimited {
            try? await outbox.touchAttempt(id: op.id, lastError: sanitized)
            // Kind is public operator state; even sanitized error text remains private.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.warning(
                "Op \(op.kind.rawValue, privacy: .public) retriable (server degraded — attempt not counted): \(sanitized, privacy: .private)"
            )
        } else {
            try? await outbox.incrementAttempts(id: op.id, lastError: sanitized)
            // Kind is public operator state; even sanitized error text remains private.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.warning("Op \(op.kind.rawValue, privacy: .public) retriable: \(sanitized, privacy: .private)")
        }
    }

    /// A non-retriable failure (a permanent 4xx, an unroutable kind): drop the
    /// row so it can't block the queue — but **audit B-3**: never in silence.
    /// The pre-fix path left one log line behind, so a validation change on the
    /// server or a resource deleted elsewhere ate offline edits with no trace on
    /// any surface. Every drop now reaches the same honest failure count the
    /// dead-letter lane feeds, named by kind and machine reason.
    func onNonRetriable(_ op: OutboxQueue.Operation, error: Error) async {
        let sanitized = LogSanitizer.redact(String(describing: error))
        // Kind is public operator state; even sanitized error text remains private.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.warning("Op \(op.kind.rawValue, privacy: .public) verworfen: \(sanitized, privacy: .private)")
        try? await outbox.remove(id: op.id)
        await publishDiscard(.init(kind: op.kind.rawValue, reason: Self.discardReason(for: error)))
    }

    /// **Audit B-3 — our own stored payload no longer decodes.** The CI run of
    /// 8 September showed the live case ("Op createMeasurement verworfen:
    /// DecodingError … not valid JSON"): a payload an older build wrote and this
    /// one cannot read used to be DELETED, as if the server had refused it. It
    /// is the opposite — the server never saw it, and only this build's reader
    /// is at fault — so the row is retained as a recoverable dead-letter
    /// (counted, out of the replay snapshot, re-submittable) instead.
    func onUndecodablePayload(_ op: OutboxQueue.Operation, error: DecodingError, now: Date) async {
        let sanitized = LogSanitizer.redact(String(describing: error))
        // Kind is public operator state; even sanitized error text remains private.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.error(
            "Op \(op.kind.rawValue, privacy: .public) dead-lettered — Payload nicht lesbar: \(sanitized, privacy: .private)"
        )
        do {
            try await outbox.markDeadLetter(id: op.id, lastError: sanitized, now: now)
        } catch {
            // Marking failed: the row stays live and will be re-read next pass,
            // which is the safe direction (retained, never transmitted — the
            // decode fails before anything reaches the wire).
            HLLog.outbox.error("Outbox dead-letter mark failed: \(LogSanitizer.redact(String(describing: error)))")
        }
        await publishDiscard(.init(kind: op.kind.rawValue, reason: .payloadUnreadable))
    }

    /// Audit B-3 — name the failure in the finite vocabulary the surface reads.
    /// `HLError.decoding` is the SERVER's answer being unreadable (we cannot
    /// tell whether the write landed); `.unknown` is this build failing to route
    /// the op at all; everything else that reaches here is a stated refusal.
    static func discardReason(for error: Error) -> OutboxDiscardNotice.Reason {
        guard let hlError = error as? HLError else { return .unroutable }
        switch hlError {
        case .decoding: return .responseUnreadable
        case .unknown: return .unroutable
        default: return .serverRejected
        }
    }

    // MARK: - Lower-coupling dispatch arms

    /// v0.14.8 — cycle outbox kinds. Each replays under the persisted
    /// idempotency key (UPSERT-idempotent via `externalId`); a missing
    /// `cycleRepo` dead-letters (non-retriable) so an unwired build never
    /// busy-loops.
    func dispatchCycle(_ op: OutboxQueue.Operation) async throws {
        guard let cycleRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — cycleRepo unwired")
        }
        switch op.kind {
        case .logCycleDayLog:
            let p = try decoder.decode(OutboxQueue.Payloads.LogCycleDayLog.self, from: op.payload)
            try await cycleRepo.replayLogDayLog(write: p.write, idempotencyKey: op.idempotencyKey)
        case .updateCycleDayLog:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateCycleDayLog.self, from: op.payload)
            _ = try await cycleRepo.replayUpdateDayLog(id: p.id, patch: p.patch, idempotencyKey: op.idempotencyKey)
        case .deleteCycleDayLog:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteCycleDayLog.self, from: op.payload)
            try await cycleRepo.replayDeleteDayLog(id: p.id, idempotencyKey: op.idempotencyKey)
        case .cyclePeriod:
            let p = try decoder.decode(OutboxQueue.Payloads.CyclePeriod.self, from: op.payload)
            try await cycleRepo.replayPeriod(request: p.request, idempotencyKey: op.idempotencyKey)
        default:
            break
        }
    }

    /// v0.14.8 audit Wave A (C4.1) — replay path for `uploadWorkoutBatch`.
    /// Re-POSTs `POST /api/workouts/batch` with the persisted idempotency key
    /// (24h server envelope dedup) — and beyond that window the per-entry
    /// `externalId` UPSERT folds a batch that already landed into `duplicate`
    /// rows. A 2xx response is successful only when its per-entry outcomes
    /// completely cover the posted batch; ambiguous acceptance stays retryable
    /// under the original key. When the repo is unwired (tests / widget
    /// extension) the op is dropped as non-retriable so it can't wedge the
    /// queue.
    func dispatchWorkoutBatch(_ op: OutboxQueue.Operation) async throws {
        guard let workoutsRepo else {
            throw HLError.unknown("uploadWorkoutBatch replay skipped — workoutsRepo not wired")
        }
        let p = try decoder.decode(OutboxQueue.Payloads.UploadWorkoutBatch.self, from: op.payload)
        let response: WorkoutBatchResponseDTO
        do {
            if let ownerUserID = op.ownerUserID {
                // Capture after the pass-level owner gate, then let the repository
                // revalidate immediately before wire and after APIClient returns.
                // Its request pins this bearer across a possible 401 refresh.
                let authLease = try await outbox.captureAuthLease(requiringOwner: ownerUserID)
                response = try await workoutsRepo.replayUploadBatch(
                    p.workouts,
                    idempotencyKey: op.idempotencyKey,
                    authLease: authLease
                )
                try await outbox.validateAuthLease(authLease)
            } else {
                // Transitional pre-owner rows retain the established compatibility
                // path; no historical bearer generation exists to capture.
                response = try await workoutsRepo.replayUploadBatch(p.workouts, idempotencyKey: op.idempotencyKey)
            }
        } catch is OutboxQueue.OwnerLeaseError {
            // Session transitions are retryable protocol uncertainty, never a
            // reason to drop the PHI row. The message contains no owner/token.
            throw HLError.network(.other("authenticated session changed"))
        }
        do {
            try WorkoutBatchAcceptance.validate(postedCount: p.workouts.count, response: response)
        } catch let error as WorkoutBatchAcceptanceError {
            // HTTP accepted the envelope but did not prove durable per-entry
            // coverage. Keep this as retryable protocol uncertainty; the
            // acceptance error contains aggregate counts only.
            throw HLError.network(.other(error.description))
        }
    }

    /// W-B187 COACH-3 — replay the coach clarifying-question writes. Each
    /// re-issues under the persisted idempotency key (the server dedupes a
    /// replayed adoption against the stored prose, and exact-match dismissal is
    /// naturally idempotent). A missing `coachAboutMeRepo` dead-letters
    /// (non-retriable) so an unwired build never busy-loops.
    func dispatchCoachAboutMe(_ op: OutboxQueue.Operation) async throws {
        guard let coachAboutMeRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — coachAboutMeRepo unwired")
        }
        switch op.kind {
        case .coachAboutMeAdopt:
            let p = try decoder.decode(OutboxQueue.Payloads.CoachAboutMeAdopt.self, from: op.payload)
            _ = try await coachAboutMeRepo.replayAdopt(p.write, idempotencyKey: op.idempotencyKey)
        case .coachAboutMeDismissQuestion:
            let p = try decoder.decode(OutboxQueue.Payloads.CoachAboutMeDismissQuestion.self, from: op.payload)
            _ = try await coachAboutMeRepo.replayDismiss(p.write, idempotencyKey: op.idempotencyKey)
        default:
            break
        }
    }

    /// v0.12 SP3+SP4 — replay path for the GLP-1 side-effect + inventory CRUD
    /// kinds. Each re-issues its mutation with the persisted idempotency-key so
    /// the server's `(userId, key, method, path)` dedup suppresses a write that
    /// may already have landed before app-kill. When the repo is unwired the op
    /// is dropped as non-retriable so it can't wedge the queue.
    func dispatchTherapyLog(_ op: OutboxQueue.Operation) async throws {
        guard let therapyLogRepo else {
            throw HLError.unknown("\(op.kind.rawValue) replay skipped — therapyLogRepo not wired")
        }
        switch op.kind {
        case .createMedicationSideEffect:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateMedicationSideEffect.self, from: op.payload)
            _ = try await therapyLogRepo.replayCreateSideEffect(
                medicationID: p.medicationId, body: p.body, idempotencyKey: op.idempotencyKey
            )
        case .deleteMedicationSideEffect:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteMedicationSideEffect.self, from: op.payload)
            try await therapyLogRepo.replayDeleteSideEffect(
                medicationID: p.medicationId, logID: p.logId, idempotencyKey: op.idempotencyKey
            )
        case .createMedicationInventory:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateMedicationInventory.self, from: op.payload)
            _ = try await therapyLogRepo.replayCreateInventoryItem(
                medicationID: p.medicationId, body: p.body, idempotencyKey: op.idempotencyKey
            )
        case .updateMedicationInventory:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateMedicationInventory.self, from: op.payload)
            _ = try await therapyLogRepo.replayUpdateInventoryItem(
                medicationID: p.medicationId, itemID: p.itemId, patch: p.patch, idempotencyKey: op.idempotencyKey
            )
        case .deleteMedicationInventory:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteMedicationInventory.self, from: op.payload)
            try await therapyLogRepo.replayDeleteInventoryItem(
                medicationID: p.medicationId, itemID: p.itemId, idempotencyKey: op.idempotencyKey
            )
        default:
            throw HLError.unknown("dispatchTherapyLog received unexpected kind \(op.kind.rawValue)")
        }
    }
}

extension HLError {
    /// audit-v0162 H1 (Opt 3) — a server-side transient (5xx / 429). When the
    /// health-probe reports the server is known-degraded, a replay failure of
    /// this shape is the SERVER's fault, not the write's, so it must not count
    /// toward the dead-letter budget. (429 surfaces as `.rateLimited`, not
    /// `.server`, so both arms are needed.)
    var is5xxOrRateLimited: Bool {
        switch self {
        case let .server(status, _, _): (500 ... 599).contains(status)
        case .rateLimited: true
        default: false
        }
    }
}
