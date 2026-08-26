import Foundation

// Phase 07 Wave 1 — the `syncHealthKitSample` replay arm.
//
// Until now this kind was enqueued (the device forwarder ferries a failed
// measurement batch onto the queue) but never drained: the dispatcher threw a
// non-retriable error and the row was deleted. Every transient failure of a
// HealthKit upload therefore cost the samples permanently, which is exactly the
// durability hole the anchor already assumed was closed.
//
// The arm below is the workout-batch pattern applied to measurements, because
// the two routes have the same three hazards:
//
//   * the persisted bearer generation must be revalidated on both sides of the
//     wire call, so a 401 refresh cannot rebuild the envelope under a
//     replacement account;
//   * an owner transition is retryable protocol uncertainty, never a reason to
//     drop PHI; and
//   * HTTP 200 is not acceptance — only exact, complete, per-index terminal
//     evidence is, and anything less stays retryable under the same key.

extension OutboxReplayService {
    /// Replays one persisted HealthKit measurement batch under its own owner
    /// and its own persisted idempotency key.
    func dispatchHealthKitBatch(_ op: OutboxQueue.Operation) async throws {
        let payload = try decoder.decode(HealthKitBatchPayload.self, from: op.payload)
        guard !payload.entries.isEmpty else {
            // An empty batch has nothing to prove and nothing to lose; letting
            // it drain keeps a malformed historical row from wedging the queue.
            return
        }

        let response: HealthKitBatchResponseDTO
        do {
            if let ownerUserID = op.ownerUserID {
                // Captured after the pass-level owner gate. The repository
                // revalidates immediately before the wire and the queue
                // revalidates again once APIClient returns.
                let authLease = try await outbox.captureAuthLease(requiringOwner: ownerUserID)
                response = try await measurementsRepo.replayHealthKitBatch(
                    payload.entries,
                    idempotencyKey: op.idempotencyKey,
                    authLease: authLease
                )
                try await outbox.validateAuthLease(authLease)
            } else {
                // Reachable only while nobody is signed in — a signed-in
                // account quarantines this row before dispatch. No historical
                // bearer generation exists to capture.
                response = try await measurementsRepo.replayHealthKitBatch(
                    payload.entries,
                    idempotencyKey: op.idempotencyKey
                )
            }
        } catch is OutboxQueue.OwnerLeaseError {
            // Session transitions are retryable protocol uncertainty. The
            // message carries neither owner nor token.
            throw HLError.network(.other("authenticated session changed"))
        }

        do {
            // Same gate, same policy, same evidence as the online POST — and the
            // persisted rows' own external ids, so a replayed stats batch can
            // prove a `superseded_in_batch` index rather than assume it.
            try MeasurementBatchAcceptance.validate(
                postedCount: payload.entries.count,
                postedExternalIds: payload.entries.map(\.externalId),
                response: response,
                policy: .deployedMeasurementRoute
            )
        } catch let error as MeasurementBatchAcceptanceError {
            // The envelope was accepted but per-entry coverage was not proven.
            // Ambiguity stays retryable; the error carries aggregate counts only.
            throw HLError.network(.other(error.description))
        }
    }
}

extension MeasurementsRepository {
    /// Transitional replay path for rows enqueued before the owner stamp
    /// existed. No captured bearer generation, so `APIClient`'s ambient
    /// authentication recovery still applies.
    func replayHealthKitBatch(
        _ entries: [HealthKitBatchEntryDTO],
        idempotencyKey: String
    ) async throws -> HealthKitBatchResponseDTO {
        try await postHealthKitBatch(entries, idempotencyKey: idempotencyKey, authLease: nil)
    }

    /// Account-leased replay path. The captured bearer is pinned into the
    /// request so a one-shot 401 retry cannot re-issue account A's samples with
    /// a replacement account's credential.
    func replayHealthKitBatch(
        _ entries: [HealthKitBatchEntryDTO],
        idempotencyKey: String,
        authLease: OutboxQueue.AuthLease
    ) async throws -> HealthKitBatchResponseDTO {
        try await postHealthKitBatch(entries, idempotencyKey: idempotencyKey, authLease: authLease)
    }

    /// The single wire path both replay legs share — identical body and encoder
    /// to `MeasurementBatchUploader.upload`, differing only in where the
    /// idempotency key and the bearer come from.
    private func postHealthKitBatch(
        _ entries: [HealthKitBatchEntryDTO],
        idempotencyKey: String,
        authLease: OutboxQueue.AuthLease?
    ) async throws -> HealthKitBatchResponseDTO {
        let base: APIRequest<HealthKitBatchResponseDTO> = try .post(
            "/api/measurements/batch",
            body: HealthKitBatchPayload(entries: entries),
            encoder: .hlBatch,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        if let authLease {
            try await outbox.validateAuthLease(authLease)
        }
        let pinnedHeaders: [String: String] = if let authorizationHeader = authLease?.authorizationHeader {
            ["Authorization": authorizationHeader]
        } else {
            base.extraHeaders
        }
        let request = APIRequest<HealthKitBatchResponseDTO>(
            method: base.method,
            path: base.path,
            query: base.query,
            body: base.body,
            extraHeaders: pinnedHeaders,
            idempotencyKey: base.idempotencyKey,
            maxRetries: base.maxRetries,
            failFast: base.failFast,
            streaming: base.streaming,
            // A captured bearer belongs to one account generation. A 401 is
            // retained for a later pass; it must never refresh or log out a
            // process-global session that may now belong to another account.
            allowsAuthenticationRecovery: authLease == nil
        )
        let response = try await api.send(request)
        if let authLease {
            try await outbox.validateAuthLease(authLease)
        }
        return response
    }
}
