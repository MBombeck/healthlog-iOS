import Foundation

// Intake mutation surface (T-4 retro-mutate, W3-MEDCONTRACT slot pin,
// MEDS-QUICK-MARK-UNDO, MEDS-QUICK-MARK-TAKEN) — moved verbatim out of
// `MedicationsStore.swift` so the store file stays under SwiftLint's
// `file_length` ceiling (pure code movement, no behavior change).

// MARK: - T-4 Intake retro-mutate

/// Retro-mutate methods live in an extension to keep `MedicationsStore`'s
/// primary body under SwiftLint's `type_body_length` ceiling. Semantically
/// these belong to the same store — `IntakeHistoryRow` swipe-actions on
/// `MedicationDetailScreen` call them via `@Environment(MedicationsStore.self)`.
public extension MedicationsStore {
    /// Retro-mutate an existing intake event — used by `IntakeHistoryRow`
    /// swipe-actions on the detail screen ("mark as taken" / "mark as
    /// skipped" / fix wrong `takenAt`). Routes to
    /// `MedicationsRepository.updateIntake` (`PUT /api/medications/[id]/intake/[eventId]`).
    ///
    /// The store does **not** hold a paginated intake-history array of its
    /// own — that lives on `MedicationDetailStore` per-screen. The store's
    /// `todayIntakes` array IS patched if the targeted event happens to be
    /// in today's list (so the dashboard tile + Today section reflect the
    /// retro-mark immediately). The detail screen is responsible for
    /// applying the optimistic patch to its own `intakes` array before
    /// calling this method.
    ///
    /// `WriteOutcome.queued` means the network attempt failed with a
    /// retriable error and the outbox holds the patch — the local
    /// optimistic state must remain visible (caller's responsibility),
    /// the replay loop will drain on next reachability. `WriteOutcome.failed`
    /// signals a non-retriable server error (typically 422 schema reject) —
    /// caller should roll the optimistic patch back.
    @discardableResult
    func updateIntake(
        medicationId: String,
        eventId: String,
        patch: MedicationsRepository.IntakePatch
    ) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        // 15-01 (B1) — say locally what the patch says, BEFORE the round-trip,
        // and give it back on every exit that does not land. Deliberately ahead
        // of the first suspension point: this is a statement about a row the
        // user is looking at, not an authenticated effect. `nil` when the patch
        // states nothing local (a pin/unpin) or the row is not in today's list.
        let optimisticSnapshot = optimisticallyApply(patch, toIntake: eventId)
        do {
            let updated = try await repo.updateIntake(
                medicationId: medicationId,
                eventId: eventId,
                patch: patch
            )
            try sessionLease.requireCurrent()
            // If today's list happens to carry this intake, refresh the row
            // so the Today section + dashboard tile reflect the retro-mark
            // without a separate refetch.
            if let idx = todayIntakes.firstIndex(where: { $0.id == eventId }) {
                bumpMutationGeneration() // H-3 — protect this optimistic patch
                todayIntakes[idx] = updated
                if let swr {
                    await swr.writeThrough(todayIntakesKey, value: todayIntakes)
                    try sessionLease.requireCurrent()
                }
            }
            // Sibling-key invalidate: compliance heatmap + dashboard +
            // health-score all aggregate intake status server-side. Mirrors
            // `mark(intake:)`'s sibling invalidation list (F5 reconcile —
            // we keep `.medicationsTodayIntakes` hot via writeThrough above,
            // only the aggregates need a refetch).
            if let swr {
                await swr.invalidate(intakeSiblingKeys)
                try sessionLease.requireCurrent()
            }
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                restoreIntakeSnapshot(optimisticSnapshot)
                return .failed(.canceled)
            }
            error = err
            // `.queued` keeps the local statement standing — the outbox holds
            // the exact patch and replays it (same rule as `markIntakeQuick`).
            if err.shouldPersistToOutbox { return .queued }
            restoreIntakeSnapshot(optimisticSnapshot)
            return .failed(err)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                restoreIntakeSnapshot(optimisticSnapshot)
                return .failed(.canceled)
            }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            restoreIntakeSnapshot(optimisticSnapshot)
            return .failed(wrapped)
        }
    }

    /// Convenience for the dominant retro-mutate path: "user forgot to log
    /// a dose, marks the past row as taken/skipped now". Synthesises the
    /// `IntakePatch` from the desired status + an optional override
    /// `takenAt` (defaults to the **scheduled** time when marking as taken
    /// — the user's intent is "I took it on schedule, I just forgot to log
    /// it", not "I'm taking it now"). For `.skipped` no `takenAt` is sent —
    /// the server's update-schema treats `takenAt` as orthogonal to status,
    /// but sending the original-scheduled timestamp would mis-imply an
    /// administration moment for a skip.
    ///
    /// Server write contract accepts `taken`, `skipped`, and `snoozed`;
    /// `pending` and the server-owned terminal `missed` are read states. The
    /// retro-mutate UI deliberately surfaces only `.taken` and `.skipped`;
    /// `.snoozed` is a "snooze until
    /// later today" action that doesn't make sense retroactively, and
    /// `.pending` is a server-emitted state for unactioned future doses
    /// that the user cannot select directly.
    /// v1.15.19 — server-side `takenAt` plausibility bounds on the edit
    /// path: a future instant (5-minute clock-skew allowance) or anything
    /// older than 5 years 422s. Mirrored client-side so retro-mark/edit
    /// flows never round-trip into the 422 (`updateIntakeEventSchema`,
    /// `TAKEN_AT_MAX_AGE_MS`).
    static let takenAtMaxAge: TimeInterval = 5 * 365 * 24 * 60 * 60

    @discardableResult
    func markIntakeRetroactively(
        medicationId: String,
        eventId: String,
        status: IntakeStatus,
        scheduledAt: Date,
        now: Date = .now
    ) async -> WriteOutcome {
        // W3-MEDCONTRACT — the server's update schema is `{takenAt, skipped,
        // forceSlotInstant}`; the unknown `status` key is stripped by Zod.
        // The pre-v0.14.8 body relied on `status` alone for a skip, which
        // silently no-opped, and a skipped→taken flip left `skipped: true`
        // standing. Send the real `skipped` boolean + an explicit-null
        // `takenAt` on a skip (a skip has no administration instant).
        let patch: MedicationsRepository.IntakePatch
        switch status {
        case .taken:
            // Honor the scheduled timestamp — user intent is "I took it on
            // time, forgot to log". If `scheduledAt` is in the future
            // (defensive — UI should block this path), clamp to `now` so
            // the server's future-`takenAt` 422 (v1.15.19) can never fire.
            let takenAt = min(scheduledAt, now)
            // Honest pre-flight on the 5-year floor: the server would 422
            // anyway; fail locally with the same user-facing copy instead
            // of burning a round-trip.
            guard takenAt >= now.addingTimeInterval(-Self.takenAtMaxAge) else {
                let err = HLError.server(
                    status: 422,
                    code: "medications.intake.taken_at.out_of_range",
                    message: String(localized: "med.intake.taken_at.out_of_range")
                )
                error = err
                return .failed(err)
            }
            patch = .init(status: status.rawValue, takenAt: takenAt, skipped: false)
        case .skipped:
            // Skip → `skipped: true` + explicit `takenAt: null` (clears any
            // stale administration instant on a taken→skipped flip).
            patch = .init(status: status.rawValue, skipped: true, takenAtField: .null)
        case .pending, .snoozed:
            // These cases shouldn't be reached from the UI but we keep the
            // method total: forward the legacy status only (the server strips
            // it → harmless no-op rather than a hard failure).
            patch = .init(status: status.rawValue)
        case .missed: return rejectReadOnlyIntakeMutation()
        }
        return await updateIntake(medicationId: medicationId, eventId: eventId, patch: patch)
    }

    // MARK: - W3-MEDCONTRACT (v0.14.8) — slot pin / unpin

    /// Pin an off-schedule (ad-hoc) take onto a named real slot — the
    /// server counts it taken-late and badges the row "zugeordnet"
    /// (`forceSlotInstant`, v1.16.0). `slotInstant` MUST be the canonical
    /// slot anchor the ledger's `nearestSlot.at` carries; an arbitrary
    /// instant or an already-served slot 422s (surfaces as `.failed`).
    @discardableResult
    func pinIntakeToSlot(
        medicationId: String,
        eventId: String,
        slotInstant: Date
    ) async -> WriteOutcome {
        await updateIntake(
            medicationId: medicationId,
            eventId: eventId,
            patch: .init(forceSlotInstant: .value(slotInstant))
        )
    }

    /// Release a user pin ("Zuordnung lösen") — explicit `forceSlotInstant:
    /// null` re-attributes the take by window band on its own `takenAt`
    /// (ad-hoc when no band matches). The release stays user-fixed
    /// server-side so the nightly dedup never re-snaps it.
    @discardableResult
    func unpinIntake(
        medicationId: String,
        eventId: String
    ) async -> WriteOutcome {
        await updateIntake(
            medicationId: medicationId,
            eventId: eventId,
            patch: .init(forceSlotInstant: .null)
        )
    }

    /// Phantom-row delete — used when the user wants to *remove* a past
    /// intake event entirely (e.g. a dose was logged on the wrong
    /// medication and is otherwise un-correctable). Server route:
    /// `DELETE /api/medications/[medicationId]/intake/[eventId]` (204).
    /// Idempotent: a 404-on-replay is treated as success by the repo's
    /// retriable-classifier.
    @discardableResult
    func deleteIntake(medicationId: String, eventId: String) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        do {
            try await repo.deleteIntake(medicationId: medicationId, eventId: eventId)
            try sessionLease.requireCurrent()
            // Drop from today's list if present + writeThrough so the
            // optimistic UI doesn't re-flash on the next observe.
            if let idx = todayIntakes.firstIndex(where: { $0.id == eventId }) {
                bumpMutationGeneration() // H-3 — protect this optimistic removal
                todayIntakes.remove(at: idx)
                if let swr {
                    await swr.writeThrough(todayIntakesKey, value: todayIntakes)
                    try sessionLease.requireCurrent()
                }
            }
            if let swr {
                await swr.invalidate(intakeSiblingKeys)
                try sessionLease.requireCurrent()
            }
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

    /// Cache keys whose value depends on intake status — must be invalidated
    /// after any `updateIntake` / `deleteIntake` / `markIntakeQuick` /
    /// `logIntakeFree`. The today intakes key itself is handled via
    /// writeThrough above, NOT via invalidate (F5 reconcile: invalidating it
    /// causes a `.empty → fresh` flash on the next observe).
    ///
    /// **15-03 (B4) — `.medicationsList` belongs here.** The medication row
    /// carries `lastTakenAt`, so the card's "letzte Einnahme" is exactly as
    /// fresh as this key. Without the invalidation the session that just
    /// recorded an intake kept reading its own pre-write list until the TTL
    /// happened to expire — which is what a PRN card, whose entire record is
    /// its last intake, had nothing else to show.
    var intakeSiblingKeys: [CacheKey] {
        [
            .medicationsList,
            .medicationsCompliance(days: Self.complianceDaysWindow),
            dashboardSummaryKey,
            .healthScore
        ]
    }

    /// Core of ``markIntakeQuickUndoable`` — performs the mark and computes
    /// the reversal descriptor, but does NOT touch the undo coordinator.
    /// Split out so the undo-reversal unit tests can assert the token shape
    /// + the inverse round-trip without a live coordinator.
    ///
    /// Standalone real-path: ``markIntakeQuick`` swaps the optimistic row for
    /// the mirror-canonical row carrying a fresh `externalId`; we diff
    /// `todayIntakes` for the id that newly appeared so undo can delete it.
    func markIntakeQuickReturningUndo(
        intakeId: String,
        status: IntakeStatus,
        now: Date = .now,
        injectionSite: InjectionSite? = nil
    ) async -> (outcome: WriteOutcome, undo: IntakeMarkUndo?) {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return (.failed(.canceled), nil) }
        let standalone = isStandalone()
        let preIds = Set(todayIntakes.map(\.id))
        // Snapshot the pre-mark row for the real-intake reversal.
        let preSnapshot = todayIntakes.first { $0.id == intakeId }
        let synthParsed = intakeId.hasPrefix(MedicationIntake.synthesizedPlaceholderPrefix)
            ? Self.parseSynthesizedPlaceholderID(intakeId)
            : nil

        if !standalone, let synthParsed {
            let result = await markSynthesizedPlaceholderReturningReceipt(
                intakeId: intakeId,
                status: status,
                now: now,
                injectionSite: injectionSite
            )
            guard authenticatedEffectIsCurrent(sessionLease) else { return (.failed(.canceled), nil) }
            guard result.outcome.didLand,
                  result.serverEventID != nil || result.queuedOperationID != nil else
            {
                return (result.outcome, nil)
            }
            return (
                result.outcome,
                IntakeMarkUndo(
                    kind: .synthesized(
                        medicationId: synthParsed.medicationId,
                        scheduledAt: synthParsed.scheduledAt,
                        intakeId: intakeId,
                        serverEventID: result.serverEventID,
                        queuedOperationID: result.queuedOperationID
                    ),
                    medicationId: synthParsed.medicationId
                )
            )
        }

        let outcome = await markIntakeQuick(
            intakeId: intakeId, status: status, now: now, injectionSite: injectionSite
        )
        guard authenticatedEffectIsCurrent(sessionLease) else { return (.failed(.canceled), nil) }
        guard outcome.didLand else { return (outcome, nil) }

        let undo: IntakeMarkUndo?
        if standalone {
            // The added mirror row is the id that newly appeared in
            // `todayIntakes` after the mark. Real path swaps a fresh id in;
            // synth path appends one. Either way, diff finds it.
            let addedId = todayIntakes.map(\.id).first { !preIds.contains($0) }
            if let addedId {
                let pending = preSnapshot.map {
                    MedicationIntake(
                        id: $0.id,
                        medicationId: $0.medicationId,
                        scheduledAt: $0.scheduledAt,
                        takenAt: nil,
                        status: .pending,
                        snoozedUntil: nil
                    )
                }
                undo = IntakeMarkUndo(
                    kind: .standaloneAdded(externalId: addedId, pendingSnapshot: pending),
                    medicationId: synthParsed?.medicationId ?? preSnapshot?.medicationId ?? ""
                )
            } else {
                undo = nil
            }
        } else if let synthParsed {
            undo = IntakeMarkUndo(
                kind: .synthesized(
                    medicationId: synthParsed.medicationId,
                    scheduledAt: synthParsed.scheduledAt,
                    intakeId: intakeId,
                    serverEventID: nil,
                    queuedOperationID: nil
                ),
                medicationId: synthParsed.medicationId
            )
        } else if let preSnapshot {
            undo = IntakeMarkUndo(
                kind: .realIntake(snapshot: preSnapshot),
                medicationId: preSnapshot.medicationId
            )
        } else {
            undo = nil
        }
        return (outcome, undo)
    }

    /// Reverse a mark fired via ``markIntakeQuickUndoable``. Routes each
    /// path back to its pre-mark state: re-mark the real row to its prior
    /// status, delete the synth disposition, or delete the standalone mirror
    /// row + restore the local pending row. Best-effort —
    /// surfaces failures on `error` exactly like a forward mark.
    func undoIntakeMark(_ token: IntakeMarkUndo) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        bumpMutationGeneration() // H-3 — protect the optimistic revert (all branches)
        switch token.kind {
        case let .realIntake(snapshot):
            // Restore the captured row locally, then push the prior status to
            // the server. `markIntakeQuick` honours an arbitrary target
            // status, so a `.pending` revert flows through the same PATCH.
            if let idx = todayIntakes.firstIndex(where: { $0.id == snapshot.id }) {
                todayIntakes[idx] = snapshot
                onIntakesDidChange?()
            }
            _ = await markIntakeQuick(intakeId: snapshot.id, status: snapshot.status)
            guard authenticatedEffectIsCurrent(sessionLease) else { return }

        case let .synthesized(
            medicationId,
            _,
            synthIntakeId,
            serverEventID,
            queuedOperationID
        ):
            // A terminal disposition is inverted by deleting its exact event.
            // If the original write never reached the server, remove its exact
            // write-ahead operation before reachability replay can publish it.
            do {
                if let serverEventID {
                    try await repo.deleteIntake(
                        medicationId: medicationId,
                        eventId: serverEventID
                    )
                } else if let queuedOperationID {
                    try await repo.cancelQueuedReminderIntake(operationID: queuedOperationID)
                }
                try sessionLease.requireCurrent()
                removeOptimisticSynth(id: synthIntakeId)
                await invalidateAfterSynthMark(sessionLease: sessionLease)
                try sessionLease.requireCurrent()
                error = nil
            } catch let err as HLError {
                guard authenticatedEffectIsCurrent(sessionLease) else { return }
                error = err
            } catch {
                guard authenticatedEffectIsCurrent(sessionLease) else { return }
                self.error = .unknown(String(describing: error))
            }
            // W-COMPLIANCE-INV — refresh only; the previous server snapshot
            // stays painted until the canonical value lands (no local-interim
            // repaint).
            await refreshCardComplianceSnapshot(for: medicationId, sessionLease: sessionLease)

        case let .standaloneAdded(externalId, pendingSnapshot):
            do {
                try await repo.deleteStandaloneIntake(externalId: externalId)
                try sessionLease.requireCurrent()
                // Drop the added (taken/skipped) row locally; restore the
                // pre-mark pending row so the dose reads as due again.
                todayIntakes.removeAll { $0.id == externalId }
                if let pendingSnapshot,
                   !todayIntakes.contains(where: { $0.id == pendingSnapshot.id })
                {
                    todayIntakes.append(pendingSnapshot)
                }
                onIntakesDidChange?()
                if let swr {
                    await swr.writeThrough(todayIntakesKey, value: todayIntakes)
                    try sessionLease.requireCurrent()
                    await swr.invalidate(intakeSiblingKeys)
                    try sessionLease.requireCurrent()
                }
            } catch let err as HLError {
                guard authenticatedEffectIsCurrent(sessionLease) else { return }
                error = err
            } catch {
                guard authenticatedEffectIsCurrent(sessionLease) else { return }
                self.error = .unknown(String(describing: error))
            }
            // W-COMPLIANCE-INV — refresh only (see above).
            await refreshCardComplianceSnapshot(for: token.medicationId, sessionLease: sessionLease)
        }
    }

    // MARK: - MEDS-QUICK-MARK-TAKEN

    /// WriteOutcome-returning variant of `mark(intake:status:)`. Required by
    /// the list-row quick-mark surface (`MedicationsScreen` leading-✓
    /// button) because the screen needs `.queued` vs `.failed`
    /// discrimination to drive the offline-toast vs revert-banner. The
    /// legacy void-returning `mark(intake:)` stays untouched for the
    /// Today-section swipe-actions (zero-signature-change risk).
    ///
    /// Semantics mirror `mark(intake:status:)`:
    /// - Optimistic-patch of `todayIntakes` BEFORE the network attempt
    /// - On retriable error → keep patch visible, return `.queued`
    ///   (outbox replays on next reachability)
    /// - On non-retriable error → rollback, return `.failed(err)`
    /// - On success → writeThrough + sibling-invalidate, return `.success`
    /// v0.11 — recent injection sites for a medication (newest-first), feeding
    /// the take-flow rotation hint. Reads the paginated intake history and maps
    /// the server `injectionSite` strings to local cases. Best-effort — a fetch
    /// failure returns `[]` so the hint silently degrades (no suggestion).
    func recentInjectionSites(medicationID: String, limit: Int = 12) async -> [InjectionSite] {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return [] }
        do {
            let page = try await repo.intakeHistory(medicationID: medicationID, limit: limit)
            try sessionLease.requireCurrent()
            return page.events.compactMap { InjectionSite.parse($0.injectionSite) }
        } catch {
            return []
        }
    }

    @discardableResult
    func markIntakeQuick(
        intakeId: String,
        status: IntakeStatus,
        now: Date = .now,
        injectionSite: InjectionSite? = nil
    ) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        // W-MED2: synthesised placeholders have no server `intakeId` to
        // PATCH — route through `recordFromReminder` so the bulk-intake
        // endpoint creates the row idempotently from the
        // `(medicationId, scheduledFor)` pair. The optimistic patch
        // appends a flipped-status placeholder to `todayIntakes` so the
        // UI reflects the action immediately; the next server fetch
        // returns the real row and the dedup window suppresses the
        // placeholder.
        if intakeId.hasPrefix(MedicationIntake.synthesizedPlaceholderPrefix) {
            return await markSynthesizedPlaceholderWithOutcome(
                intakeId: intakeId,
                status: status,
                now: now,
                injectionSite: injectionSite
            )
        }
        // v0.8.2 W1b (B5): coalesce a rapid second tap on the same real
        // intake while the first PATCH is still in flight.
        guard beginMark(intakeId) else { return .success }
        defer { endMark(intakeId) }
        guard let originalIndex = todayIntakes.firstIndex(where: { $0.id == intakeId }) else {
            // Concurrent refresh dropped the row — soft no-op rather than
            // spurious `.failed`.
            return .success
        }
        let original = todayIntakes[originalIndex]
        // MEDS-RETROLOG-QUICK (RCA-med-compliance, b197): tapping a known
        // scheduled slot is a *retro-log of that slot* ("I took the 09:00
        // dose"), not "I'm taking a dose now". For a PENDING PAST SCHEDULED
        // dose being marked `.taken`, send `takenAt = scheduledAt` (clamped
        // to ≤ now) — mirroring `markIntakeRetroactively`. Otherwise the
        // server re-attributes the take by window band on a `now` that falls
        // outside the slot's band, tombstones the original row and mints a
        // new ad-hoc row → the phantom/unassigned intake + count drop.
        // `min(scheduledAt, now)` is `now` for current/on-time doses, so the
        // adjustment is scoped to the past-pending case by the guard below.
        let resolvedTakenAt: Date = if status == .taken,
                                       original.status == .pending,
                                       original.scheduledAt < now
        {
            min(original.scheduledAt, now)
        } else {
            now
        }
        bumpMutationGeneration() // H-3 — protect this optimistic patch (mark)
        todayIntakes[originalIndex] = MedicationIntake(
            id: original.id,
            medicationId: original.medicationId,
            scheduledAt: original.scheduledAt,
            takenAt: status == .taken ? resolvedTakenAt : original.takenAt,
            status: status,
            snoozedUntil: nil
        )
        // v0.6.1.3 Y4.1 — let the App-Badge follow the optimistic patch
        // so the icon ticks down immediately on Genommen tap, even
        // before the server roundtrip lands.
        onIntakesDidChange?()
        // W-COMPLIANCE-INV — keep the last server snapshot painting through
        // the optimistic window; the post-mark refresh overwrites it with the
        // canonical value (server is the only painted source).

        do {
            let saved: MedicationIntake = if isStandalone() {
                // v0.11 W2 — persist the dose to the local mirror so it reads
                // back in the list immediately. No network, no outbox. The
                // optimistic patch above already moved the row; this swaps in
                // the canonical local row (stable externalId).
                try await repo.recordStandaloneIntake(
                    medicationId: original.medicationId,
                    scheduledAt: original.scheduledAt,
                    status: status,
                    takenAt: resolvedTakenAt,
                    injectionSite: injectionSite
                )
            } else {
                try await repo.record(
                    intake: intakeId,
                    status: status,
                    takenAt: resolvedTakenAt,
                    injectionSite: injectionSite
                )
            }
            try sessionLease.requireCurrent()
            if let idx = todayIntakes.firstIndex(where: { $0.id == intakeId }) {
                todayIntakes[idx] = saved
            }
            if let swr {
                await swr.writeThrough(todayIntakesKey, value: todayIntakes)
                try sessionLease.requireCurrent()
                await swr.invalidate(intakeSiblingKeys)
                try sessionLease.requireCurrent()
            }
            onIntakesDidChange?()
            // v0.6.1.4 Y4.2 — re-fetch the server-canonical card
            // snapshot for the affected medication so the bar moves
            // to the new percentage as soon as the round-trip lands.
            // Detached so the success return isn't blocked on the
            // compliance round-trip.
            let affectedMedicationID = original.medicationId
            // Senior M3 — keep a handle so `clearOnLogout()` can cancel an
            // in-flight refresh (stale-compliance PHI flash on shared-device
            // sign-out). Replace (cancel) any prior in-flight refresh so only
            // the latest mark's snapshot fetch stays live.
            complianceRefreshTask?.cancel()
            complianceRefreshTask = _Concurrency.Task { @MainActor [weak self] in
                await self?.refreshCardComplianceSnapshot(
                    for: affectedMedicationID,
                    sessionLease: sessionLease
                )
            }
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = err
            // WC/D1 + WW/F1: the repo enqueues to the Outbox for everything
            // `shouldPersistToOutbox` covers (retriable network/5xx PLUS
            // `.unauthorized` token-expiry). Keep the optimistic patch + report
            // `.queued` for ALL of those — gating on `isRetriable` here would
            // roll back + report `.failed` for a 401 the repo just durably
            // queued (the watch-mood-vanishes class of bug).
            if err.shouldPersistToOutbox { return .queued } // keep patch — outbox replays
            if let idx = todayIntakes.firstIndex(where: { $0.id == intakeId }) {
                todayIntakes[idx] = original
            }
            // Rollback also re-publishes the badge — the dose returns
            // to pending and the count climbs back to its pre-mark value.
            onIntakesDidChange?()
            return .failed(err)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            if let idx = todayIntakes.firstIndex(where: { $0.id == intakeId }) {
                todayIntakes[idx] = original
            }
            onIntakesDidChange?()
            return .failed(wrapped)
        }
    }
}
