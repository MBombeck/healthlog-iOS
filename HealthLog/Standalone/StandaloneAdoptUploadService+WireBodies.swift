import Foundation

// v0.13 WR — extracted from `StandaloneAdoptUploadService.swift` to keep that
// file under the 600-line cap. These are the bulk wire-body DTOs for the
// adopt-on-pair mood + intake backfill routes (no behaviour change).

// MARK: - Bulk wire bodies (mood + intake backfill)

/// Wire entry for `POST /api/mood-entries/bulk`. `mood` is the server level enum
/// (`SUPER_GUT`…`LAUSIG`); `externalId` carries the local row identity so the
/// upsert dedups idempotently. Mirrors the server `bulkEntrySchema`.
public struct BulkMoodEntryDTO: Codable, Sendable, Equatable {
    public let mood: String
    public let tags: [String]?
    /// v0.14 — structured tag-keys carried into the adopt-on-pair backfill.
    /// **LIVE since server v1.12.0** — the bulk route's `bulkEntrySchema` now
    /// persists `tagKeys` (the earlier "strips the unknown key" gap is closed;
    /// confirmed in `v1.12.0-server-to-ios-LIVE.md`). Emitted only when non-empty
    /// so legacy bodies stay byte-identical; standalone structured tags now
    /// round-trip through the bulk path. (Server `externalId` bulk-upsert dedup
    /// is still pending a LIVE note — don't rely on it for idempotent re-import.)
    public let tagKeys: [String]?
    public let note: String?
    public let moodLoggedAt: Date
    public let source: String
    public let externalId: String

    public init(
        mood: String,
        tags: [String]?,
        tagKeys: [String]? = nil,
        note: String?,
        moodLoggedAt: Date,
        source: String,
        externalId: String
    ) {
        self.mood = mood
        self.tags = tags
        self.tagKeys = tagKeys
        self.note = note
        self.moodLoggedAt = moodLoggedAt
        self.source = source
        self.externalId = externalId
    }

    private enum CodingKeys: String, CodingKey {
        case mood, tags, tagKeys, note, moodLoggedAt, source, externalId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mood, forKey: .mood)
        try c.encodeIfPresent(tags, forKey: .tags)
        if let tagKeys, !tagKeys.isEmpty {
            try c.encode(tagKeys, forKey: .tagKeys)
        }
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(moodLoggedAt, forKey: .moodLoggedAt)
        try c.encode(source, forKey: .source)
        try c.encode(externalId, forKey: .externalId)
    }
}

public struct BulkMoodPayload: Codable, Sendable, Equatable {
    public let entries: [BulkMoodEntryDTO]
    public init(entries: [BulkMoodEntryDTO]) {
        self.entries = entries
    }
}

/// Wire entry for `POST /api/medications/intake/bulk`. `idempotencyKey` carries
/// the local externalId — the server's UNIQUE column on it makes a re-run a
/// no-op. `medicationId` is the SERVER id (post-remap), never the local one.
public struct BulkIntakeEntryDTO: Codable, Sendable, Equatable {
    public let medicationId: String
    public let scheduledFor: Date?
    public let takenAt: Date?
    public let skipped: Bool
    public let idempotencyKey: String
    /// v0.13 WP — server injection-site enum string, carried so an offline
    /// injection's site survives adopt-on-pair upload (server persists it only
    /// on a taken injection entry; otherwise silently dropped — see
    /// `BulkIntakeEntry.injectionSite`).
    public let injectionSite: String?

    public init(
        medicationId: String,
        scheduledFor: Date?,
        takenAt: Date?,
        skipped: Bool,
        idempotencyKey: String,
        injectionSite: String? = nil
    ) {
        self.medicationId = medicationId
        self.scheduledFor = scheduledFor
        self.takenAt = takenAt
        self.skipped = skipped
        self.idempotencyKey = idempotencyKey
        self.injectionSite = injectionSite
    }
}

public struct BulkIntakePayload: Codable, Sendable, Equatable {
    public let entries: [BulkIntakeEntryDTO]
    public init(entries: [BulkIntakeEntryDTO]) {
        self.entries = entries
    }
}

/// Shared response envelope for the mood + intake bulk routes. Both return the
/// same `{ processed, inserted, duplicates, skipped[], entries[] }` shape (the
/// intake route adds `updated`, which is decoded tolerantly via the optional).
/// We only need the aggregate counts for logging; per-entry status drives no
/// cursor here (the externalId/idempotencyKey IS the cursor).
public struct BulkUpsertResponseDTO: Codable, Sendable, Equatable {
    public let processed: Int
    public let inserted: Int
    public let updated: Int?
    public let duplicates: Int

    public init(processed: Int, inserted: Int, updated: Int? = nil, duplicates: Int) {
        self.processed = processed
        self.inserted = inserted
        self.updated = updated
        self.duplicates = duplicates
    }
}
