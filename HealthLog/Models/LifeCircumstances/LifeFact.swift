import Foundation

/// **LIFE (1.5.0, #132)** — the fact kinds the life-circumstances read
/// route serves: the six new object kinds and the two closed string kinds that
/// live in a section (smoking status in tobacco, shift work in work).
///
/// Server-side these six object kinds are deliberately absent from
/// `GET /api/anamnesis/facts`, whose kind list older builds decode closed;
/// they are read here and only here. A kind this build does not know is
/// skipped while decoding (``LifeSection``), never guessed at.
public enum LifeFactKind: String, Codable, Sendable, Hashable, CaseIterable {
    case smokingStatus = "SMOKING_STATUS"
    case shiftSchedule = "SHIFT_SCHEDULE"
    case tobaccoDetail = "TOBACCO_DETAIL"
    case activityHabit = "ACTIVITY_HABIT"
    case workContext = "WORK_CONTEXT"
    case freeWeekdays = "FREE_WEEKDAYS"
    case habits = "HABITS"
    case healthGoals = "HEALTH_GOALS"
}

/// One decoded answer.
///
/// `.unreadable` is the server's `unreadable: true` (the sealed value does not
/// open on this host). `.unsupported` is an answer this build cannot read in
/// full: another schema version, or an option it does not know. Neither is
/// ever shown as an answer, and neither is written over unless the person
/// enters a new answer for that kind themselves (see ``LifeSectionDraft``).
public enum LifeFactValue: Sendable, Hashable {
    case smokingStatus(AnamnesisFactValue)
    case shiftSchedule(AnamnesisFactValue)
    case tobacco(LifeTobaccoDetail)
    case activity(LifeActivityHabit)
    case work(LifeWorkContext)
    case freeWeekdays(LifeFreeWeekdays)
    case habits(LifeHabits)
    case goals(LifeHealthGoals)
    case unreadable
    case unsupported
}

/// The current revision of one life-circumstance fact (`LifeFactRevision`).
public struct LifeFact: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: LifeFactKind
    public let value: LifeFactValue
    public let validFrom: Date
    public let createdAt: Date?

    public init(id: String, kind: LifeFactKind, value: LifeFactValue, validFrom: Date, createdAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.validFrom = validFrom
        self.createdAt = createdAt
    }

    /// `true` while the answer can be shown and edited as an answer.
    public var isReadable: Bool {
        switch value {
        case .unreadable, .unsupported: false
        default: true
        }
    }
}

extension LifeFact: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, value, unreadable, validFrom, createdAt
    }

    /// Throws only for an unknown `kind` (the caller skips the row) or a
    /// missing identity. A value that does not fit its kind decodes as
    /// ``LifeFactValue/unsupported``, so the row stays visible and protected.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(LifeFactKind.self, forKey: .kind)
        validFrom = try c.decode(Date.self, forKey: .validFrom)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        if (try? c.decodeIfPresent(Bool.self, forKey: .unreadable)) == true {
            value = .unreadable
            return
        }
        value = Self.decodeValue(kind: kind, from: c)
    }

    private static func decodeValue(kind: LifeFactKind, from c: KeyedDecodingContainer<CodingKeys>) -> LifeFactValue {
        func object<T: Decodable>(_: T.Type) -> T? {
            try? c.decode(T.self, forKey: .value)
        }
        func closed(_ kind: AnamnesisFactKind) -> AnamnesisFactValue? {
            guard let raw = try? c.decode(String.self, forKey: .value) else { return nil }
            let value = AnamnesisFactValue(rawValue: raw)
            return kind.allows(value) ? value : nil
        }
        let decoded: LifeFactValue? = switch kind {
        case .smokingStatus: closed(.smokingStatus).map(LifeFactValue.smokingStatus)
        case .shiftSchedule: closed(.shiftSchedule).map(LifeFactValue.shiftSchedule)
        case .tobaccoDetail: object(LifeTobaccoDetail.self).map(LifeFactValue.tobacco)
        case .activityHabit: object(LifeActivityHabit.self).map(LifeFactValue.activity)
        case .workContext: object(LifeWorkContext.self).map(LifeFactValue.work)
        case .freeWeekdays: object(LifeFreeWeekdays.self).map(LifeFactValue.freeWeekdays)
        case .habits: object(LifeHabits.self).map(LifeFactValue.habits)
        case .healthGoals: object(LifeHealthGoals.self).map(LifeFactValue.goals)
        }
        return decoded ?? .unsupported
    }
}

/// Skips one array element whose decode failed, so the decoder moves past it.
struct LifeSkippedElement: Decodable {
    init(from _: Decoder) {}
}
