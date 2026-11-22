import Foundation

// #12 — a queued take that meets a dose already recorded.
//
// The take was queued offline; meanwhile the pill box (or another device)
// recorded the same slot. The server answers `alreadyTaken` and records
// nothing, which is the right answer: there is exactly one dose. Up to 1.6 the
// replay did not know the error (it is not an `HLError`), dead-lettered the row
// as `unroutable` and offered "Erneut senden", which met the same answer again.
// It is a delivery: the row goes, and the person hears when the first dose was
// taken, the same note the banner path shows.

public extension OutboxReplayService {
    /// The local note for a replayed take the server already had. Same shape
    /// as ``HealthKitDeliveryNotifier``: the service also compiles into the
    /// widget extension, which has no notification centre to post to.
    typealias AlreadyTakenNotifier = @Sendable (MedicationAlreadyTaken) async -> Void

    /// Composition-root wiring, filled inside the init tick like the
    /// HealthKit delivery notifier.
    nonisolated func setAlreadyTakenNotifier(_ notifier: AlreadyTakenNotifier?) {
        alreadyTakenSlot.withLock { $0 = notifier }
    }

    /// The row is finished like a delivered one and never counted as a
    /// failure.
    internal func onAlreadyTaken(_ op: OutboxQueue.Operation, _ already: MedicationAlreadyTaken) async {
        deliveredIDs.insert(op.id)
        try? await outbox.markDelivered(id: op.id)
        // Kind only — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info("Op \(op.kind.rawValue, privacy: .public) already taken on the server — delivered")
        await completeDelivery(op)
        if let notifier = alreadyTakenSlot.withLock({ $0 }) {
            await notifier(already)
        }
    }
}
