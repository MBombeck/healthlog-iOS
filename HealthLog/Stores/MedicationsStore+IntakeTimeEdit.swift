import Foundation

// MARK: - 15-01 (B1) — editing an intake's time

/// The local half of an intake edit, plus the one entry point the history row
/// uses. Everything here is synchronous on purpose: it runs before (or after)
/// the network attempt inside ``MedicationsStore/updateIntake(medicationId:eventId:patch:)``,
/// never across it, so the authenticated-effect fence that guards that method's
/// suspension points is neither widened nor duplicated.
public extension MedicationsStore {
    /// v1.15.19 — the server's forward plausibility allowance on `takenAt`
    /// (five minutes of clock skew). Mirrored client-side so an edit can never
    /// round-trip into the 422 the server would answer with.
    static let takenAtFutureSkew: TimeInterval = 5 * 60

    /// **B1 — correct the time of an intake that was taken.**
    ///
    /// Sends `takenAt` ALONE: the entry's status is not up for renegotiation
    /// here (`skipped` stays whatever the server holds), which is why the
    /// affordance is offered only on rows that already carry an administration
    /// instant. The optimistic patch + rollback ride
    /// ``MedicationsStore/updateIntake(medicationId:eventId:patch:)`` — this
    /// method adds only the bound check, so a nonsense instant costs no
    /// round-trip and reads the same copy the server would send back.
    @discardableResult
    func editIntakeTakenAt(
        medicationId: String,
        eventId: String,
        takenAt: Date,
        now: Date = .now
    ) async -> WriteOutcome {
        guard takenAt <= now.addingTimeInterval(Self.takenAtFutureSkew),
              takenAt >= now.addingTimeInterval(-Self.takenAtMaxAge) else
        {
            let err = HLError.server(
                status: 422,
                code: "medications.intake.taken_at.out_of_range",
                message: String(localized: "med.intake.taken_at.out_of_range")
            )
            error = err
            return .failed(err)
        }
        return await updateIntake(
            medicationId: medicationId,
            eventId: eventId,
            patch: .init(takenAtField: .value(takenAt))
        )
    }

    /// Apply what `patch` states to today's copy of `eventId` and return the
    /// row as it was, so a refusal can put it back byte-for-byte. Returns `nil`
    /// — meaning "nothing to take back" — when the row is not in today's list
    /// or the patch says nothing about status or administration instant (slot
    /// pin / unpin, whose local truth is the server's re-attribution).
    @discardableResult
    func optimisticallyApply(
        _ patch: MedicationsRepository.IntakePatch,
        toIntake eventId: String
    ) -> MedicationIntake? {
        guard let index = todayIntakes.firstIndex(where: { $0.id == eventId }) else { return nil }
        let original = todayIntakes[index]
        guard let patched = Self.locallyPatched(original, with: patch) else { return nil }
        bumpMutationGeneration() // H-3 — protect this optimistic patch
        todayIntakes[index] = patched
        // Y4.1 — the badge follows the optimistic patch, exactly as on the
        // quick-mark path.
        onIntakesDidChange?()
        return original
    }

    /// Put back the row ``optimisticallyApply(_:toIntake:)`` replaced. A `nil`
    /// snapshot is the no-op case (nothing was ever applied).
    func restoreIntakeSnapshot(_ original: MedicationIntake?) {
        guard let original,
              let index = todayIntakes.firstIndex(where: { $0.id == original.id }) else { return }
        todayIntakes[index] = original
        onIntakesDidChange?()
    }

    /// The row `patch` describes, read against `original`. `nil` when the patch
    /// carries no local statement at all.
    static func locallyPatched(
        _ original: MedicationIntake,
        with patch: MedicationsRepository.IntakePatch
    ) -> MedicationIntake? {
        let statesTakenAt = patch.takenAt != MedicationsRepository.PatchField<Date>.absent
        guard statesTakenAt || patch.skipped != nil else { return nil }
        let takenAt: Date? = switch patch.takenAt {
        case .absent: original.takenAt
        case .null: nil
        case let .value(instant): instant
        }
        let skipped = patch.skipped ?? (original.status == .skipped)
        let status: IntakeStatus = if skipped {
            .skipped
        } else if takenAt != nil {
            .taken
        } else {
            .pending
        }
        return MedicationIntake(
            id: original.id,
            medicationId: original.medicationId,
            scheduledAt: original.scheduledAt,
            takenAt: skipped ? nil : takenAt,
            status: status,
            snoozedUntil: original.snoozedUntil
        )
    }
}
