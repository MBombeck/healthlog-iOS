import Foundation

// v1.18.6 PHI — labs + illness outbox replay dispatch, split out of
// `OutboxReplayService.swift` to keep the actor body under the
// `type_body_length` budget (the dispatch arms are pure decode→re-issue leaves
// with no actor state beyond the injected repos + decoder). Each re-issues the
// identical request under the persisted idempotency key; an unwired repo
// dead-letters (non-retriable) so the queue can never wedge.

extension OutboxReplayService {
    /// Replay the labs + biomarker writes (server dedups within 24h;
    /// soft-delete is tombstone-idempotent; restore foreign-ids are no-ops).
    func dispatchLabs(_ op: OutboxQueue.Operation) async throws {
        guard let labsRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — labsRepo unwired")
        }
        let key = op.idempotencyKey
        switch op.kind {
        case .createLab:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateLab.self, from: op.payload)
            // audit-v0162 H-4 — capture the server id so a queued update/delete
            // that references the optimistic lab id is remapped on replay.
            lastCreatedServerId = try await labsRepo.replayCreateLabReturningServerId(p.body, idempotencyKey: key)
        case .updateLab:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateLab.self, from: op.payload)
            try await labsRepo.replayUpdateLab(id: resolveEntityId(p.id, op: op), p.patch, idempotencyKey: key)
        case .deleteLab:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteLab.self, from: op.payload)
            try await labsRepo.replayDeleteLab(id: resolveEntityId(p.id, op: op), idempotencyKey: key)
        case .restoreLabs:
            let p = try decoder.decode(OutboxQueue.Payloads.RestoreLabs.self, from: op.payload)
            try await labsRepo.replayRestoreLabs(ids: p.ids, idempotencyKey: key)
        case .createBiomarker:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateBiomarker.self, from: op.payload)
            try await labsRepo.replayCreateBiomarker(p.body, idempotencyKey: key)
        case .updateBiomarker:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateBiomarker.self, from: op.payload)
            try await labsRepo.replayUpdateBiomarker(id: p.id, p.patch, idempotencyKey: key)
        case .deleteBiomarker:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteBiomarker.self, from: op.payload)
            try await labsRepo.replayDeleteBiomarker(id: p.id, idempotencyKey: key)
        default:
            break
        }
    }

    /// Replay the illness episode + day-log writes (soft-delete + restore +
    /// day-log UPSERT are idempotent).
    func dispatchIllness(_ op: OutboxQueue.Operation) async throws {
        guard let illnessRepo else {
            throw HLError.unknown("Op-Kind \(op.kind.rawValue) — illnessRepo unwired")
        }
        let key = op.idempotencyKey
        switch op.kind {
        case .createIllnessEpisode:
            let p = try decoder.decode(OutboxQueue.Payloads.CreateIllnessEpisode.self, from: op.payload)
            try await illnessRepo.replayCreateEpisode(p.body, idempotencyKey: key)
        case .updateIllnessEpisode:
            let p = try decoder.decode(OutboxQueue.Payloads.UpdateIllnessEpisode.self, from: op.payload)
            try await illnessRepo.replayUpdateEpisode(id: p.id, p.patch, idempotencyKey: key)
        case .deleteIllnessEpisode:
            let p = try decoder.decode(OutboxQueue.Payloads.DeleteIllnessEpisode.self, from: op.payload)
            try await illnessRepo.replayDeleteEpisode(id: p.id, idempotencyKey: key)
        case .restoreIllnessEpisode:
            let p = try decoder.decode(OutboxQueue.Payloads.RestoreIllnessEpisode.self, from: op.payload)
            try await illnessRepo.replayRestore(id: p.id, idempotencyKey: key)
        case .resolveIllnessEpisode:
            let p = try decoder.decode(OutboxQueue.Payloads.ResolveIllnessEpisode.self, from: op.payload)
            try await illnessRepo.replayResolveEpisode(id: p.id, resolvedAt: p.resolvedAt, idempotencyKey: key)
        case .upsertIllnessDayLog:
            let p = try decoder.decode(OutboxQueue.Payloads.UpsertIllnessDayLog.self, from: op.payload)
            try await illnessRepo.replayUpsertDayLog(episodeId: p.episodeId, p.body, idempotencyKey: key)
        default:
            break
        }
    }
}
