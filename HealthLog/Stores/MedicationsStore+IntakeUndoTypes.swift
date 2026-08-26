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
            case standaloneAdded(externalId: String, pendingSnapshot: MedicationIntake?)
        }

        public let kind: Kind
        public let medicationId: String
    }

    // swiftformat:enable redundantSendable

    /// Result metadata needed to invert either an online or queued synth mark.
    struct SynthesizedMarkReceipt {
        let outcome: WriteOutcome
        let serverEventID: String?
        let queuedOperationID: UUID?
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
        let (outcome, undo) = await markIntakeQuickReturningUndo(
            intakeId: intakeId,
            status: status,
            now: now,
            injectionSite: injectionSite
        )
        guard authenticatedEffectIsCurrent(sessionLease) else { return .failed(.canceled) }
        if let undo {
            let messageKey: LocalizedStringResource = status == .taken
                ? "undo.medication.taken"
                : "undo.medication.skipped"
            undoCoordinator?.enqueue(message: String(localized: messageKey)) { [weak self] in
                guard let self, sessionLease.isCurrent else { return }
                await undoIntakeMark(undo)
            }
        }
        return outcome
    }
}
