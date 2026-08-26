import Foundation

// v1.25 PHI — outbox payload for the opt-in mental-health screener
// (`createMentalHealthAssessment`). Mirrors `OutboxQueue+Records.swift`: the
// shape is `Codable` + `Sendable` and re-issues the identical POST on the replay
// path under the persisted idempotency key, so an offline PHQ-9 / GAD-7 submit
// survives an app restart and replays at reachability (server `withIdempotency`
// dedups a replay-after-landed within 24h).
//
// SAFETY: the encoded `body.items` (incl. the raw item-9 answer) ride ONLY inside
// the encrypted outbox blob until replay — never a plaintext cache, never a log.
public extension OutboxQueue.Payloads {
    /// `createMentalHealthAssessment` — `POST /api/mental-health/assessments`.
    struct CreateMentalHealthAssessment: Codable, Sendable {
        public let body: CreateAssessmentRequest
        public init(body: CreateAssessmentRequest) {
            self.body = body
        }
    }
}
