import Foundation

// Phase 07 Wave 1 — the focused HealthKit surface of the outbox queue.
//
// Two things live here, and they are two halves of one rule: a HealthKit write
// on the queue must be attributable, and a row that is not attributable must
// never move.
//
//   * Enqueue. `syncHealthKitSample` rows carry the exact wire bytes
//     `MeasurementBatchUploader` would have POSTed. The importer overload adds
//     the two things a *retry* needs and a fresh POST does not: an idempotency
//     key derived from the payload's own stable identity (so a relaunch rebuilds
//     the same key instead of minting a second write) and an explicitly captured
//     owner (so a failure that resumes after A→B cannot be stamped as B).
//
//   * Quarantine. Two on-disk shapes cannot be attributed by this build at all.
//     A row with no recorded owner, and a row whose `kindRaw` this build cannot
//     name. Both are health writes; both are retained, neither is transmitted,
//     deleted, or re-stamped.
//
// The enqueue conformance the device forwarder uses was extracted here from
// `DeviceReadingForwarder.swift`; the forwarder's protocol conformance now
// delegates to it. The protocol itself stays in the forwarder because it is
// declared inside `#if canImport(HealthKit)` in an app-only file, while this
// file compiles into the platform-free `HealthLogCore` module and the widget
// extension as well.

/// Why a row cannot be attributed, and therefore cannot move.
///
/// Both cases are *durable* states of the row rather than of this pass: nothing
/// here mutates the row, so the exact bytes — including the `kindRaw` word this
/// build could not name — stay on disk for the build that can.
public enum OutboxQuarantineReason: String, Sendable, Equatable, CaseIterable {
    /// The row records no owner (`nil` or blank). It predates the v0.13 owner
    /// stamp, or it was enqueued while nobody was signed in.
    case unownedRow
    /// The row's `kindRaw` is a word this build does not know — a newer client
    /// wrote it, or the schema drifted across an upgrade.
    case unrecognizedKind
}

public extension OutboxQueue.Operation {
    /// The quarantine verdict for this row against the account that is signed
    /// in right now.
    ///
    /// An unrecognized kind is quarantined unconditionally: this build cannot
    /// say what the row means, so it cannot say the row is safe to send.
    ///
    /// An unowned row is quarantined **while a named account is signed in**.
    /// That is where the harm lives: the signed-in account is not evidence of
    /// ownership, and transmitting under it — or stamping it onto the row —
    /// would file one person's health data into another person's record. While
    /// no account is signed in there is nothing to adopt the row into and no
    /// bearer to send it with, so the row simply waits, exactly as it did
    /// before Phase 07.
    func quarantineReason(currentUserID: String?) -> OutboxQuarantineReason? {
        if kind == .unrecognized { return .unrecognizedKind }
        let owner = ownerUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ambient = currentUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if owner.isEmpty, !ambient.isEmpty { return .unownedRow }
        return nil
    }
}

public extension OutboxQueue {
    /// Device-forwarder path — the batch has no externally stable identity of
    /// its own, so the queue mints the retry key and the enqueue chokepoint
    /// stamps whichever owner is signed in.
    ///
    /// Extracted verbatim from the `DeviceReadingOutboxEnqueuing` conformance
    /// so the payload shape has exactly one definition.
    func enqueueHealthKitBatch(
        _ entries: [HealthKitBatchEntryDTO],
        encoder: JSONEncoder
    ) async throws {
        guard !entries.isEmpty else { return }
        try await enqueue(.init(
            kind: .syncHealthKitSample,
            payload: Self.encodeBatch(entries, encoder: encoder)
        ))
    }

    /// Importer path — restart-stable identity and an explicitly captured owner.
    ///
    /// `idempotencyKey` is expected to be *derived* rather than minted (see
    /// `HealthSyncRetryEnvelope.idempotencyKey`): the point of this overload is
    /// that a process which dies between the enqueue and the cursor write
    /// rebuilds the same key on relaunch, so the server's replay window folds
    /// the retry instead of writing a second row.
    ///
    /// The enqueue is refused outright when `ownerUserID` no longer owns the
    /// live session, so a long-running import that resumes after an account
    /// switch cannot persist account A's samples as account B's.
    func enqueueHealthKitBatch(
        _ entries: [HealthKitBatchEntryDTO],
        encoder: JSONEncoder,
        idempotencyKey: String,
        requiringCurrentOwner ownerUserID: String
    ) async throws {
        guard !entries.isEmpty else { return }
        try await enqueue(
            .init(
                kind: .syncHealthKitSample,
                payload: Self.encodeBatch(entries, encoder: encoder),
                idempotencyKey: idempotencyKey,
                ownerUserID: ownerUserID
            ),
            requiringCurrentOwner: ownerUserID
        )
    }

    /// The exact body `MeasurementBatchUploader.upload` would have POSTed. The
    /// `syncTrigger` is deliberately omitted: it describes the wake that
    /// produced the samples, and a replay happens in a different wake.
    private static func encodeBatch(
        _ entries: [HealthKitBatchEntryDTO],
        encoder: JSONEncoder
    ) throws -> Data {
        try encoder.encode(HealthKitBatchPayload(entries: entries))
    }
}
