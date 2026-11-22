import Foundation

/// **Build 6.1 — free / back-dated intake logging.** Split out of
/// `MedicationsStore+IntakeMutations.swift` so that file stays under SwiftLint's
/// `file_length` ceiling (pure code movement, no behaviour change).
public extension MedicationsStore {
    /// Log a free, back-datable intake for `medicationId` — the "ich habe eine
    /// Dosis genommen/ausgelassen, trage sie nach"-flow that does NOT need a
    /// pending slot row. Routes to `MedicationsRepository.logIntake`
    /// (`POST /api/medications/{id}/intake`, idempotency + outbox).
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
            let written = try await repo.logIntake(
                medicationId: medicationId,
                scheduledFor: scheduledFor,
                takenAt: takenAt,
                skipped: skipped,
                doseTaken: doseTaken,
                injectionSite: injectionSite,
                forceSlotInstant: forceSlotInstant
            )
            try sessionLease.requireCurrent()
            // The logged dose may land on today or a past day; invalidate the
            // today key (pull the canonical row on next observe) + the intake
            // aggregates rather than optimistically patching a possibly-off-day
            // row into `todayIntakes`.
            if let swr {
                await swr.invalidate([todayIntakesKey] + intakeSiblingKeys)
                try sessionLease.requireCurrent()
            }
            // D3 #4: a write that named a slot answers with the row on it,
            // which may be another day's; silence that slot's reminder and
            // alarm now. An extra dose (no slot) answers with its own time,
            // which is no slot, so only the window read below decides.
            if scheduledFor != nil || forceSlotInstant != nil,
               written.status == .taken || written.status == .skipped
            {
                noteResolvedSlot(medicationId: medicationId, slotAt: written.scheduledAt)
            }
            refreshResolvedSlotsAfterWrite(medicationId: medicationId)
            await refreshCardComplianceSnapshot(for: medicationId, sessionLease: sessionLease)
            try sessionLease.requireCurrent()
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = IntakeWriteRefusal.explained(err)
            return err.shouldPersistToOutbox ? .queued : .failed(err)
        } catch let already as MedicationAlreadyTaken {
            // #191: the slot already held a take; nothing was written.
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = already.notice
            return .failed(already.notice)
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            return .failed(wrapped)
        }
    }
}

/// **#191 (final) — the slots the intake form offers come from the server.**
///
/// `GET /api/medications/{id}/dose-history` over the chosen day in the
/// account's zone lists exactly the slots the server will accept, cadence
/// (weekdays, every N weeks, rolling) included. The form offers those and
/// nothing else, so an off day never offers "counts for the 08:00 dose".
extension MedicationsStore {
    /// The open slots of `day` for `medicationId`; `nil` when the ledger
    /// could not be read (the form then records an extra dose).
    func daySlots(medicationId: String, day: Date) async -> [IntakeSlotAttribution.DaySlot]? {
        let calendar = MedicationDueRule.calendar(timeZone: profileTimeZone)
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        guard let ledger = try? await repo.doseHistory(
            medicationID: medicationId,
            from: start,
            to: end.addingTimeInterval(-1)
        ) else { return nil }
        return IntakeSlotAttribution.openDaySlots(ledger.rows)
    }
}

// MARK: - D3 #3 / #4: day slots and other days' resolved slots

/// The effects of `MedicationsStore+ResolvedBeyondToday.swift` (the pure
/// parts live there): the slot a write answered with, the `dose-history`
/// window read behind the session lease, and the ad-hoc tap's day slots.
extension MedicationsStore {
    /// The slot a write answered with (`scheduledFor` of the row, the
    /// canonical slot instant), noted before the window read confirms it.
    func noteResolvedSlot(medicationId: String, slotAt: Date) {
        let slot = MedicationReminderCompletion.ResolvedSlot(medicationId: medicationId, scheduledAt: slotAt)
        guard !beyondToday.slots.contains(slot) else { return }
        beyondToday.slots.append(slot)
        onIntakesDidChange?()
    }

    /// Reads the window after the app's own write for `medicationId`.
    func refreshResolvedSlotsAfterWrite(medicationId: String) {
        guard let medication = medications.first(where: { $0.id == medicationId }),
              Self.needsResolvedWindow(medication) else { return }
        _Concurrency.Task { @MainActor [weak self] in
            await self?.refreshResolvedSlotsBeyondToday(for: [medicationId], force: true)
        }
    }

    /// Reads the window for `medicationIDs` (throttled unless `force`) and
    /// runs `onIntakesDidChange` when the resolved set changed. A failed read
    /// keeps what was known.
    func refreshResolvedSlotsBeyondToday(for medicationIDs: [String], force: Bool = false, now: Date = .now) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        var changed = false
        for medicationId in medicationIDs {
            if !force, let readAt = beyondToday.readAt[medicationId],
               now.timeIntervalSince(readAt) < Self.resolvedWindowThrottle { continue }
            guard let ledger = try? await repo.doseHistory(
                medicationID: medicationId,
                from: now.addingTimeInterval(-Self.resolvedWindowLookBack),
                to: now.addingTimeInterval(Self.resolvedWindowLookAhead)
            ) else { continue }
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            beyondToday.readAt[medicationId] = now
            let fresh = Self.resolvedSlots(inLedger: ledger.rows, medicationId: medicationId)
            let others = beyondToday.slots.filter { $0.medicationId != medicationId }
            let next = others + fresh
            if Set(next) != Set(beyondToday.slots) {
                beyondToday.slots = next
                changed = true
            }
        }
        if changed { onIntakesDidChange?() }
    }

    // MARK: - D3 #3

    /// Today's open slots for an ad-hoc tap, as the server counts them; `nil`
    /// when the read fails or takes longer than two seconds, so a tap offline
    /// is not held up.
    func adHocDaySlots(for medication: Medication, now: Date = .now) async -> [IntakeSlotAttribution.DaySlot]? {
        guard !medication.asNeeded,
              medication.schedule.entries.contains(where: { $0.cadence != .asNeeded }) else { return nil }
        let medicationId = medication.id
        let read = _Concurrency.Task { @MainActor [weak self] in
            await self?.daySlots(medicationId: medicationId, day: now)
        }
        // Past two seconds the read is cancelled; a cancelled read is `nil`.
        let deadline = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .seconds(2))
            read.cancel()
        }
        let slots = await read.value
        deadline.cancel()
        return slots
    }
}
