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
    /// #10 — `(deliveredAt, ownerUserID)` for a replayed HealthKit batch the
    /// server accepted. Same shape as `MeasurementBatchUploader.SuccessNotifier`,
    /// declared here because this service also compiles into the widget
    /// extension, which does not link the uploader.
    public typealias HealthKitDeliveryNotifier = @Sendable (_ deliveredAt: Date, _ ownerUserID: String) async -> Void

    /// #10 — composition-root wiring (`AppContainer.configureRuntimeWiring`):
    /// a replayed HealthKit batch is a delivered HealthKit sync just like the
    /// live POST, so it moves "Last synced" through the same fenced stamp.
    /// Synchronous and `nonisolated` for the same reason as the uploader's
    /// setter: the slot is filled inside the init tick, before any pass can run.
    public nonisolated func setHealthKitDeliveryNotifier(_ notifier: HealthKitDeliveryNotifier?) {
        healthKitDeliverySlot.withLock { $0 = notifier }
    }

    /// Whether the composition root attached the delivery notifier; pinned by
    /// `HealthKitSyncStampWiringTests` like ``isDeadLetterSinkAttached``.
    nonisolated var isHealthKitDeliveryNotifierAttached: Bool {
        healthKitDeliverySlot.withLock { $0 != nil }
    }

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
        var splitAccepted = false
        do {
            response = try await postReplayed(payload.entries, op)
        } catch is OutboxQueue.OwnerLeaseError {
            // Session transitions are retryable protocol uncertainty. The
            // message carries neither owner nor token.
            throw HLError.network(.other("authenticated session changed"))
        } catch let invalid as MeasurementBatchInvalid where invalid.entryIndexes != nil && op.ownerUserID != nil {
            // E1 — the entries v1.39.1 named go into the register, the rest of
            // the page is sent once more on its own and folded back in.
            response = try await replaySplit(invalid, payload.entries, owner: op.ownerUserID)
            splitAccepted = true
        } catch {
            // #115 / 0.3 — a refusal the route names deletes the row (see
            // `onNonRetriable`), but only once it is in the skip register, so
            // the reading stays visible and is offered again. A register write
            // that fails parks the row instead. Any other 4xx parks
            // (`parkReason`).
            if case let .refused(reason) = HealthKitBatchRejection.classify(error) {
                try await recordRefused(payload.entries, reason: reason, owner: op.ownerUserID)
            }
            throw error
        }

        do {
            // Same gate, same policy, same evidence as the online POST — and the
            // persisted rows' own external ids, so a replayed stats batch can
            // prove a `superseded_in_batch` index rather than assume it. A split
            // page's rest already passed it; its refused rows are registered.
            if !splitAccepted {
                try MeasurementBatchAcceptance.validate(
                    postedCount: payload.entries.count,
                    postedExternalIds: payload.entries.map(\.externalId),
                    response: response,
                    policy: .deployedMeasurementRoute
                )
            }
        } catch let error as MeasurementBatchAcceptanceError {
            // The envelope was accepted but per-entry coverage was not proven.
            // Ambiguity stays retryable; the error carries aggregate counts only.
            throw HLError.network(.other(error.description))
        }

        // #115 / 0.3 — the acceptance gate calls `unmappable_identifier`
        // terminal *for the envelope* (see `Policy.deployedMeasurementRoute`),
        // which is right for the live importers: they hold that one index
        // themselves and park it here. But this row IS that parking lot. When
        // the server still cannot map the identifier on replay, draining the row
        // deletes the only remaining copy of a reading whose anchor has already
        // moved past it. It stays parked instead.
        //
        // INT-A — every other terminal skip (`value_out_of_range`, …) passed the
        // gate too, and `onReplaySuccess` then deleted the row: the replay was
        // the one path where a refused reading still vanished without a trace.
        // It goes into the skip register first; if that write fails, the row
        // parks and the next pass tries again.
        let outcome = BatchUploadOutcome(chunk: payload.entries, response: response)
        var refusedByReason: [String: [HealthKitBatchEntryDTO]] = [:]
        for verdict in outcome.rowVerdicts where verdict.status == .skipped {
            let reason = verdict.reason ?? "unknown"
            guard reason != MeasurementBatchAcceptance.Reason.unmappableIdentifier else { continue }
            refusedByReason[reason, default: []].append(payload.entries[verdict.index])
        }
        for (reason, entries) in refusedByReason.sorted(by: { $0.key < $1.key }) {
            try await recordRefused(entries, reason: reason, owner: op.ownerUserID)
        }

        let unmappable = Self.unmappableIndexCount(in: response, postedCount: payload.entries.count)
        if unmappable > 0 {
            throw HealthKitReplayParked(reason: .unmappable(count: unmappable))
        }

        // #10 — only an owner-bound row stamps: the transitional unleased path
        // runs while nobody is signed in, and there is no account to stamp.
        if let owner = op.ownerUserID, let notifier = healthKitDeliverySlot.withLock({ $0 }) {
            await notifier(clock(), owner)
        }
    }

    /// The replay's own wire call for one persisted page: under the row's
    /// owner lease when it has one, the transitional unleased path otherwise.
    private func postReplayed(
        _ entries: [HealthKitBatchEntryDTO],
        _ op: OutboxQueue.Operation
    ) async throws -> HealthKitBatchResponseDTO {
        if let ownerUserID = op.ownerUserID {
            // Captured after the pass-level owner gate. The repository
            // revalidates immediately before the wire and the queue
            // revalidates again once APIClient returns.
            let authLease = try await outbox.captureAuthLease(requiringOwner: ownerUserID)
            let response = try await measurementsRepo.replayHealthKitBatch(
                entries,
                idempotencyKey: op.idempotencyKey,
                authLease: authLease
            )
            try await outbox.validateAuthLease(authLease)
            return response
        } else {
            // Reachable only while nobody is signed in — a signed-in
            // account quarantines this row before dispatch. No historical
            // bearer generation exists to capture.
            return try await measurementsRepo.replayHealthKitBatch(
                entries,
                idempotencyKey: op.idempotencyKey
            )
        }
    }

    /// E1 — ``MeasurementBatchInvalid/split(_:ownerID:send:)`` on the replay
    /// wire: the rest goes out under the row's owner lease and a fresh key (the
    /// persisted key belongs to the refused body; the server folds a repeated
    /// entry on its `externalId`). A split that cannot register rethrows the
    /// refusal, which then takes the whole-page path below.
    private func replaySplit(
        _ invalid: MeasurementBatchInvalid,
        _ entries: [HealthKitBatchEntryDTO],
        owner: String?
    ) async throws -> HealthKitBatchResponseDTO {
        do {
            return try await invalid.split(entries, ownerID: owner) { [outbox, measurementsRepo] rest in
                guard let owner else { throw invalid }
                let authLease = try await outbox.captureAuthLease(requiringOwner: owner)
                let answer = try await measurementsRepo.replayHealthKitBatch(
                    rest,
                    idempotencyKey: IdempotencyKey().raw,
                    authLease: authLease
                )
                try await outbox.validateAuthLease(authLease)
                return answer
            }
        } catch is OutboxQueue.OwnerLeaseError {
            throw HLError.network(.other("authenticated session changed"))
        } catch let error as MeasurementBatchAcceptanceError {
            throw HLError.network(.other(error.description))
        } catch let refusal as MeasurementBatchInvalid {
            if case let .refused(reason) = HealthKitBatchRejection.classify(refusal) {
                try await recordRefused(entries, reason: reason, owner: owner)
            }
            throw refusal
        }
    }

    /// Writes refused rows into the owner's skip register, or parks the row.
    /// A row without an owner has no account to show them to; it parks too.
    private func recordRefused(_ entries: [HealthKitBatchEntryDTO], reason: String, owner: String?) async throws {
        guard let owner else { throw HealthKitReplayParked(reason: .refusalNotRecorded) }
        do {
            try await HealthKitSkippedRowRegister.current.record(
                entries.map { HealthKitSkippedEntry(entry: $0, reason: reason) },
                ownerID: owner,
                build: HealthKitSkipRegisterBuild.current
            )
        } catch {
            throw HealthKitReplayParked(reason: .refusalNotRecorded)
        }
    }

    /// INT-A — the skip-register reason of a replayed page the server never
    /// confirmed within the retry budget (see ``transferUnconfirmedHealthKitRows(now:)``).
    static let notConfirmedReason = "not_confirmed"

    /// INT-A — a queued HealthKit page the server never confirmed (acceptance
    /// never proven: a skip reason this build does not know, missing indexes)
    /// used to age into the dead-letter lane after `maxAttempts` and
    /// `deadLetterMinAge`, where nothing in the app offers it again. It moves
    /// into the owner's skip register instead: listed in Sync Diagnostics,
    /// offered again once per build and on demand. Rows an earlier build
    /// already dead-lettered move the same way (the update path).
    ///
    /// Only rows of the signed-in account move; another account's rows stay
    /// in the outbox for that account. A register write that fails leaves the
    /// row where it was, and the dead-letter sweep keeps it recoverable.
    func transferUnconfirmedHealthKitRows(now: Date) async {
        guard let owner = currentUserProvider() else { return }
        let live = await outbox.snapshot.filter {
            $0.attempts >= maxAttempts && now.timeIntervalSince($0.createdAt) >= deadLetterMinAge
        }
        let candidates = await (live + outbox.deadLetteredOperations)
            .filter { $0.kind == .syncHealthKitSample && $0.ownerUserID == owner && !isDelivered($0) }
        for op in candidates {
            guard let payload = try? decoder.decode(HealthKitBatchPayload.self, from: op.payload) else { continue }
            do {
                try await HealthKitSkippedRowRegister.current.record(
                    payload.entries.map { HealthKitSkippedEntry(entry: $0, reason: Self.notConfirmedReason) },
                    ownerID: owner,
                    build: HealthKitSkipRegisterBuild.current
                )
                try await outbox.remove(id: op.id)
                // A count only — no identifier, no value.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.outbox.info("HK page not confirmed — \(payload.entries.count, privacy: .public) row(s) moved to the skip register")
            } catch {
                HLLog.outbox.error("HK page not confirmed — skip register write failed, row stays queued")
            }
        }
    }

    /// Posted indexes the server answered with `skipped(unmappable_identifier)`,
    /// read from both `skipped[]` and the mirrored `entries[]` form.
    static func unmappableIndexCount(in response: HealthKitBatchResponseDTO, postedCount: Int) -> Int {
        let reason = MeasurementBatchAcceptance.Reason.unmappableIdentifier
        var indexes = Set(response.skipped.filter { $0.reason == reason }.map(\.index))
        for entry in response.entries where entry.status == .skipped && entry.reason == reason {
            indexes.insert(entry.index)
        }
        return indexes.filter { (0 ..< postedCount).contains($0) }.count
    }

    /// A parked row keeps its place, its payload and its idempotency key. The
    /// attempt is stamped (so the back-off applies) but not counted: the server
    /// lacking a mapping, or the person's module being off, is not this write
    /// failing, and a counted budget would age the row into the dead-letter
    /// lane, which nothing re-offers. The first pass after the server can take
    /// the row lands it.
    func onParked(_ op: OutboxQueue.Operation, _ parked: HealthKitReplayParked) async {
        try? await outbox.touchAttempt(id: op.id, lastError: parked.description)
        // Kind and a fixed reason only — no identifier, no value.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info(
            "Op \(op.kind.rawValue, privacy: .public) parked — \(parked.description, privacy: .public)"
        )
    }

    /// The kinds whose rows can carry HealthKit readings an importer has already
    /// committed its anchor past. For these a module-off refusal parks instead
    /// of deleting, because the outbox row is the reading's only remaining copy.
    static let healthKitFedKinds: Set<OutboxQueue.Operation.Kind> = [
        .syncHealthKitSample, .logMood, .logCycleDayLog, .uploadWorkoutBatch
    ]

    /// Why a replay answer parks the row instead of deleting it, or `nil`.
    static func parkReason(for error: Error, kind: OutboxQueue.Operation.Kind) -> HealthKitReplayParked? {
        if let parked = error as? HealthKitReplayParked { return parked }
        guard healthKitFedKinds.contains(kind) else { return nil }
        // Both module-off shapes, read from `meta.errorCode` by `APIClient`:
        // the generic 403 `module.disabled` (typed) and the cycle route's own
        // 403 `cycle.disabled`.
        if case let HLError.moduleDisabled(module) = error {
            return HealthKitReplayParked(reason: .moduleDisabled(module))
        }
        if CycleRepository.isCycleDisabled(error) {
            return HealthKitReplayParked(reason: .moduleDisabled("cycle"))
        }
        // #115 / 0.3 — a HealthKit batch 4xx the route does not name as a
        // refusal (a Zod 422 carries no code) stored nothing and refused
        // nothing. The row is the reading's only copy; it waits.
        if kind == .syncHealthKitSample, case let .notStored(status) = HealthKitBatchRejection.classify(error) {
            return HealthKitReplayParked(reason: .notStored(status: status))
        }
        return nil
    }
}

/// #115 / 0.3 — a replay answer that is neither delivery nor refusal: the row
/// stays in the outbox, uncounted.
///
/// `lastError` of a parked row starts with ``lastErrorPrefix`` — the stable
/// marker a diagnostics surface can filter the queue on.
struct HealthKitReplayParked: Error, Equatable, CustomStringConvertible {
    enum Reason: Equatable {
        /// The server accepted the batch envelope but still cannot map
        /// `count` of its rows (`unmappable_identifier`).
        case unmappable(count: Int)
        /// The module that owns the write is off for this account.
        case moduleDisabled(String)
        /// A whole-batch 4xx without a refusal the route names.
        case notStored(status: Int)
        /// The server refused rows, but they could not be written into the
        /// owner's skip register (no owner, or a write that did not verify).
        case refusalNotRecorded
    }

    static let lastErrorPrefix = "parked:"
    let reason: Reason

    var description: String {
        switch reason {
        case let .unmappable(count): "\(Self.lastErrorPrefix)unmappable_identifier count=\(count)"
        case let .moduleDisabled(module): "\(Self.lastErrorPrefix)module_disabled module=\(module)"
        case let .notStored(status): "\(Self.lastErrorPrefix)not_stored status=\(status)"
        case .refusalNotRecorded: "\(Self.lastErrorPrefix)refusal_not_recorded"
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
