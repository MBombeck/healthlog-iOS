import Foundation

/// T-3 CRUD orchestration + W-MED2 synth-placeholder mark routing —
/// moved verbatim out of `MedicationsStore.swift` so the store file
/// stays under SwiftLint's `file_length` ceiling (pure code movement,
/// no behavior change).
public extension MedicationsStore {
    // MARK: - T-3 CRUD orchestration

    /// Outcome surface for the Add/Edit sheets. Mirrors the optimistic-write
    /// contract of `mark(intake:status:)`: the store has already applied the
    /// patch to its in-memory list by the time `.success` returns; on
    /// `.queued` the network attempt landed in the outbox (retriable error)
    /// and a snackbar / banner upstream should communicate the deferred state.
    enum WriteOutcome: Sendable, Equatable {
        case success
        case queued
        case failed(HLError)

        /// `true` when the write reached the surface (optimistic patch
        /// stands — success or outbox-queued). `false` only on `.failed`,
        /// where the optimistic state was rolled back. Drives the undo-token
        /// gate: nothing landed → nothing to undo.
        var didLand: Bool {
            switch self {
            case .success, .queued: true
            case .failed: false
            }
        }
    }

    /// Create a new medication. Optimistic add to `medications` happens
    /// **after** the network response so the server-assigned `id` is the
    /// canonical key (no temp-id rewrite). On retriable failure the row
    /// is *not* prepended — the outbox will replay and the next `load()`
    /// will pull the server row in. On non-retriable failure surfaces an
    /// HLError and leaves the list untouched.
    @discardableResult
    func create(_ body: MedicationsRepository.MedicationCreate) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        do {
            let created = try await repo.create(body)
            try sessionLease.requireCurrent()
            bumpMutationGeneration() // H-3 — protect this optimistic insert
            medications.insert(created, at: 0)
            // Patch through to the SWR list-cache so the next observe on
            // `.medicationsList` sees the new row immediately instead of
            // a stale-without-it array. Mirrors `mark(intake:)` pattern.
            // Compliance-window must invalidate too — a newly-created
            // medication shifts which dose-events count towards today's
            // ring (Arch-C1 reconcile).
            if let swr {
                await swr.writeThrough(.medicationsList, value: medications)
                try sessionLease.requireCurrent()
                await swr.invalidate([
                    dashboardSummaryKey,
                    .healthScore,
                    .medicationsCompliance(days: Self.complianceDaysWindow)
                ])
                try sessionLease.requireCurrent()
            }
            reconcileSpeziSchedulerIfAvailable()
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

    /// Apply an in-place patch. On retriable network failure the outbox
    /// queues the PUT (see `MedicationsRepository.update`) and the store
    /// keeps the **previous** value visible — the user re-attempt path is
    /// "refresh" once online (or the outbox replay drains it). On success
    /// the returned wire row replaces the local row.
    @discardableResult
    func update(id: String, patch: MedicationsRepository.MedicationPatch) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        do {
            let updated = try await repo.update(id: id, patch: patch)
            try sessionLease.requireCurrent()
            bumpMutationGeneration() // H-3 — protect this optimistic swap
            if let i = medications.firstIndex(where: { $0.id == id }) {
                medications[i] = updated
            } else {
                medications.append(updated)
            }
            // Compliance-window must invalidate too — schedule / dose / unit
            // edits change which intakes count for today's ring (Arch-C1).
            if let swr {
                await swr.writeThrough(.medicationsList, value: medications)
                try sessionLease.requireCurrent()
                await swr.invalidate([
                    dashboardSummaryKey,
                    .healthScore,
                    .medicationsCompliance(days: Self.complianceDaysWindow)
                ])
                try sessionLease.requireCurrent()
            }
            reconcileSpeziSchedulerIfAvailable()
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

    /// Archive (soft-delete) the medication. Uses
    /// `MedicationsRepository.delete` which routes to the server's
    /// `DELETE /api/medications/[id]` (204) — the row stays in the
    /// database with `active = false` server-side. Locally we apply
    /// the same `active=false` patch + an `archivedAt` timestamp so the
    /// "Archived" filter renders relative-time without a refresh.
    ///
    /// On retriable failure we still apply the optimistic local patch so
    /// the user sees their archive intent reflected; the outbox replay
    /// drains the DELETE later. On non-retriable failure we restore the
    /// original row (no archive happened, surface the error).
    @discardableResult
    func archive(id: String, now: Date = .now) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        guard let originalIndex = medications.firstIndex(where: { $0.id == id }) else {
            return .failed(.unknown("Medication not found"))
        }
        let original = medications[originalIndex]
        bumpMutationGeneration() // H-3 — protect this optimistic archive patch
        medications[originalIndex] = archiving(original, at: now)
        // Compliance-window must invalidate too — archive removes the
        // medication from the active set so today's ring needs to drop
        // its dose-events (Arch-C1).
        if let swr {
            await swr.writeThrough(.medicationsList, value: medications)
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            await swr.invalidate([
                dashboardSummaryKey,
                .healthScore,
                .medicationsCompliance(days: Self.complianceDaysWindow)
            ])
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
        }
        // Spezi reconcile picks up the optimistic archive flag and
        // purges this medication's Task versions on the next save tick.
        // The roll-back below re-runs the reconcile to restore them
        // if the server delete fails non-retriably.
        reconcileSpeziSchedulerIfAvailable()
        // Queue undo BEFORE the network round-trip. Unlike measurement +
        // mood deletes, the medication archive is a soft-delete server-
        // side (active=false), so the undo simply flips active=true via
        // the existing `unarchive(id:)` path — no id loss.
        let medicationID = id
        undoCoordinator?.enqueue(
            message: String(localized: "undo.medication.archived")
        ) { [weak self] in
            guard let self, sessionLease.isCurrent else { return }
            _ = await unarchive(id: medicationID)
        }
        do {
            try await repo.delete(id: id)
            try sessionLease.requireCurrent()
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = err
            if err.shouldPersistToOutbox {
                // Optimistic archive stays; outbox will retry (incl. a
                // transient-refresh 401 the repo durably enqueued). Leave
                // the undo affordance live — the user can still recover.
                return .queued
            }
            if let i = medications.firstIndex(where: { $0.id == id }) {
                medications[i] = original
            }
            if let swr {
                await swr.writeThrough(.medicationsList, value: medications)
                guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            }
            // Roll-back also restores the Spezi schedule entries that
            // the optimistic archive purged above.
            reconcileSpeziSchedulerIfAvailable()
            // Non-retriable failure rolled the optimistic archive back —
            // the row is back to `active=true` locally and never went
            // archive-side server-side. The undo affordance would just
            // re-fire `unarchive` on an already-active row, so drop it.
            undoCoordinator?.dismiss(reason: .cancelled)
            return .failed(err)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            if let i = medications.firstIndex(where: { $0.id == id }) {
                medications[i] = original
            }
            reconcileSpeziSchedulerIfAvailable()
            undoCoordinator?.dismiss(reason: .cancelled)
            return .failed(wrapped)
        }
    }

    /// Restore an archived medication (rollback the archive intent before
    /// the server has confirmed, or undo from the Archived list). Routes
    /// through `update(id:, patch:)` with `active=true`.
    @discardableResult
    func unarchive(id: String) async -> WriteOutcome {
        await update(id: id, patch: .init(active: true))
    }

    // MARK: - Build 6.2 — lifecycle (pause / reactivate / end)

    /// **Pause** the medication — flips `active` to `false` via
    /// `PUT /api/medications/[id]`. The server stamps `pausedAt = now()` and
    /// opens a durable pause era (`v1.25 H-MED1`), so paused days drop out of
    /// the compliance denominator instead of counting as missed. Distinct from
    /// ``archive(id:now:)``: pause carries no local `archivedAt` stamp and no
    /// undo toast — it is a deliberate, reversible "aussetzen", surfaced with
    /// its own `pausedAt` state rather than as a soft-delete. Reactivate via
    /// ``reactivateMedication(id:)``.
    @discardableResult
    func pauseMedication(id: String) async -> WriteOutcome {
        await update(id: id, patch: .init(active: false))
    }

    /// **Reactivate** a paused (or archived) medication — flips `active` back to
    /// `true`; the server clears `pausedAt` and closes the open pause era.
    @discardableResult
    func reactivateMedication(id: String) async -> WriteOutcome {
        await update(id: id, patch: .init(active: true))
    }

    /// **End the course** — sets `endsOn` to `date` (default today) via
    /// `PUT /api/medications/[id]`. The medication stays `active` but its
    /// recurrence is floored at `endsOn`, so no further doses are scheduled
    /// after that day (the server caps every cadence by the course window).
    /// Unlike pause this is a schedule edit, not an activity flip — a med the
    /// user finished their course of, not one they temporarily suspended.
    @discardableResult
    func endMedication(id: String, on date: Date = .now) async -> WriteOutcome {
        await update(id: id, patch: .init(endsOn: MedicationCadenceLogic.isoDay(date)))
    }

    /// **M2** — best-effort fetch of the saved list layout. Quietly keeps the
    /// current value on any failure (offline / standalone / older server) so
    /// the list falls back to the plain server order rather than erroring.
    func fetchListLayout() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        await fetchListLayout(sessionLease: sessionLease)
    }

    internal func fetchListLayout(sessionLease: AuthenticatedSessionLease) async {
        if let layout = try? await repo.listLayout(), authenticatedEffectIsCurrent(sessionLease) {
            listLayout = layout
        }
    }

    // 08-13 — there is no list-presentation setter any more. `setListView` was
    // made inert by 08-05 (one enum case, so its guard returned before any
    // state moved) and retained only because 06-AUTHENTICATED-EFFECT-INVENTORY
    // froze six scanner hits on `setListView#1`. Those six rows are attested
    // `removed-hit` under owner 08-13 in 06-EFFECT-INVENTORY-DISPOSITIONS.tsv,
    // so the function is deleted rather than documented. `setListOrder` below
    // is the only medication-layout write the app performs, and it is
    // order-only — which is what keeps whatever presentation the server may
    // still have stored from being overwritten by anything this app sends.

    /// **W-B184 MED-1** — persist a new manual medication order.
    ///
    /// `order` is the full top-to-bottom id sequence the user dragged into
    /// place. It is capped at `MedicationListLayout.orderMaxEntries` (the
    /// server-side bound) before the optimistic apply + PUT so an over-long
    /// list can never be sent. Optimistic apply + Outbox + Idempotency-Key, and
    /// only `order` is on the wire — so whatever presentation the server has
    /// stored for this account is preserved rather than overwritten, which is
    /// what keeps a legacy value from being rewritten by an order change.
    ///
    /// **08-05 — this is the only medication-layout write the app performs.**
    @discardableResult
    func setListOrder(_ order: [String]) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        let capped = Array(order.prefix(MedicationListLayout.orderMaxEntries))
        let previous = listLayout
        guard capped != previous.order else { return .success }
        listLayout = MedicationListLayout(
            version: previous.version,
            view: previous.view,
            order: capped
        )
        do {
            let resolved = try await repo.updateListLayout(.init(order: capped))
            try sessionLease.requireCurrent()
            listLayout = resolved
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = err
            if err.shouldPersistToOutbox {
                return .queued
            }
            listLayout = previous
            return .failed(err)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            listLayout = previous
            return .failed(wrapped)
        }
    }

    /// Derived: rows the user has not archived (UI's "active" tab).
    ///
    /// **M2** — honours the saved per-account manual `order` from
    /// `/api/medications/layout` so the list matches the web/other devices.
    /// An empty saved order is a pure passthrough (plain server order).
    var activeMedications: [Medication] {
        listLayout.applied(to: medications.filter(\.active), id: \.id)
    }

    /// Derived: archived rows, newest-first.
    var archivedMedications: [Medication] {
        medications
            .filter { !$0.active }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    private func archiving(_ medication: Medication, at timestamp: Date) -> Medication {
        Medication(
            id: medication.id,
            name: medication.name,
            dose: medication.dose,
            treatmentClass: medication.treatmentClass,
            category: medication.category,
            dosesPerUnit: medication.dosesPerUnit,
            schedule: medication.schedule,
            lastTakenAt: medication.lastTakenAt,
            todayEventCount: medication.todayEventCount,
            notificationsEnabled: medication.notificationsEnabled,
            active: false,
            archivedAt: timestamp
        )
    }

    /// Void-returning mark entry point for the Today-section swipe-actions.
    ///
    /// W-DEDUP-INTAKE — this is now a thin delegate to the canonical
    /// `markIntakeQuick`, the single source of truth for the optimistic
    /// patch + rollback + `takenAt = min(scheduledAt, now)` clamp (the b198
    /// phantom-dose fix) + synth-id routing + standalone-mirror handling.
    /// The only difference vs. `markIntakeQuick` is that this surface
    /// discards the `WriteOutcome` (the swipe-action UI has no `.queued`
    /// vs. `.failed` branch to drive); `markIntakeQuick` is
    /// `@discardableResult` so the call needs no `_ =`.
    func mark(intake id: String, status: IntakeStatus) async {
        await markIntakeQuick(intakeId: id, status: status)
    }

    // MARK: - W-MED2 synth-placeholder mark routing

    /// Synth-placeholder mark for the quick-mark surface — the single
    /// synth-id mark path (W-DEDUP-INTAKE retired the Void twin). The
    /// placeholder lives in `derivedTodayIntakes` only; we append an
    /// optimistic flipped-status row into `todayIntakes` itself so the
    /// `derivedTodayIntakes` merge keeps the placeholder suppressed by
    /// id-collision while the network attempt is in-flight. On success we
    /// invalidate the today-intakes cache key so the next observe pulls the
    /// real server-created row (the dedup window suppresses our synth
    /// shadow). Mirrors `markIntakeQuick`'s `.success` / `.queued` /
    /// `.failed` discrimination so the parent can drive the offline toast or
    /// the inline error banner.
    internal func markSynthesizedPlaceholderWithOutcome(
        intakeId: String,
        status: IntakeStatus,
        now: Date,
        injectionSite: InjectionSite? = nil
    ) async -> WriteOutcome {
        await markSynthesizedPlaceholderReturningReceipt(
            intakeId: intakeId,
            status: status,
            now: now,
            injectionSite: injectionSite
        ).outcome
    }

    /// The undo-aware variant also returns the exact server event id on a
    /// completed send, or the exact durable operation id when the send queued.
    internal func markSynthesizedPlaceholderReturningReceipt(
        intakeId: String,
        status: IntakeStatus,
        now: Date,
        injectionSite: InjectionSite? = nil
    ) async -> SynthesizedMarkReceipt {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            return SynthesizedMarkReceipt(outcome: .failed(.canceled), serverEventID: nil, queuedOperationID: nil)
        }
        guard let parsed = Self.parseSynthesizedPlaceholderID(intakeId) else {
            // Malformed synth id — treat as no-op rather than spurious
            // failure (UI sometimes invokes mark for a row that was
            // already replaced by a fresh server fetch between render
            // + tap).
            return SynthesizedMarkReceipt(outcome: .success, serverEventID: nil, queuedOperationID: nil)
        }
        // v0.8.2 W1b (B5): coalesce a rapid second tap — the first mark
        // owns the real outcome + the single CREATE; the duplicate is a
        // benign no-op (mirrors the malformed-id soft-success above).
        guard beginMark(intakeId) else {
            return SynthesizedMarkReceipt(outcome: .success, serverEventID: nil, queuedOperationID: nil)
        }
        defer { endMark(intakeId) }
        // M3 — clamp TAKEN to `min(scheduledAt, now)` (canonical), as above.
        let resolvedTakenAt = status == .taken ? min(parsed.scheduledAt, now) : nil
        let optimistic = MedicationIntake(
            id: intakeId,
            medicationId: parsed.medicationId,
            scheduledAt: parsed.scheduledAt,
            takenAt: resolvedTakenAt,
            status: status,
            snoozedUntil: nil
        )
        appendOrReplaceOptimisticSynth(intake: optimistic)
        let operationID = UUID()
        do {
            let serverEventID = try await repo.recordFromReminder(
                medicationId: parsed.medicationId,
                scheduledFor: parsed.scheduledAt,
                status: status,
                takenAt: resolvedTakenAt ?? now,
                injectionSite: injectionSite,
                operationID: operationID
            )
            try sessionLease.requireCurrent()
            await invalidateAfterSynthMark(sessionLease: sessionLease)
            try sessionLease.requireCurrent()
            // v0.6.1.4 Y4.2 — re-fetch the server-canonical snapshot
            // for the affected medication on the synth-mark path too.
            // PRN / weekly meds (Trulicity) take this branch since they
            // have no today-intake row before the operator marks one.
            let affectedMedicationID = parsed.medicationId
            complianceRefreshTask?.cancel()
            complianceRefreshTask = _Concurrency.Task { @MainActor [weak self] in
                await self?.refreshCardComplianceSnapshot(
                    for: affectedMedicationID,
                    sessionLease: sessionLease
                )
            }
            return SynthesizedMarkReceipt(
                outcome: .success,
                serverEventID: serverEventID,
                queuedOperationID: nil
            )
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                return SynthesizedMarkReceipt(outcome: .failed(.canceled), serverEventID: nil, queuedOperationID: nil)
            }
            error = err
            if err.shouldPersistToOutbox {
                // Outbox replays (incl. `.unauthorized` token-expiry, WW/F1) —
                // keep the optimistic patch visible.
                return SynthesizedMarkReceipt(
                    outcome: .queued,
                    serverEventID: nil,
                    queuedOperationID: operationID
                )
            }
            removeOptimisticSynth(id: intakeId)
            return SynthesizedMarkReceipt(outcome: .failed(err), serverEventID: nil, queuedOperationID: nil)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                return SynthesizedMarkReceipt(outcome: .failed(.canceled), serverEventID: nil, queuedOperationID: nil)
            }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            removeOptimisticSynth(id: intakeId)
            return SynthesizedMarkReceipt(
                outcome: .failed(wrapped),
                serverEventID: nil,
                queuedOperationID: nil
            )
        }
    }

    /// Append the synth-marked row to `todayIntakes` (or replace an
    /// existing entry under the same synth id if the user toggles
    /// status). The `derivedTodayIntakes` merge dedups against this on
    /// every render so the original placeholder is suppressed by its
    /// own optimistic shadow.
    ///
    /// v0.6.1.3 Y4.1 — fires `onIntakesDidChange` so the App-Badge
    /// recomputes the moment the optimistic synth row lands.
    private func appendOrReplaceOptimisticSynth(intake: MedicationIntake) {
        // audit-v0162 H-3 — bump so an in-flight revalidation can't drop this
        // optimistic synth row (which would re-surface the placeholder + climb
        // the badge back up).
        bumpMutationGeneration()
        if let idx = todayIntakes.firstIndex(where: { $0.id == intake.id }) {
            todayIntakes[idx] = intake
        } else {
            todayIntakes.append(intake)
        }
        // W-COMPLIANCE-INV — no cache invalidate here (PRN / weekly meds
        // take this path): the last server snapshot keeps painting until the
        // post-mark `refreshCardComplianceSnapshot` lands the canonical value.
        onIntakesDidChange?()
    }

    /// Roll-back for non-retriable failures — drop the optimistic row so
    /// the original synth placeholder re-surfaces in
    /// `derivedTodayIntakes`.
    ///
    /// v0.6.1.3 Y4.1 — fires `onIntakesDidChange` so the App-Badge
    /// catches up to the rollback.
    internal func removeOptimisticSynth(id: String) {
        bumpMutationGeneration() // H-3 — protect this optimistic rollback removal
        todayIntakes.removeAll { $0.id == id }
        onIntakesDidChange?()
    }

    /// Refresh + sibling-invalidate after a successful synth mark. The
    /// today-intakes key is invalidated (not writeThrough'd) so the
    /// next observe pulls the real server-created intake row and the
    /// dedup window suppresses the synth shadow. Sibling keys mirror
    /// `mark(intake:status:)`'s contract.
    internal func invalidateAfterSynthMark() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        await invalidateAfterSynthMark(sessionLease: sessionLease)
    }

    internal func invalidateAfterSynthMark(sessionLease: AuthenticatedSessionLease) async {
        guard let swr else { return }
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        await swr.invalidate([
            todayIntakesKey,
            // 15-03 (B4) — the medication row carries `lastTakenAt`; a
            // synthesised-slot mark is an intake write like any other.
            .medicationsList,
            .medicationsCompliance(days: Self.complianceDaysWindow),
            dashboardSummaryKey,
            .healthScore
        ])
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
    }
}
