import Foundation

// Custom-metric outbox replay dispatch, split out of `OutboxReplayService.swift`
// to keep the actor body under the `type_body_length` budget (the dispatch arms
// are pure decode→re-issue leaves with no actor state beyond the injected repo +
// decoder). Mirrors `OutboxReplayService+LabsIllness.swift`.
//
// An unwired repo dead-letters (non-retriable) so the queue can never wedge.

extension OutboxReplayService {
    /// Replay the custom-metric definition + value writes.
    ///
    /// **The H-4 remap matters more here than anywhere else.** A user can define
    /// a metric AND log its first value in one offline session; the value's
    /// payload then carries the optimistic metric id. The create arm publishes
    /// the server-assigned id via `lastCreatedServerId`, and every entry arm
    /// funnels its `metricID` through `resolveEntityId` — so the queued value
    /// lands on the real metric instead of 404-ing into the dead-letter table.
    func dispatchCustomMetrics(_ op: OutboxQueue.Operation) async throws {
        guard let customMetricsRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — customMetricsRepo unwired")
        }
        let key = op.idempotencyKey
        switch op.kind {
        case .createCustomMetric:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateCustomMetric.self, from: op.payload)
            lastCreatedServerId = try await customMetricsRepo.replayCreateMetricReturningServerId(
                p.body, idempotencyKey: key
            )
        case .updateCustomMetric:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateCustomMetric.self, from: op.payload)
            try await customMetricsRepo.replayUpdateMetric(
                id: resolveEntityId(p.id, op: op), p.patch, idempotencyKey: key
            )
        case .deleteCustomMetric:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteCustomMetric.self, from: op.payload)
            try await customMetricsRepo.replayDeleteMetric(
                id: resolveEntityId(p.id, op: op), idempotencyKey: key
            )
        case .createCustomMetricEntry:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateCustomMetricEntry.self, from: op.payload)
            try await customMetricsRepo.replayCreateEntry(
                metricID: resolveEntityId(p.metricID, op: op), p.body, idempotencyKey: key
            )
        case .updateCustomMetricEntry:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateCustomMetricEntry.self, from: op.payload)
            try await customMetricsRepo.replayUpdateEntry(
                metricID: resolveEntityId(p.metricID, op: op),
                entryID: p.entryID, p.patch, idempotencyKey: key
            )
        case .deleteCustomMetricEntry:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteCustomMetricEntry.self, from: op.payload)
            try await customMetricsRepo.replayDeleteEntry(
                metricID: resolveEntityId(p.metricID, op: op),
                entryID: p.entryID, idempotencyKey: key
            )
        default:
            break
        }
    }
}
