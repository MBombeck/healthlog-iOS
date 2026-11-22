import Foundation

// The person's own symptom
// occurrences (`/api/symptoms/events`) and the symptoms they defined
// (`/api/symptoms/definitions`), as OpenAPI v1.47.0 describes them
// (`SymptomEvent`, `SymptomEventList`, `SymptomDefinition`).
//
// An occurrence belongs to an illness episode only through `episodeId`
// (server v1.43.4). The time span of an episode decides which episodes may be
// linked, never which occurrences are shown on it.
//
// Tolerant decode like the illness DTOs: a missing field takes a neutral
// value, so one odd row never sinks the whole list.

/// One occurrence of a defined symptom: when, how strong (0 to 10), the
/// decrypted note, and the episode it is filed against (`nil` for none).
public struct SymptomEvent: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let definitionId: String
    /// ISO-8601 instant.
    public let occurredAt: String
    public let intensity: Int
    public let note: String?
    public let episodeId: String?
    /// #191 (server 1.49.0, key `day.dose-offset`) — the occurrence's
    /// distance to the day's nearest dose, as the day view words it. `nil`
    /// on an older server, without a timed dose that day, with the
    /// medications module off or a grant that does not reach it, and on the
    /// single read and the write answers. Never recomputed here.
    public let doseOffset: DayDoseOffset?

    public init(
        id: String,
        definitionId: String,
        occurredAt: String,
        intensity: Int,
        note: String?,
        episodeId: String?,
        doseOffset: DayDoseOffset? = nil
    ) {
        self.id = id
        self.definitionId = definitionId
        self.occurredAt = occurredAt
        self.intensity = intensity
        self.note = note
        self.episodeId = episodeId
        self.doseOffset = doseOffset
    }

    private enum CodingKeys: String, CodingKey {
        case id, definitionId, occurredAt, intensity, note, episodeId, doseOffset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        definitionId = try c.decodeIfPresent(String.self, forKey: .definitionId) ?? ""
        occurredAt = try c.decodeIfPresent(String.self, forKey: .occurredAt) ?? ""
        intensity = try c.decodeIfPresent(Int.self, forKey: .intensity) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        // Optional everywhere: an unreadable offset costs the offset, never the row.
        doseOffset = try? c.decodeIfPresent(DayDoseOffset.self, forKey: .doseOffset)
    }

    /// The instant, or `nil` when the server sent something unreadable.
    public var occurredDate: Date? {
        ISO8601DateFormatter.fractional.date(from: occurredAt) ?? ISO8601DateFormatter.plain.date(from: occurredAt)
    }

    /// The intensity scale the server accepts.
    public static let intensityRange: ClosedRange<Int> = 0 ... 10
}

/// A page of occurrences, newest first (`SymptomEventList`). `hasMore` is true
/// exactly when an occurrence past this page exists.
public struct SymptomEventPage: Decodable, Sendable, Equatable {
    public let events: [SymptomEvent]
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case events, hasMore
    }

    public init(events: [SymptomEvent], hasMore: Bool) {
        self.events = events
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([SymptomEvent].self, forKey: .events) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// A symptom the person defined. `label` is user data (decrypted on the
/// server, `nil` only on an unreadable value) and is shown verbatim.
public struct SymptomDefinition: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let label: String?
    public let sortOrder: Int
    public let isActive: Bool
    /// How the person used the symptom lately (`recent`, server v1.40): the
    /// count over 30 days and the last occurrence. `nil` when the server
    /// sends none; the symptom then sorts with the unused ones.
    public let recent: SymptomRecentUse?

    public init(
        id: String,
        label: String?,
        sortOrder: Int = 0,
        isActive: Bool = true,
        recent: SymptomRecentUse? = nil
    ) {
        self.id = id
        self.label = label
        self.sortOrder = sortOrder
        self.isActive = isActive
        self.recent = recent
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, sortOrder, isActive, recent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        // An odd summary costs the summary, never the symptom.
        recent = try? c.decodeIfPresent(SymptomRecentUse.self, forKey: .recent)
    }
}

/// The 30-day summary the server keeps per symptom (`SymptomRecentSummary`):
/// how often it was logged in the last 30 days and when it was last felt at
/// all. The server's figures, never recounted here.
public struct SymptomRecentUse: Decodable, Sendable, Equatable, Hashable {
    public let count30d: Int
    /// ISO-8601 instant of the last occurrence over all time, `nil` for never.
    public let lastOccurredAt: String?

    public init(count30d: Int, lastOccurredAt: String?) {
        self.count30d = count30d
        self.lastOccurredAt = lastOccurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case count30d, lastOccurredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count30d = (try? c.decodeIfPresent(Int.self, forKey: .count30d)) ?? 0
        lastOccurredAt = try? c.decodeIfPresent(String.self, forKey: .lastOccurredAt)
    }

    /// The last occurrence as an instant, `nil` for never or unreadable.
    public var lastOccurredDate: Date? {
        guard let lastOccurredAt else { return nil }
        return ISO8601DateFormatter.fractional.date(from: lastOccurredAt) ?? ISO8601DateFormatter.plain.date(from: lastOccurredAt)
    }
}

/// `SymptomDefinitionList`: the definitions in display order, and how many
/// active ones of the person's own the server admits (`limit`).
struct SymptomDefinitionList: Decodable, Sendable {
    let definitions: [SymptomDefinition]
    /// Server 1.48.4 answers 30. An older server sends no `limit` and
    /// admitted 8, so a missing or unreadable value is 8, never a number
    /// written into a screen (#187).
    let limit: Int

    /// The limit of every server before 1.48.4.
    static let legacyLimit = 8

    private enum CodingKeys: String, CodingKey {
        case definitions, limit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        definitions = try c.decodeIfPresent([SymptomDefinition].self, forKey: .definitions) ?? []
        let sent = try? c.decodeIfPresent(Int.self, forKey: .limit)
        limit = sent.flatMap { $0 > 0 ? $0 : nil } ?? Self.legacyLimit
    }
}
