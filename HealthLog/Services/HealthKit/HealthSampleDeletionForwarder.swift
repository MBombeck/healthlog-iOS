#if canImport(HealthKit)
    import Foundation
    import HealthKit

    /// **A5 (1.4, R3 S4) — Apple Health deletions of hand-kept readings, sent to
    /// the server.**
    ///
    /// A wrong weight or blood pressure the person deletes in Apple Health must
    /// leave the server too. The read path sends every sample with its HealthKit
    /// UUID as `externalId` (`HealthKitWireConverter`), and an `HKDeletedObject`
    /// carries exactly that UUID, so the UUID is the whole link. Its metadata is
    /// not: HealthKit keeps only `HKMetadataKeySyncIdentifier` and
    /// `HKMetadataKeySyncVersion` on a deleted object, so neither our external
    /// UUID nor our origin marker survives a deletion.
    ///
    /// **Server contract** (`DELETE /api/measurements/by-external-ids`,
    /// v1.43.10, unchanged in v1.44.0): body `{ externalIds }`, at most 500,
    /// strict (no other key, so no `syncTrigger`). It soft-deletes only the
    /// caller's rows with `source = APPLE_HEALTH`, skips every id it does not
    /// hold, and touches a row once. A deletion that names a sample the server
    /// never had is a no-op there. So is a copy this app wrote into Apple
    /// Health (never uploaded, see `HealthKitSampleOwnership.isOwnEcho`); since
    /// A6 a copy that carries its sync identifier does not even get here.
    struct HealthSampleDeletionForwarder: Sendable {
        /// The types whose deletions are forwarded: readings people keep by hand
        /// (or a scale keeps for them) and the server keeps raw, one row per
        /// sample, at any age. Waist circumference joined in A6, now that B5
        /// reads it (`WAIST_CIRCUMFERENCE`, raw, under the sample's UUID).
        ///
        /// Left out on purpose, after the server's own lists (v1.43.10):
        /// * Summed types (steps, active energy, flights, distance, daylight) go
        ///   up as `stats:` day and hour totals; their raw UUIDs are not on the
        ///   server (`CUMULATIVE_HK_TYPES`).
        /// * Pulse, HRV (SDNN) and SpO2 are folded into hourly `stats:` rows
        ///   after 90 days (`DENSE_INTRADAY_RETENTION_TYPES`); recent pulse goes
        ///   up as 10-minute buckets.
        /// * Respiratory rate, audio exposure, the walking and stair metrics and
        ///   the walking heart-rate average are folded into daily means after
        ///   36 hours (`HIGH_FREQUENCY_MEAN_TYPES`).
        ///
        /// A folded raw sample is gone from the server; its deletion could not
        /// take the reading out of the hour or day it went into.
        static let forwardedTypes: Set<String> = [
            HKQuantityTypeIdentifier.bodyMass.rawValue,
            HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
            HKQuantityTypeIdentifier.leanBodyMass.rawValue,
            HKQuantityTypeIdentifier.bodyMassIndex.rawValue,
            HKQuantityTypeIdentifier.bodyTemperature.rawValue,
            HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
            HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue,
            HKQuantityTypeIdentifier.bloodGlucose.rawValue,
            HKQuantityTypeIdentifier.waistCircumference.rawValue
        ]

        /// The send: `MeasurementsRepository`, through its conformance.
        let server: (any MeasurementDeletionReconciler)?
        /// Where a batch waits when it cannot be sent: the outbox.
        let queue: (any HealthSyncBatchRetryEnqueuing)?

        /// Forwards one page's deletions. `nil` when every one is accounted for
        /// (sent, kept in the outbox, refused for good, or not forwarded);
        /// otherwise why the cursor must hold.
        func forward(
            _ externalIDs: [String],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            guard Self.forwardedTypes.contains(typeIdentifier) else { return nil }
            var seen = Set<String>()
            let ids = externalIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
            let bound = OutboxQueue.maxHealthKitDeletionIDs
            for start in stride(from: 0, to: ids.count, by: bound) {
                let batch = Array(ids[start ..< min(start + bound, ids.count)])
                if let held = await forwardBatch(batch, requiring: lease) { return held }
            }
            return nil
        }

        /// One batch: sent, kept for the replay, or refused for good.
        private func forwardBatch(
            _ ids: [String],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            if let refusal = lease.refusal { return refusal.holdReason }
            guard let server else { return await keep(ids, requiring: lease) }
            do {
                try await lease.admitting { try await server.reconcileDeletedExternalIDs(ids) }
                Self.note("sent", ids.count)
                return nil
            } catch let refusal as HealthSyncLeaseRefusal {
                return refusal.holdReason
            } catch let error where HealthSampleConsumption.isCancellation(error) {
                return .cancelled
            } catch let error where Self.isRefusedForGood(error) {
                // The server read the request and said no; the same body would
                // earn the same answer.
                Self.note("refused", ids.count)
                return nil
            } catch {
                return await keep(ids, requiring: lease)
            }
        }

        /// Keeps a batch for the replay, under the owner it was read for. The
        /// key comes from the batch itself, so a page read again after a hold
        /// finds its batch already waiting instead of adding a second.
        private func keep(
            _ ids: [String],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            guard let queue, let envelope = HealthSyncRetryEnvelope(
                ownerID: lease.ownerID,
                source: lease.source,
                stableIdentity: "delete:" + ids.sorted().joined(separator: "|")
            ) else {
                return .retryPersistenceFailed
            }
            if await queue.hasPendingHealthKitRetry(idempotencyKey: envelope.idempotencyKey) { return nil }
            do {
                try await lease.admitting {
                    try await queue.enqueueHealthKitDeletion(
                        ids,
                        idempotencyKey: envelope.idempotencyKey,
                        requiringCurrentOwner: lease.ownerID
                    )
                }
                Self.note("kept for the replay", ids.count)
                return nil
            } catch let refusal as HealthSyncLeaseRefusal {
                return refusal.holdReason
            } catch {
                HLLog.healthKit.error("health deletions could not be kept — cursor holds")
                return .retryPersistenceFailed
            }
        }

        /// A refusal no retry can change: a 4xx other than 401, 408 and 429.
        /// An unreadable answer is not one (the delete may have landed, and a
        /// repeat is harmless), and neither is anything that is not an
        /// `HLError`.
        static func isRefusedForGood(_ error: Error) -> Bool {
            guard let error = error as? HLError else { return false }
            if case .decoding = error { return false }
            return error != .serverNotConfigured && !error.shouldPersistToOutbox
        }

        private static func note(_ what: String, _ count: Int) {
            // A fixed phrase and a count: no id, no type, no value, no owner.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("health deletions \(what, privacy: .public): \(count, privacy: .public)")
        }
    }
#endif
