import Foundation

// Outbox payloads for the custom-metric durable-write kinds. Split out of
// `OutboxQueue.swift` (file_length + type_body_length discipline), mirroring
// `OutboxQueue+LabsIllness.swift`.
//
// Each shape is `Codable` + `Sendable` and re-issues the identical write on the
// replay path under the persisted idempotency key, so an offline metric /
// value write survives an app restart and replays at reachability.
//
// **Idempotency per shape.** Only the two POST routes are wrapped in the
// server's `withIdempotency` (verified in the route files). The other four are
// naturally replay-safe: PATCH is same-body-same-end-state, the metric DELETE is
// a `deletedAt` tombstone stamp, and the entry DELETE 404s once the row is gone.

public extension OutboxQueue.Payloads {
    // MARK: - Metric definitions

    /// `createCustomMetric` — `POST /api/custom-metrics`. Server dedups within
    /// 24h on the persisted key. A replay whose name now matches a soft-deleted
    /// row REVIVES it rather than 409-ing, which is the desired outcome either
    /// way.
    struct CreateCustomMetric: Codable, Sendable {
        public let body: CustomMetricCreate
        public init(body: CustomMetricCreate) {
            self.body = body
        }
    }

    /// `updateCustomMetric` — `PATCH /api/custom-metrics/{id}` partial edit.
    /// The tri-state `RecordPatchField`s round-trip through the encrypted blob,
    /// so a queued "clear the target band" replays as a clear, not an omission.
    struct UpdateCustomMetric: Codable, Sendable {
        public let id: String
        public let patch: CustomMetricPatch
        public init(id: String, patch: CustomMetricPatch) {
            self.id = id
            self.patch = patch
        }
    }

    /// `deleteCustomMetric` — `DELETE /api/custom-metrics/{id}` (soft,
    /// tombstone-idempotent; the logged values survive server-side).
    struct DeleteCustomMetric: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    // MARK: - Logged values

    /// `createCustomMetricEntry` — `POST /api/custom-metrics/{id}/entries`.
    /// `metricID` may be an OPTIMISTIC id when the value was logged offline
    /// against a metric that was itself created offline; the replay service
    /// remaps it via `resolveEntityId` before re-issuing.
    struct CreateCustomMetricEntry: Codable, Sendable {
        public let metricID: String
        public let body: CustomMetricEntryCreate
        public init(metricID: String, body: CustomMetricEntryCreate) {
            self.metricID = metricID
            self.body = body
        }
    }

    /// `updateCustomMetricEntry` — `PATCH /api/custom-metrics/{id}/entries/{entryId}`.
    struct UpdateCustomMetricEntry: Codable, Sendable {
        public let metricID: String
        public let entryID: String
        public let patch: CustomMetricEntryPatch
        public init(metricID: String, entryID: String, patch: CustomMetricEntryPatch) {
            self.metricID = metricID
            self.entryID = entryID
            self.patch = patch
        }
    }

    /// `deleteCustomMetricEntry` — `DELETE /api/custom-metrics/{id}/entries/{entryId}`
    /// (HARD delete; a replay after the original landed 404s, which the queue
    /// treats as settled).
    struct DeleteCustomMetricEntry: Codable, Sendable {
        public let metricID: String
        public let entryID: String
        public init(metricID: String, entryID: String) {
            self.metricID = metricID
            self.entryID = entryID
        }
    }
}
