import Foundation

// SYMPTOM (1.5.0, #144) — the write bodies of `/api/symptoms/events` and
// the one rule for linking an occurrence to an illness episode.

/// A field of a partial edit that can also be cleared: `note: null` clears
/// the note, `episodeId: null` drops the link (`UpdateSymptomEventRequest`).
public enum SymptomFieldChange<Value: Sendable & Equatable>: Sendable, Equatable {
    case set(Value)
    case clear
}

/// `PATCH /api/symptoms/events/{id}`: only what changed is sent.
public struct SymptomEventPatch: Encodable, Sendable, Equatable {
    public var occurredAt: String?
    public var intensity: Int?
    public var note: SymptomFieldChange<String>?
    public var episodeId: SymptomFieldChange<String>?

    public init(
        occurredAt: String? = nil,
        intensity: Int? = nil,
        note: SymptomFieldChange<String>? = nil,
        episodeId: SymptomFieldChange<String>? = nil
    ) {
        self.occurredAt = occurredAt
        self.intensity = intensity
        self.note = note
        self.episodeId = episodeId
    }

    public var isEmpty: Bool {
        occurredAt == nil && intensity == nil && note == nil && episodeId == nil
    }

    private enum CodingKeys: String, CodingKey {
        case occurredAt, intensity, note, episodeId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(occurredAt, forKey: .occurredAt)
        try c.encodeIfPresent(intensity, forKey: .intensity)
        try Self.encode(note, forKey: .note, in: &c)
        try Self.encode(episodeId, forKey: .episodeId, in: &c)
    }

    private static func encode(
        _ change: SymptomFieldChange<String>?,
        forKey key: CodingKeys,
        in c: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch change {
        case nil: break
        case .clear: try c.encodeNil(forKey: key)
        case let .set(value): try c.encode(value, forKey: key)
        }
    }

    /// The edit between what the server sent and what the form holds. A note
    /// is trimmed; an empty one clears. The time is compared to the second,
    /// so a time the person did not touch is not sent.
    public static func between(
        _ original: SymptomEvent,
        occurredAt: Date,
        intensity: Int,
        note: String,
        episodeId: String?
    ) -> SymptomEventPatch {
        var patch = SymptomEventPatch()
        let originalDate = original.occurredDate
        if originalDate.map({ abs($0.timeIntervalSince(occurredAt)) >= 1 }) ?? true {
            patch.occurredAt = SymptomEventCreate.wireInstant(occurredAt)
        }
        if intensity != original.intensity {
            patch.intensity = intensity
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = original.note ?? ""
        if trimmed != stored {
            patch.note = trimmed.isEmpty ? .clear : .set(trimmed)
        }
        if episodeId != original.episodeId {
            patch.episodeId = episodeId.map { .set($0) } ?? .clear
        }
        return patch
    }
}

/// `POST /api/symptoms/events`.
public struct SymptomEventCreate: Encodable, Sendable, Equatable {
    public let definitionId: String
    public let occurredAt: String
    public let intensity: Int
    public let note: String?
    public let episodeId: String?

    public init(definitionId: String, occurredAt: Date, intensity: Int, note: String, episodeId: String?) {
        self.definitionId = definitionId
        self.occurredAt = Self.wireInstant(occurredAt)
        self.intensity = intensity
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = trimmed.isEmpty ? nil : trimmed
        self.episodeId = episodeId
    }

    private enum CodingKeys: String, CodingKey {
        case definitionId, occurredAt, intensity, note, episodeId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(definitionId, forKey: .definitionId)
        try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(intensity, forKey: .intensity)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(episodeId, forKey: .episodeId)
    }

    /// The instant as the server's pattern wants it (`…T08:00:00Z`).
    static func wireInstant(_ date: Date) -> String {
        ISO8601DateFormatter.plain.string(from: date)
    }
}

/// The one linking rule, as the server checks it (`isEpisodeLinkableAt`): an
/// occurrence may be filed against an episode that is still open, or against
/// a resolved one whose onset-to-recovery span holds the occurrence's time.
public enum SymptomEpisodeLink {
    public static func isLinkable(_ episode: IllnessEpisodeDTO, at date: Date) -> Bool {
        guard let resolvedRaw = episode.resolvedAt, !resolvedRaw.isEmpty else { return true }
        guard let onset = parse(episode.onsetAt), let resolved = parse(resolvedRaw) else { return false }
        return onset <= date && date <= resolved
    }

    /// The episodes the picker offers for an occurrence at `date`, in the
    /// order given, plus `keep` (the stored link of an edited occurrence: the
    /// server keeps an unchanged link even after its episode resolved).
    public static func options(
        from episodes: [IllnessEpisodeDTO],
        at date: Date,
        keep: String? = nil
    ) -> [IllnessEpisodeDTO] {
        episodes.filter { $0.id == keep || isLinkable($0, at: date) }
    }

    /// The link to send: the choice while it is still offered, else none. A
    /// choice the time has moved away from is dropped, never sent.
    public static func effective(chosen: String?, options: [IllnessEpisodeDTO]) -> String? {
        guard let chosen, options.contains(where: { $0.id == chosen }) else { return nil }
        return chosen
    }

    private static func parse(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }
}
