import Foundation

// Outbox payload for the nutrient water quick-add kind (Build 7.6, GH #48).
// Split out of `OutboxQueue.swift` (file_length + type_body_length discipline),
// mirroring `OutboxQueue+CustomMetrics.swift`.
//
// The shape is `Codable` + `Sendable` and re-issues the identical
// `POST /api/nutrients/water` on the replay path under the persisted idempotency
// key, so an offline water quick-add survives an app restart and replays at
// reachability — the server's `withIdempotency` suppresses a replay that already
// landed.

public extension OutboxQueue.Payloads {
    /// `logNutrientWater` — `POST /api/nutrients/water`. Carries the exact wire
    /// body (amount + add/set mode + optional day). Replay drains via
    /// `OutboxReplayService.dispatchNutrients`.
    struct LogNutrientWater: Codable, Sendable {
        public let body: NutrientWaterWriteRequestDTO
        public init(body: NutrientWaterWriteRequestDTO) {
            self.body = body
        }
    }
}
