import Foundation

// A5 (1.4, R3 S4) — Apple Health deletions that could not reach the server at
// once wait here, bound to the account whose samples they name.
//
// The server route (`DELETE /api/measurements/by-external-ids`, v1.43.10)
// soft-deletes only the caller's `APPLE_HEALTH` rows, skips every id it does
// not hold, and touches a row at most once (`deletedAt: null` guard). A replay
// is therefore harmless at any age, which is why this kind needs neither the
// 23-hour unconfirmed window nor a dead-letter on refusal.
//
// Platform-free: compiled into `HealthLogCore` and the widget extension like
// the rest of the queue.

public extension OutboxQueue.Payloads {
    /// `deleteHealthKitSamples` — `DELETE /api/measurements/by-external-ids`.
    /// At most ``OutboxQueue/maxHealthKitDeletionIDs`` HealthKit sample UUIDs,
    /// exactly the body the route takes (`{ externalIds }`, strict).
    struct DeleteHealthKitSamples: Codable, Sendable {
        public let externalIds: [String]
        public init(externalIds: [String]) {
            self.externalIds = externalIds
        }
    }
}

public extension OutboxQueue {
    /// The route's own bound (`MAX_BATCH_ENTRIES = 500`).
    static let maxHealthKitDeletionIDs = 500

    /// Keeps one batch of deleted HealthKit sample UUIDs for the replay, under
    /// an explicitly captured owner: a deletion read for account A is never
    /// stamped onto account B. `idempotencyKey` is the row's identity, derived
    /// from the batch, so a page read again finds its batch already waiting
    /// (`hasLiveOperation`); the DELETE itself carries no key header.
    func enqueueHealthKitDeletion(
        _ externalIDs: [String],
        idempotencyKey: String,
        requiringCurrentOwner ownerUserID: String
    ) async throws {
        guard !externalIDs.isEmpty else { return }
        try await enqueue(
            .init(
                kind: .deleteHealthKitSamples,
                payload: JSONEncoder.hlDefault.encode(Payloads.DeleteHealthKitSamples(externalIds: externalIDs)),
                idempotencyKey: idempotencyKey,
                ownerUserID: ownerUserID
            ),
            requiringCurrentOwner: ownerUserID
        )
    }
}
