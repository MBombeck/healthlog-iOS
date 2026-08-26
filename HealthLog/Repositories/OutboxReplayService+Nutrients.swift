import Foundation

// Nutrient-water outbox replay dispatch (Build 7.6, GH #48), split out of
// `OutboxReplayService.swift` to keep the actor body under the
// `type_body_length` budget — mirrors `+CustomMetrics` / `+Records`.
//
// An unwired repo dead-letters (non-retriable) so the queue can never wedge.

extension OutboxReplayService {
    /// Replay the manual water quick-add (`logNutrientWater`). Re-issues
    /// `POST /api/nutrients/water` under the persisted idempotency key; the
    /// server's `withIdempotency` on the route folds a replay that already landed
    /// into a no-op, so a quick-add tap can never double-increment the day total.
    /// A missing `nutrientReadRepo` dead-letters (non-retriable) so an unwired
    /// build never busy-loops.
    func dispatchNutrients(_ op: OutboxQueue.Operation) async throws {
        guard let nutrientReadRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — nutrientReadRepo unwired")
        }
        switch op.kind {
        case .logNutrientWater:
            let p = try decoder.decode(OutboxQueue.Payloads.LogNutrientWater.self, from: op.payload)
            _ = try await nutrientReadRepo.replayWaterQuickAdd(p.body, idempotencyKey: op.idempotencyKey)
        default:
            break
        }
    }
}
