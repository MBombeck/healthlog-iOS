import Foundation

// T-4 intake retro-mutate — the optimistic-mutation family for the detail
// screen's history rows, lifted VERBATIM out of `MedicationDetailStore.swift`
// (15-01, W-FILELEN) so that file stays under SwiftLint's 600-line ceiling.
// Pure code movement, no behaviour change; the only edit is the addition of
// ``applyOptimisticTimeEdit(eventId:takenAt:)`` below, which B1 needs and which
// belongs with the family it mirrors. `intakes` became `internal(set)` for this
// move (Swift's `private` is file-scoped) — this file and the store's own are
// still its only writers.
public extension MedicationDetailStore {
    // MARK: - T-4 Intake retro-mutate

    /// Optimistic patch on the local `intakes` array. The caller drives
    /// the actual server-side patch via `MedicationsStore.updateIntake` /
    /// `markIntakeRetroactively` / `deleteIntake`; this method just makes
    /// the row reflect the intent immediately while the network request
    /// is in flight. Returns the previous event so the caller can roll
    /// back on `WriteOutcome.failed`.
    @discardableResult
    func applyOptimisticMark(
        eventId: String,
        status: IntakeStatus,
        now: Date = .now
    ) -> PaginatedIntakeEvent? {
        guard let idx = intakes.firstIndex(where: { $0.id == eventId }) else {
            return nil
        }
        let original = intakes[idx]
        let patched: PaginatedIntakeEvent = switch status {
        case .taken:
            PaginatedIntakeEvent(
                id: original.id,
                takenAt: min(original.scheduledFor, now),
                skipped: false,
                scheduledFor: original.scheduledFor,
                injectionSite: original.injectionSite
            )
        case .skipped:
            PaginatedIntakeEvent(
                id: original.id,
                takenAt: nil,
                skipped: true,
                scheduledFor: original.scheduledFor,
                injectionSite: original.injectionSite
            )
        case .pending, .snoozed, .missed:
            // The retro-mutate UI doesn't surface these directly. Keep the
            // method total so callers don't have to assert at call-site.
            original
        }
        intakes[idx] = patched
        return original
    }

    /// **15-01 (B1)** — optimistic patch for a TIME correction on a row that is
    /// already taken. Distinct from ``applyOptimisticMark(eventId:status:now:)``,
    /// whose `.taken` branch pins the SCHEDULED instant ("I took it on time, I
    /// just forgot to log it"): here the user is saying the opposite — the
    /// scheduled instant is not when it happened. `skipped` is untouched
    /// (`false` is the only state this affordance is offered in). Returns the
    /// previous event so the caller can roll back via
    /// ``rollbackOptimisticMark(eventId:original:)``.
    @discardableResult
    func applyOptimisticTimeEdit(
        eventId: String,
        takenAt: Date
    ) -> PaginatedIntakeEvent? {
        guard let idx = intakes.firstIndex(where: { $0.id == eventId }) else {
            return nil
        }
        let original = intakes[idx]
        intakes[idx] = PaginatedIntakeEvent(
            id: original.id,
            takenAt: takenAt,
            skipped: original.skipped,
            scheduledFor: original.scheduledFor,
            injectionSite: original.injectionSite
        )
        return original
    }

    /// Roll back the optimistic patch — used when the server returns a
    /// non-retriable error (`.failed`). For `.queued` we keep the
    /// optimistic state visible; the outbox replay will reconcile on next
    /// reachability.
    func rollbackOptimisticMark(eventId: String, original: PaginatedIntakeEvent) {
        guard let idx = intakes.firstIndex(where: { $0.id == eventId }) else {
            // The row may have been removed by an unrelated refresh —
            // re-insert at the head as a defensive fallback. The next
            // `load()` will reorder it correctly.
            intakes.insert(original, at: 0)
            return
        }
        intakes[idx] = original
    }

    /// Optimistic delete — drops the row immediately and returns its
    /// previous index so the caller can re-insert on rollback.
    @discardableResult
    func applyOptimisticDelete(eventId: String) -> (event: PaginatedIntakeEvent, index: Int)? {
        guard let idx = intakes.firstIndex(where: { $0.id == eventId }) else {
            return nil
        }
        let event = intakes[idx]
        intakes.remove(at: idx)
        return (event, idx)
    }

    /// Re-insert a previously-deleted event at its prior index.
    func rollbackOptimisticDelete(_ event: PaginatedIntakeEvent, at index: Int) {
        let clamped = max(0, min(index, intakes.count))
        intakes.insert(event, at: clamped)
    }
}
