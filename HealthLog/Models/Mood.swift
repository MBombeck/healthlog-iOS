import Foundation

/// Server-Enum (siehe `prisma/schema.prisma` `MoodLevel`).
public enum ServerMoodLevel: String, Codable, Sendable, CaseIterable {
    case lousy = "LAUSIG" // score 1
    case bad = "SCHLECHT" // score 2
    case okay = "OKAY" // score 3
    case good = "GUT" // score 4
    case great = "SUPER_GUT" // score 5

    public init(score: Int) {
        switch max(1, min(5, score)) {
        case 1: self = .lousy
        case 2: self = .bad
        case 3: self = .okay
        case 4: self = .good
        default: self = .great
        }
    }

    public var score: Int {
        switch self {
        case .lousy: 1
        case .bad: 2
        case .okay: 3
        case .good: 4
        case .great: 5
        }
    }
}

public struct MoodEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let mood: ServerMoodLevel
    public let tags: [String]
    /// v0.14 — structured mood-tag keys (server v1.8.5 `MoodEntryTagLink`).
    /// Stable catalog keys (`happy`, `worked_out`) the Daylio-style picker
    /// emits; sent on `POST`/`PUT` and round-tripped on read. Coexists with
    /// the free-text `tags` axis (the server folds both into aggregates).
    public let tagKeys: [String]
    public let moodLoggedAt: Date
    public let source: String?
    /// Direkter Note-Slot — Server v1.4.30 ships `MoodEntry.note` als
    /// dedizierte Spalte. iOS sendet `note` direkt im Body (single-write,
    /// kein Dual-Write `tags["note:..."]` mehr).
    public let note: String?
    /// v0.14.7 — RATED factors with their per-entry score, read back from the
    /// server (`GET`/`PUT`/`POST` response serializes `ratedFactors:
    /// [{ key, rating }]`, server v1.12.0 — `route.ts` `entriesWithParsedTags`).
    /// The capture flow PUTs these via ``MoodEntryPatch/ratedFactors``; this is
    /// the read side so the history readback can render the saved rating and the
    /// edit panel can pre-fill the sliders. Defaults to `[]` so older cached
    /// responses / pre-v2 servers decode unchanged.
    public let ratedFactors: [RatedFactorOutput]

    public init(id: String, recordedAt: Date, score: Int, tags: [String] = [], tagKeys: [String] = [], note: String? = nil) {
        self.id = id
        mood = ServerMoodLevel(score: score)
        // Defensive: falls Aufrufer noch alten Tag-Hack mitschickt, hier
        // einmalig migrieren — Notiz extrahieren, Tag entfernen.
        let cleaned = tags.filter { !$0.hasPrefix("note:") }
        let legacyNote = tags.first(where: { $0.hasPrefix("note:") })?
            .replacingOccurrences(of: "note:", with: "")
        self.tags = cleaned
        self.tagKeys = tagKeys
        self.note = note ?? legacyNote
        ratedFactors = []
        moodLoggedAt = recordedAt
        source = "MANUAL"
    }

    public init(
        id: String,
        mood: ServerMoodLevel,
        tags: [String],
        tagKeys: [String] = [],
        moodLoggedAt: Date,
        source: String? = nil,
        note: String? = nil,
        ratedFactors: [RatedFactorOutput] = []
    ) {
        self.id = id
        self.mood = mood
        // Backfill-safety: alte Server-Antworten könnten noch Tag-Notizen
        // liefern, bis das Migrations-Script v1.4.30 alle Bestände
        // konvertiert hat. Wir filtern client-side defensiv.
        let cleaned = tags.filter { !$0.hasPrefix("note:") }
        let legacyNote = tags.first(where: { $0.hasPrefix("note:") })?
            .replacingOccurrences(of: "note:", with: "")
        self.tags = cleaned
        self.tagKeys = tagKeys
        self.note = note ?? legacyNote
        self.ratedFactors = ratedFactors
        self.moodLoggedAt = moodLoggedAt
        self.source = source
    }

    /// Convenience-Properties für UI-Code, der das alte score-Schema kennt.
    public var score: Int {
        mood.score
    }

    public var recordedAt: Date {
        moodLoggedAt
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, mood, tags, tagKeys, moodLoggedAt, source, note, ratedFactors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mood = try c.decode(ServerMoodLevel.self, forKey: .mood)
        let rawTags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        tags = rawTags.filter { !$0.hasPrefix("note:") }
        // `tagKeys` is a v1.8.5 addition — tolerate older cached responses /
        // servers that omit it by defaulting to an empty set.
        tagKeys = try c.decodeIfPresent([String].self, forKey: .tagKeys) ?? []
        moodLoggedAt = try c.decode(Date.self, forKey: .moodLoggedAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        let directNote = try c.decodeIfPresent(String.self, forKey: .note)
        let legacyNote = rawTags.first(where: { $0.hasPrefix("note:") })?
            .replacingOccurrences(of: "note:", with: "")
        note = directNote ?? legacyNote
        // `ratedFactors` is a v1.12.0 read-side addition — tolerate older cached
        // responses / pre-v2 servers that omit it by defaulting to an empty set.
        ratedFactors = try c.decodeIfPresent([RatedFactorOutput].self, forKey: .ratedFactors) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mood, forKey: .mood)
        try c.encode(tags, forKey: .tags)
        // Only emit `tagKeys` when present — an empty array is a no-op on the
        // server create schema (optional) and keeps legacy bodies lean.
        if !tagKeys.isEmpty {
            try c.encode(tagKeys, forKey: .tagKeys)
        }
        try c.encode(moodLoggedAt, forKey: .moodLoggedAt)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(note, forKey: .note)
        // Round-trip the read-back rated factors only when present (empty is a
        // no-op; the write path uses `MoodEntryPatch.ratedFactors` instead).
        if !ratedFactors.isEmpty {
            try c.encode(ratedFactors, forKey: .ratedFactors)
        }
    }
}

/// Read-side rated-factor element: the server `GET`/`PUT`/`POST` response
/// serializes each RATED tag link as `{ key, rating }` (server v1.12.0 —
/// `route.ts` `entriesWithParsedTags`). Mirrors the write-side
/// ``RatedFactorInput`` shape. `rating` is the literal raw score within the
/// factor's own `scaleMin…scaleMax`; the inverse-aware good/bad framing is
/// resolved at render time against the catalog (``MoodTagDTO/inverse``).
public struct RatedFactorOutput: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let key: String
    public let rating: Int
    public var id: String {
        key
    }

    public init(key: String, rating: Int) {
        self.key = key
        self.rating = rating
    }
}

/// Update body for `PUT /api/mood-entries/[id]`. All fields optional —
/// server applies only the keys that are present (partial-update PUT). Ab v1.4.30 ist `note`
/// ein dediziertes Feld; ältere Builds schrieben es als `tags["note:..."]`.
/// One rated-factor score on a mood write (server v1.12.0 Mood v2). Sent in the
/// `ratedFactors` array on `POST /api/mood-entries` (+ the bulk route). `rating`
/// is an integer within the factor's own `scaleMin…scaleMax` (clamp client-side
/// to avoid the server's `mood.ratedFactor.out_of_range` 422 — contract §3).
public struct RatedFactorInput: Codable, Sendable, Equatable {
    public let key: String
    public let rating: Int
    public init(key: String, rating: Int) {
        self.key = key
        self.rating = rating
    }
}

public struct MoodEntryPatch: Codable, Sendable {
    public let mood: ServerMoodLevel?
    public let tags: [String]?
    /// v0.14 — structured tag-keys on edit. The server update schema accepts
    /// `tagKeys` nullable+optional; we only send the key when the caller
    /// passes a non-nil value so an unrelated edit (e.g. note-only) doesn't
    /// clobber the existing tag-links.
    public let tagKeys: [String]?
    /// v0.14.1 — Mood v2 rated factors (work / social / sleep / stress /
    /// conflict). Parallel to `tagKeys`; omitted entirely when nil/empty so an
    /// unrelated edit doesn't touch the rated links.
    public let ratedFactors: [RatedFactorInput]?
    public let moodLoggedAt: Date?
    public let note: String?
    public init(
        score: Int? = nil,
        tags: [String]? = nil,
        tagKeys: [String]? = nil,
        ratedFactors: [RatedFactorInput]? = nil,
        recordedAt: Date? = nil,
        note: String? = nil
    ) {
        mood = score.map { ServerMoodLevel(score: $0) }
        self.tags = tags
        self.tagKeys = tagKeys
        self.ratedFactors = ratedFactors
        moodLoggedAt = recordedAt
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case mood, tags, tagKeys, ratedFactors, moodLoggedAt, note
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(mood, forKey: .mood)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(tagKeys, forKey: .tagKeys)
        // Omit an empty rated-factors array — a no-op write, and the server
        // treats absent vs `[]` identically.
        if let ratedFactors, !ratedFactors.isEmpty {
            try c.encode(ratedFactors, forKey: .ratedFactors)
        }
        try c.encodeIfPresent(moodLoggedAt, forKey: .moodLoggedAt)
        try c.encodeIfPresent(note, forKey: .note)
    }
}
