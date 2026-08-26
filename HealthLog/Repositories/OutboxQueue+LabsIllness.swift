import Foundation

// v1.18.6 PHI — outbox payloads for the labs + illness durable-write kinds.
// Split out of `OutboxQueue.swift` (file_length + type_body_length discipline).
// Each shape is `Codable` + `Sendable` and re-issues the identical write on the
// replay path under the persisted idempotency key, so an offline lab / biomarker
// / illness write survives an app restart and replays at reachability — exactly
// like the measurement / medication / cycle kinds. Idempotency notes per shape.

public extension OutboxQueue.Payloads {
    // MARK: - Labs

    /// `createLab` — `POST /api/labs`. The server dedups within 24h on the
    /// persisted key; a replay after the original landed is a no-op.
    struct CreateLab: Codable, Sendable {
        public let body: LabResultCreate
        public init(body: LabResultCreate) {
            self.body = body
        }
    }

    /// `updateLab` — `PUT /api/labs/{id}` partial edit.
    struct UpdateLab: Codable, Sendable {
        public let id: String
        public let patch: LabResultPatch
        public init(id: String, patch: LabResultPatch) {
            self.id = id
            self.patch = patch
        }
    }

    /// `deleteLab` — `DELETE /api/labs/{id}` (soft, tombstone-idempotent).
    struct DeleteLab: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    /// `restoreLabs` — `POST /api/labs/restore` `{ ids }`. Foreign/live ids are
    /// silent server-side no-ops, so a replay is harmless.
    struct RestoreLabs: Codable, Sendable {
        public let ids: [String]
        public init(ids: [String]) {
            self.ids = ids
        }
    }

    /// `createBiomarker` — `POST /api/biomarkers`.
    struct CreateBiomarker: Codable, Sendable {
        public let body: BiomarkerCreate
        public init(body: BiomarkerCreate) {
            self.body = body
        }
    }

    /// `updateBiomarker` — `PUT /api/biomarkers/{id}`.
    struct UpdateBiomarker: Codable, Sendable {
        public let id: String
        public let patch: BiomarkerPatch
        public init(id: String, patch: BiomarkerPatch) {
            self.id = id
            self.patch = patch
        }
    }

    /// `deleteBiomarker` — `DELETE /api/biomarkers/{id}` (idempotent).
    struct DeleteBiomarker: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    // MARK: - Illness

    /// `createIllnessEpisode` — `POST /api/illness/episodes`.
    struct CreateIllnessEpisode: Codable, Sendable {
        public let body: IllnessEpisodeCreate
        public init(body: IllnessEpisodeCreate) {
            self.body = body
        }
    }

    /// `updateIllnessEpisode` — `PATCH /api/illness/episodes/{id}`.
    struct UpdateIllnessEpisode: Codable, Sendable {
        public let id: String
        public let patch: IllnessEpisodePatch
        public init(id: String, patch: IllnessEpisodePatch) {
            self.id = id
            self.patch = patch
        }
    }

    /// `deleteIllnessEpisode` — `DELETE /api/illness/episodes/{id}` (soft,
    /// tombstone-idempotent).
    struct DeleteIllnessEpisode: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    /// `restoreIllnessEpisode` — `POST /api/illness/episodes/{id}/restore`
    /// (flag flip; restoring a live episode is a no-op).
    struct RestoreIllnessEpisode: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    /// `resolveIllnessEpisode` — `PATCH /api/illness/episodes/{id}/resolve`.
    struct ResolveIllnessEpisode: Codable, Sendable {
        public let id: String
        public let resolvedAt: String?
        public init(id: String, resolvedAt: String?) {
            self.id = id
            self.resolvedAt = resolvedAt
        }
    }

    /// `upsertIllnessDayLog` — `POST /api/illness/episodes/{id}/day-logs`
    /// (UPSERT on `(episodeId, date)`; a replay last-writer-wins).
    struct UpsertIllnessDayLog: Codable, Sendable {
        public let episodeId: String
        public let body: IllnessDayLogUpsert
        public init(episodeId: String, body: IllnessDayLogUpsert) {
            self.episodeId = episodeId
            self.body = body
        }
    }
}
