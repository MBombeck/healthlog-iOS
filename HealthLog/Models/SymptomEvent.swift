import Foundation

// SYMPTOM (1.5.0, #144, server #1237) — the person's own symptom
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

    public init(
        id: String,
        definitionId: String,
        occurredAt: String,
        intensity: Int,
        note: String?,
        episodeId: String?
    ) {
        self.id = id
        self.definitionId = definitionId
        self.occurredAt = occurredAt
        self.intensity = intensity
        self.note = note
        self.episodeId = episodeId
    }

    private enum CodingKeys: String, CodingKey {
        case id, definitionId, occurredAt, intensity, note, episodeId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        definitionId = try c.decodeIfPresent(String.self, forKey: .definitionId) ?? ""
        occurredAt = try c.decodeIfPresent(String.self, forKey: .occurredAt) ?? ""
        intensity = try c.decodeIfPresent(Int.self, forKey: .intensity) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
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

    public init(id: String, label: String?, sortOrder: Int = 0, isActive: Bool = true) {
        self.id = id
        self.label = label
        self.sortOrder = sortOrder
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, sortOrder, isActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

/// `SymptomDefinitionList`: the definitions in display order.
struct SymptomDefinitionList: Decodable, Sendable {
    let definitions: [SymptomDefinition]

    private enum CodingKeys: String, CodingKey {
        case definitions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        definitions = try c.decodeIfPresent([SymptomDefinition].self, forKey: .definitions) ?? []
    }
}
