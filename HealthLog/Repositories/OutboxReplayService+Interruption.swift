import Foundation

// C4 — answers the replay used to delete although they are not a refusal.
//
// Until C4 every error that was neither `shouldPersistToOutbox` nor a decode
// failure of our own payload reached `onNonRetriable`, and that removed the
// row. Three classes of answer got there without the server ever saying "no":
//
//   * **Cancellation.** `URLError.cancelled` (mapped to `HLError.canceled`) or
//     a raw `CancellationError` out of `APIClient`'s back-off sleep — what a
//     `BGTask` expiration, the end of a background window or an app suspend
//     produces while a row is on the wire. The queued medication intake, blood
//     pressure or mood entry was deleted, and the footer called it a server
//     rejection. A HealthKit page went the same way, after its importer had
//     already moved the anchor past it.
//   * **An unreadable 2xx** (`HLError.decoding`): the write may well have
//     landed, or a captive portal answered in its place. Deleting it lost the
//     second case; sending it again blindly would duplicate the first.
//   * **A refusal the server names** (a 4xx): the row was removed, so the data
//     of a refused create or edit was gone, only a count was left.
//
// Now:
//
//   * a cancellation leaves the row exactly as it was — no attempt counted, no
//     stamp — and ends the pass; the next trigger carries on;
//   * an unreadable 2xx is "sent, unconfirmed": the row stays and goes out
//     again under the SAME idempotency key, which the server answers with the
//     first response for 24 h (`src/lib/idempotency.ts`, v1.39.0). Once that
//     window has run out it is never sent again but dead-lettered — retained,
//     counted, recoverable;
//   * a named refusal dead-letters the row instead of deleting it, unless the
//     row carries nothing to lose (a delete) or its readings are already in
//     the skip register (a refused HealthKit page).

extension OutboxReplayService {
    /// How long after the first unconfirmed send a re-send is still answered
    /// from the server's idempotency cache: its TTL is 24 h, one hour stays
    /// free for clock skew and time on the wire.
    static let unconfirmedResendWindow: TimeInterval = 23 * 3600

    /// `lastError` of an unconfirmed row: this prefix plus the epoch second of
    /// the first unreadable answer.
    static let unconfirmedPrefix = "unconfirmed:since="

    /// Kinds whose server side folds a repeat by `externalId` (measurement and
    /// workout batches upsert), so a re-send is harmless at any age and the
    /// window does not apply.
    static let externalIdDedupedKinds: Set<OutboxQueue.Operation.Kind> = [
        .syncHealthKitSample, .uploadWorkoutBatch
    ]

    /// Kinds that carry nothing a refusal could lose: the record is either gone
    /// already or still on the server.
    static let deleteKinds: Set<OutboxQueue.Operation.Kind> = [
        .deleteMeasurement, .bulkDeleteMeasurements, .deleteMood, .deleteMedication, .deleteIntake,
        .deleteMedicationSideEffect, .deleteMedicationInventory, .deleteCycleDayLog, .deleteLab,
        .deleteBiomarker, .deleteIllnessEpisode, .deleteAllergy, .deleteFamilyHistory,
        .deleteCustomMetric, .deleteCustomMetricEntry
    ]

    // MARK: - Cancellation

    /// `true` when the failure says "stopped", not "no": the task was
    /// cancelled, the request was cancelled on the wire, or there is no server
    /// to send to at all. None of it is the write's fault.
    static func isInterruption(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        switch error as? HLError {
        // E1 — `APIClient` reports a write cut off on the wire (task still
        // running) as `.network(.writeCancelled)`; for the replay it is the same
        // interruption as `.canceled`.
        case .canceled?, .serverNotConfigured?, .network(.writeCancelled)?: return true
        default: return false
        }
    }

    /// The pass stops here and the row stays exactly as it was.
    func onInterrupted(_ op: OutboxQueue.Operation) {
        // Kind is a finite operator-grade enum; no id, no payload.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info("Op \(op.kind.rawValue, privacy: .public) interrupted — row untouched, pass ends")
    }

    /// `onNonRetriable`, plus the entity key the pass must hold back: the row's
    /// own, while it stays live (unconfirmed or parked), so a dependent update
    /// or delete cannot overtake its create.
    func holdingDependents(_ op: OutboxQueue.Operation, afterNonRetriable error: Error, now: Date) async -> Set<String> {
        guard await onNonRetriable(op, error: error, now: now), let key = op.clientEntityId else { return [] }
        return [key]
    }

    // MARK: - Sent, unconfirmed

    /// The row's first unconfirmed answer, read from its `lastError` marker.
    static func unconfirmedSince(_ lastError: String?) -> Date? {
        guard let lastError, lastError.hasPrefix(unconfirmedPrefix),
              let seconds = TimeInterval(lastError.dropFirst(unconfirmedPrefix.count)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The pre-send gate of the pass. A delivered row only owes its local
    /// delete (audit B-2) and is finished here. A row whose unconfirmed window
    /// has run out is dead-lettered here, before it could go out a second time
    /// as a new record. Everything else defers to ``isOnHoldThisPass(_:now:)``.
    func holdsThisPass(_ op: OutboxQueue.Operation, now: Date) async -> Bool {
        if isDelivered(op) {
            await completeDelivery(op)
            return true
        }
        if !Self.externalIdDedupedKinds.contains(op.kind),
           let since = Self.unconfirmedSince(op.lastError),
           now.timeIntervalSince(since) >= Self.unconfirmedResendWindow
        {
            await retainAsDeadLetter(op, reason: .responseUnreadable, lastError: op.lastError, now: now)
            return true
        }
        return isOnHoldThisPass(op, now: now)
    }

    /// An unreadable 2xx: keep the row, count the attempt, and remember when
    /// the first such answer came so the window above holds across passes.
    func onUnconfirmed(_ op: OutboxQueue.Operation, now: Date) async {
        let since = Self.unconfirmedSince(op.lastError) ?? now
        let marker = "\(Self.unconfirmedPrefix)\(Int(since.timeIntervalSince1970))"
        try? await outbox.incrementAttempts(id: op.id, lastError: marker)
        // Kind is a finite operator-grade enum; no id, no payload.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.warning("Op \(op.kind.rawValue, privacy: .public) sent, unconfirmed — kept for a re-send under its key")
    }

    /// The `lastError` a counted retriable failure writes: its own text, unless
    /// the row is unconfirmed — then the marker stays, or a later timeout would
    /// restart the window and let a re-send out past the server's cache.
    static func lastErrorKeepingUnconfirmed(_ op: OutboxQueue.Operation, _ sanitized: String) -> String {
        unconfirmedSince(op.lastError) != nil ? (op.lastError ?? sanitized) : sanitized
    }

    // MARK: - Refusals

    /// Whether dropping the row after a refusal loses nothing: a delete, or a
    /// HealthKit page whose refused readings `dispatchHealthKitBatch` has
    /// already written into the skip register.
    static func refusalLosesNothing(_ op: OutboxQueue.Operation, error: Error) -> Bool {
        if deleteKinds.contains(op.kind) { return true }
        if op.kind == .syncHealthKitSample, case .refused = HealthKitBatchRejection.classify(error) { return true }
        return false
    }

    /// Out of the live queue, never sent again, still on disk and counted —
    /// the same lane `onUndecodablePayload` uses.
    func retainAsDeadLetter(
        _ op: OutboxQueue.Operation,
        reason: OutboxDiscardNotice.Reason,
        lastError: String?,
        now: Date
    ) async {
        // Kind and reason are finite operator-grade vocabulary.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.error("Op \(op.kind.rawValue, privacy: .public) dead-lettered (\(reason.rawValue, privacy: .public)) — retained")
        do {
            try await outbox.markDeadLetter(id: op.id, lastError: lastError, now: now)
        } catch {
            // The row stays live and meets the same answer next pass — the
            // safe direction.
            HLLog.outbox.error("Outbox dead-letter mark failed: \(LogSanitizer.redact(String(describing: error)))")
        }
        await publishDiscard(.init(kind: op.kind.rawValue, reason: reason))
    }
}
