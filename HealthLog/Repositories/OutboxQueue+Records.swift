import Foundation

// v1.25 PHI — outbox payloads for the structured-records (allergy +
// family-history) durable-write kinds. Mirrors `OutboxQueue+LabsIllness.swift`:
// each shape is `Codable` + `Sendable` and re-issues the identical write on the
// replay path under the persisted idempotency key, so an offline allergy /
// family-history write survives an app restart and replays at reachability. The
// persisted key makes a replay-after-original-landed duplicate-safe (server
// dedups a create within 24h; PATCH is naturally idempotent; the soft-delete is
// tombstone-idempotent).

public extension OutboxQueue.Payloads {
    // MARK: - Allergies

    /// `createAllergy` — `POST /api/allergies`.
    struct CreateAllergy: Codable, Sendable {
        public let body: AllergyCreate
        public init(body: AllergyCreate) {
            self.body = body
        }
    }

    /// `updateAllergy` — `PATCH /api/allergies/{id}` partial edit (tri-state).
    struct UpdateAllergy: Codable, Sendable {
        public let id: String
        public let patch: AllergyPatch
        public init(id: String, patch: AllergyPatch) {
            self.id = id
            self.patch = patch
        }
    }

    /// `deleteAllergy` — `DELETE /api/allergies/{id}` (soft, tombstone-idempotent).
    struct DeleteAllergy: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    // MARK: - Family history

    /// `createFamilyHistory` — `POST /api/family-history`.
    struct CreateFamilyHistory: Codable, Sendable {
        public let body: FamilyHistoryCreate
        public init(body: FamilyHistoryCreate) {
            self.body = body
        }
    }

    /// `updateFamilyHistory` — `PATCH /api/family-history/{id}` (tri-state).
    struct UpdateFamilyHistory: Codable, Sendable {
        public let id: String
        public let patch: FamilyHistoryPatch
        public init(id: String, patch: FamilyHistoryPatch) {
            self.id = id
            self.patch = patch
        }
    }

    /// `deleteFamilyHistory` — `DELETE /api/family-history/{id}` (soft,
    /// tombstone-idempotent).
    struct DeleteFamilyHistory: Codable, Sendable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }
}
