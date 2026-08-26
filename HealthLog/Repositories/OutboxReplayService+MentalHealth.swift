import Foundation

/// v1.25 PHI — mental-health screener outbox replay dispatch, split out of
/// `OutboxReplayService.swift` to keep the actor body under the
/// `type_body_length` budget (mirrors `+Records` / `+LabsIllness`). Re-issues the
/// identical POST under the persisted idempotency key; an unwired repo
/// dead-letters (non-retriable) so the queue can never wedge.
extension OutboxReplayService {
    /// Replay the PHQ-9 / GAD-7 submit (server `withIdempotency` dedups a
    /// replay-after-landed within 24h).
    func dispatchMentalHealth(_ op: OutboxQueue.Operation) async throws {
        guard let mentalHealthRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — mentalHealthRepo unwired")
        }
        switch op.kind {
        case .createMentalHealthAssessment:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateMentalHealthAssessment.self, from: op.payload)
            try await mentalHealthRepo.replaySubmit(p.body, idempotencyKey: op.idempotencyKey)
        default:
            break
        }
    }
}
