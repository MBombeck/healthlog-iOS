import Foundation

// v1.25 PHI — structured-records (allergy + family-history) outbox replay
// dispatch, split out of `OutboxReplayService.swift` to keep the actor body
// under the `type_body_length` budget (mirrors `+LabsIllness`). Each arm
// re-issues the identical request under the persisted idempotency key; an
// unwired repo dead-letters (non-retriable) so the queue can never wedge.

extension OutboxReplayService {
    /// Replay the allergy + family-history writes (server dedups a create within
    /// 24h; PATCH is idempotent; the soft-delete is tombstone-idempotent).
    func dispatchRecords(_ op: OutboxQueue.Operation) async throws {
        let key = op.idempotencyKey
        switch op.kind {
        case .createAllergy, .updateAllergy, .deleteAllergy:
            guard let allergiesRepo else {
                throw HLError.unknown("Op-Kind \(op.kind.rawValue) — allergiesRepo unwired")
            }
            try await dispatchAllergy(op, repo: allergiesRepo, key: key)
        case .createFamilyHistory, .updateFamilyHistory, .deleteFamilyHistory:
            guard let familyHistoryRepo else {
                throw HLError.unknown("Op-Kind \(op.kind.rawValue) — familyHistoryRepo unwired")
            }
            try await dispatchFamilyHistory(op, repo: familyHistoryRepo, key: key)
        default:
            break
        }
    }

    private func dispatchAllergy(_ op: OutboxQueue.Operation, repo: AllergiesRepository, key: String) async throws {
        switch op.kind {
        case .createAllergy:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateAllergy.self, from: op.payload)
            // audit-v0162 H-4 — capture the server id so `runOnce` can remap any
            // queued update/delete that still references the optimistic id.
            lastCreatedServerId = try await repo.replayCreateReturningServerId(p.body, idempotencyKey: key)
        case .updateAllergy:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateAllergy.self, from: op.payload)
            try await repo.replayUpdate(id: resolveEntityId(p.id, op: op), p.patch, idempotencyKey: key)
        case .deleteAllergy:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteAllergy.self, from: op.payload)
            try await repo.replayDelete(id: resolveEntityId(p.id, op: op), idempotencyKey: key)
        default:
            break
        }
    }

    private func dispatchFamilyHistory(_ op: OutboxQueue.Operation, repo: FamilyHistoryRepository, key: String) async throws {
        switch op.kind {
        case .createFamilyHistory:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateFamilyHistory.self, from: op.payload)
            lastCreatedServerId = try await repo.replayCreateReturningServerId(p.body, idempotencyKey: key)
        case .updateFamilyHistory:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateFamilyHistory.self, from: op.payload)
            try await repo.replayUpdate(id: resolveEntityId(p.id, op: op), p.patch, idempotencyKey: key)
        case .deleteFamilyHistory:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteFamilyHistory.self, from: op.payload)
            try await repo.replayDelete(id: resolveEntityId(p.id, op: op), idempotencyKey: key)
        default:
            break
        }
    }
}
