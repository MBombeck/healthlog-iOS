import Foundation

public extension MedicationsStore {
    // swiftformat:disable redundantSendable
    // Explicit Sendable is required because IntakeMarkUndo crosses into the
    // @Sendable closure owned by UndoCoordinator.

    /// Exact inverse descriptor for a quick medication mark.
    struct IntakeMarkUndo: Sendable {
        public enum Kind: Sendable {
            case realIntake(snapshot: MedicationIntake)
            case synthesized(
                medicationId: String,
                scheduledAt: Date,
                intakeId: String,
                serverEventID: String?,
                queuedOperationID: UUID?
            )
        }

        public let kind: Kind
        public let medicationId: String
        /// The idempotency key the mark went out under. The undo sends it as
        /// `expectedIdempotencyKey` (#191), so it removes only this take.
        public var idempotencyKey: String?
        /// The row's `syncVersion` from the write answer, when the server
        /// sent one; the undo sends it next to the key (#191, final).
        public var syncVersion: Int?
    }

    // swiftformat:enable redundantSendable

    /// Result metadata needed to invert either an online or queued synth mark.
    struct SynthesizedMarkReceipt {
        let outcome: WriteOutcome
        let serverEventID: String?
        let queuedOperationID: UUID?
        /// The key of the bulk entry; see ``IntakeMarkUndo/idempotencyKey``.
        var idempotencyKey: String?
        /// See ``IntakeMarkUndo/syncVersion``.
        var syncVersion: Int?
    }

    /// Performs a quick mark and installs its exact inverse in the global undo
    /// coordinator only when the original operation actually landed or queued.
    @discardableResult
    func markIntakeQuickUndoable(
        intakeId: String,
        status: IntakeStatus,
        now: Date = .now,
        injectionSite: InjectionSite? = nil
    ) async -> WriteOutcome {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        if status == .taken, !bulkAnswersAlreadyTaken,
           let notice = await alreadyTakenAfterReread(intakeId: intakeId, now: now)
        {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
            error = notice
            return .failed(notice)
        }
        let (outcome, undo) = await markIntakeQuickReturningUndo(
            intakeId: intakeId,
            status: status,
            now: now,
            injectionSite: injectionSite
        )
        guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
        if let undo {
            let name = medications.first { $0.id == undo.medicationId }?.name
            undoCoordinator?.enqueue(message: Self.markToast(status: status, name: name, at: now)) { [weak self] in
                guard let self, sessionLease.isCurrent else { return }
                await undoIntakeMark(undo)
            }
        }
        return outcome
    }
}

extension MedicationsStore {
    /// The toast after a take or a skip (term list, #191): "Lisinopril: taken,
    /// 08:12" / "Lisinopril: skipped". Without a name the older plain line.
    nonisolated static func markToast(status: IntakeStatus, name: String?, at time: Date) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return status == .taken
                ? String(localized: "undo.medication.taken")
                : String(localized: "undo.medication.skipped")
        }
        return status == .taken
            ? MedicationDoseWords.toastTaken(name: trimmed, time: HLTimeFormat.time(time))
            : MedicationDoseWords.toastSkipped(name: trimmed)
    }
}

extension MedicationsStore {
    /// **#191 (changing) — the server refuses a second take itself.** With
    /// ``MedicationCapability/bulkAlreadyTaken`` the bulk route answers
    /// `alreadyTaken` per entry, so the re-read before a take
    /// (``alreadyTakenAfterReread(intakeId:now:)``) costs a request and saves
    /// nothing.
    var bulkAnswersAlreadyTaken: Bool {
        MedicationCapabilities.isOpen(.bulkAlreadyTaken, defaults: contract.capabilityDefaults)
    }

    /// How old today's list may be before a take re-reads it (#189 (6)).
    static let takeRereadAfter: TimeInterval = 3 * 60

    /// **#189 (6) — re-read before a take when the list is old.** A dose the
    /// pill box or Telegram recorded a few minutes ago is not in a list read
    /// an hour ago; taking it again would be a second dose. When the last
    /// server answer for today is older than ``takeRereadAfter`` the list is
    /// reloaded first, and a slot it now shows taken is not taken again:
    /// the returned notice says when it was. Only with the SWR stack, which
    /// production always has.
    func alreadyTakenAfterReread(intakeId: String, now: Date) async -> HLError? {
        guard swr != nil,
              let target = derivedTodayIntakes.first(where: { $0.id == intakeId }),
              target.status != .taken else { return nil }
        if let fresh = lastFreshTodayIntakesAt, now.timeIntervalSince(fresh) < Self.takeRereadAfter { return nil }
        await load(force: true)
        guard let taken = Self.takenSibling(of: target, in: derivedTodayIntakes) else { return nil }
        return MedicationAlreadyTaken(takenAt: taken.takenAt, source: taken.takenVia).notice
    }

    /// The taken row of `target`'s slot, if the list now has one.
    nonisolated static func takenSibling(of target: MedicationIntake, in intakes: [MedicationIntake]) -> MedicationIntake? {
        intakes.first {
            $0.medicationId == target.medicationId
                && $0.status == .taken
                && abs($0.scheduledAt.timeIntervalSince(target.scheduledAt)) < 60
        }
    }
}

extension MedicationsStore {
    /// **#191 — the precondition an undo sends.** The version the person
    /// saw: the row's `syncVersion` when the list carried one, else the key
    /// the app's own take went out under.
    func undoPrecondition(syncVersion: Int? = nil, idempotencyKey: String?) -> IntakeUndoPrecondition? {
        IntakeUndoPrecondition(syncVersion: syncVersion, idempotencyKey: idempotencyKey)
    }

    /// The undo's catch: a `changedSinceSeen` answer replaces the raw 409
    /// with the plain notice; any other error is left as it is.
    func explainIfChangedSinceSeen(_ error: HLError) async {
        if IntakeUndoPrecondition.isInvalidPrecondition(error) {
            self.error = IntakeUndoPrecondition.invalidPreconditionNotice
            return
        }
        guard IntakeUndoPrecondition.isChangedSinceSeen(error) else { return }
        _ = await reportChangedSinceSeen()
    }

    /// `409 medications.intake.changedSinceSeen`: someone else changed the
    /// dose since the person saw it, nothing was removed. Says so in plain
    /// words and re-reads today, so the screen shows what the server now has.
    func reportChangedSinceSeen() async -> WriteOutcome {
        let notice = IntakeUndoPrecondition.changedSinceSeenNotice
        error = notice
        if let swr { await swr.invalidate([todayIntakesKey] + intakeSiblingKeys) }
        return .failed(notice)
    }
}
