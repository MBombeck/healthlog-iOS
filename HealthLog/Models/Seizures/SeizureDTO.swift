import Foundation

// The seizure diary (server v1.48.0, #1368, #182 A4): `GET /api/seizures`
// and its writes. Shapes from `docs/api/openapi.yaml` (`SeizureDiary`,
// `SeizureType`, `SeizureEvent`, `SeizureRescueDose`, `SeizureSettings`,
// `SeizureDiarySummary`). Instants stay ISO strings like the other record
// surfaces; every field decodes tolerantly, so a field added later or a value
// this build does not know never costs the diary. The summary is the
// server's: the app renders it and never recounts.

/// When the quick-log timer shows the type's plan (`SeizureAlertThreshold`).
public struct SeizureAlertThreshold: Codable, Sendable, Equatable, Hashable {
    public enum Source: String, Codable, Sendable, Equatable, Hashable, TolerantServerEnum {
        /// Trinka 2015 t1 for the type.
        case t1
        /// NICE NG217: the usual duration plus two minutes.
        case usualPlusTwo
        /// Five minutes (CDC first aid).
        case generic
        case unrecognized = "__UNRECOGNIZED__"

        public static let unknownFallback = Source.unrecognized
        public static let wireVocabulary: StaticString = "seizure alert source"
    }

    public let seconds: Int
    public let source: Source

    /// The generic threshold the server uses where a type names none.
    public static let generic = SeizureAlertThreshold(seconds: 300, source: .generic)

    public init(seconds: Int, source: Source) {
        self.seconds = seconds
        self.source = source
    }
}

/// One of the person's seizure types (`SeizureType`). The plan text and the
/// rescue medication are edited on the web; the app shows them.
public struct SeizureTypeDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    /// The family's own name; `nil` when the stored label cannot be read.
    public let label: String?
    public let ilaeType: SeizureIlaeType
    public let usualDurationSec: Int?
    public let rescuePlan: String?
    public let rescueMedicationId: String?
    public let rescueMedicationName: String?
    public let rescueDoseAmount: Double?
    public let rescueDoseUnit: String?
    public let rescueRoute: SeizureRescueRoute?
    public let sortOrder: Int
    public let archived: Bool
    public let alert: SeizureAlertThreshold

    public init(
        id: String,
        label: String?,
        ilaeType: SeizureIlaeType,
        usualDurationSec: Int? = nil,
        rescuePlan: String? = nil,
        rescueMedicationId: String? = nil,
        rescueMedicationName: String? = nil,
        rescueDoseAmount: Double? = nil,
        rescueDoseUnit: String? = nil,
        rescueRoute: SeizureRescueRoute? = nil,
        sortOrder: Int = 0,
        archived: Bool = false,
        alert: SeizureAlertThreshold = .generic
    ) {
        self.id = id
        self.label = label
        self.ilaeType = ilaeType
        self.usualDurationSec = usualDurationSec
        self.rescuePlan = rescuePlan
        self.rescueMedicationId = rescueMedicationId
        self.rescueMedicationName = rescueMedicationName
        self.rescueDoseAmount = rescueDoseAmount
        self.rescueDoseUnit = rescueDoseUnit
        self.rescueRoute = rescueRoute
        self.sortOrder = sortOrder
        self.archived = archived
        self.alert = alert
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        ilaeType = (try? c.decodeIfPresent(SeizureIlaeType.self, forKey: .ilaeType)) ?? .unrecognized
        usualDurationSec = try? c.decodeIfPresent(Int.self, forKey: .usualDurationSec)
        rescuePlan = try? c.decodeIfPresent(String.self, forKey: .rescuePlan)
        rescueMedicationId = try? c.decodeIfPresent(String.self, forKey: .rescueMedicationId)
        rescueMedicationName = try? c.decodeIfPresent(String.self, forKey: .rescueMedicationName)
        rescueDoseAmount = try? c.decodeIfPresent(Double.self, forKey: .rescueDoseAmount)
        rescueDoseUnit = try? c.decodeIfPresent(String.self, forKey: .rescueDoseUnit)
        rescueRoute = try? c.decodeIfPresent(SeizureRescueRoute.self, forKey: .rescueRoute)
        sortOrder = (try? c.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? 0
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        alert = (try? c.decodeIfPresent(SeizureAlertThreshold.self, forKey: .alert)) ?? .generic
    }

    /// The name the diary shows: the family's own, else the ILAE name.
    public var displayName: String {
        let own = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? ilaeType.label : own
    }

    /// The plan has a drug the quick log can stamp.
    public var hasRescueMedication: Bool {
        rescueMedicationId != nil || !(rescueMedicationName ?? "").isEmpty
    }

    /// The plan text agreed with the care team, `nil` when none is saved.
    public var plan: String? {
        let text = rescuePlan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

/// A rescue dose (`SeizureRescueDose`).
public struct SeizureRescueDoseDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let eventId: String
    public let medicationId: String?
    public let medicationName: String
    public let doseAmount: Double?
    public let doseUnit: String?
    public let route: SeizureRescueRoute?
    public let givenAt: String
    public let givenBy: SeizureObserverRole?
    public let effect: SeizureRescueEffect
    public let seizureEndedAt: String?
    /// The intake written on the medication, while it exists.
    public let intakeEventId: String?

    public init(
        id: String,
        eventId: String,
        medicationId: String? = nil,
        medicationName: String,
        doseAmount: Double? = nil,
        doseUnit: String? = nil,
        route: SeizureRescueRoute? = nil,
        givenAt: String,
        givenBy: SeizureObserverRole? = nil,
        effect: SeizureRescueEffect = .unknown,
        seizureEndedAt: String? = nil,
        intakeEventId: String? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.medicationId = medicationId
        self.medicationName = medicationName
        self.doseAmount = doseAmount
        self.doseUnit = doseUnit
        self.route = route
        self.givenAt = givenAt
        self.givenBy = givenBy
        self.effect = effect
        self.seizureEndedAt = seizureEndedAt
        self.intakeEventId = intakeEventId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventId = (try? c.decodeIfPresent(String.self, forKey: .eventId)) ?? ""
        medicationId = try? c.decodeIfPresent(String.self, forKey: .medicationId)
        medicationName = (try? c.decodeIfPresent(String.self, forKey: .medicationName)) ?? ""
        doseAmount = try? c.decodeIfPresent(Double.self, forKey: .doseAmount)
        doseUnit = try? c.decodeIfPresent(String.self, forKey: .doseUnit)
        route = try? c.decodeIfPresent(SeizureRescueRoute.self, forKey: .route)
        givenAt = (try? c.decodeIfPresent(String.self, forKey: .givenAt)) ?? ""
        givenBy = try? c.decodeIfPresent(SeizureObserverRole.self, forKey: .givenBy)
        effect = (try? c.decodeIfPresent(SeizureRescueEffect.self, forKey: .effect)) ?? .unknown
        seizureEndedAt = try? c.decodeIfPresent(String.self, forKey: .seizureEndedAt)
        intakeEventId = try? c.decodeIfPresent(String.self, forKey: .intakeEventId)
    }
}

/// One recorded seizure, or a tally of brief ones (`SeizureEvent`).
public struct SeizureEventDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public struct Flags: Codable, Sendable, Equatable, Hashable {
        /// The duration reached Trinka's t1 for the type; `nil` where an input is missing.
        public let overT1: Bool?
        /// Two minutes past the type's usual duration (NICE); `nil` where an input is missing.
        public let prolonged: Bool?

        public init(overT1: Bool? = nil, prolonged: Bool? = nil) {
            self.overT1 = overT1
            self.prolonged = prolonged
        }
    }

    public enum LoggedBy: String, Codable, Sendable, Equatable, Hashable, TolerantServerEnum {
        case owner, delegate, unknown
        public static let unknownFallback = LoggedBy.unknown
        public static let wireVocabulary: StaticString = "seizure loggedBy"
    }

    public let id: String
    public let typeProfileId: String?
    public let ilaeType: SeizureIlaeType?
    public let effectiveIlaeType: SeizureIlaeType?
    public let onsetAt: String
    public let onsetPrecision: SeizureOnsetPrecision
    public let durationSec: Int?
    public let durationSource: SeizureDurationSource
    public let count: Int
    public let certainty: SeizureCertainty
    public let sleepState: SeizureSleepState
    public let semiology: [SeizureSemiology]
    public let semiologyNote: String?
    public let aura: String?
    public let triggers: [SeizureTrigger]
    public let postictalMinutes: Int?
    public let postictal: [SeizurePostictal]
    public let injuries: [SeizureInjury]
    public let incontinence: Bool?
    public let emergency: SeizureEmergency
    public let witnessed: Bool?
    public let witnessRole: SeizureObserverRole?
    public let witnessNote: String?
    public let loggedBy: LoggedBy
    public let loggedByViewer: Bool
    public let loggedByName: String?
    public let note: String?
    public let rescueDoses: [SeizureRescueDoseDTO]
    public let flags: Flags
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        typeProfileId: String? = nil,
        ilaeType: SeizureIlaeType? = nil,
        effectiveIlaeType: SeizureIlaeType? = nil,
        onsetAt: String,
        onsetPrecision: SeizureOnsetPrecision = .exact,
        durationSec: Int? = nil,
        durationSource: SeizureDurationSource = .unknown,
        count: Int = 1,
        certainty: SeizureCertainty = .confirmed,
        sleepState: SeizureSleepState = .unknown,
        semiology: [SeizureSemiology] = [],
        semiologyNote: String? = nil,
        aura: String? = nil,
        triggers: [SeizureTrigger] = [],
        postictalMinutes: Int? = nil,
        postictal: [SeizurePostictal] = [],
        injuries: [SeizureInjury] = [],
        incontinence: Bool? = nil,
        emergency: SeizureEmergency = .noneNoted,
        witnessed: Bool? = nil,
        witnessRole: SeizureObserverRole? = nil,
        witnessNote: String? = nil,
        loggedBy: LoggedBy = .owner,
        loggedByViewer: Bool = true,
        loggedByName: String? = nil,
        note: String? = nil,
        rescueDoses: [SeizureRescueDoseDTO] = [],
        flags: Flags = Flags(),
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.typeProfileId = typeProfileId
        self.ilaeType = ilaeType
        self.effectiveIlaeType = effectiveIlaeType
        self.onsetAt = onsetAt
        self.onsetPrecision = onsetPrecision
        self.durationSec = durationSec
        self.durationSource = durationSource
        self.count = count
        self.certainty = certainty
        self.sleepState = sleepState
        self.semiology = semiology
        self.semiologyNote = semiologyNote
        self.aura = aura
        self.triggers = triggers
        self.postictalMinutes = postictalMinutes
        self.postictal = postictal
        self.injuries = injuries
        self.incontinence = incontinence
        self.emergency = emergency
        self.witnessed = witnessed
        self.witnessRole = witnessRole
        self.witnessNote = witnessNote
        self.loggedBy = loggedBy
        self.loggedByViewer = loggedByViewer
        self.loggedByName = loggedByName
        self.note = note
        self.rescueDoses = rescueDoses
        self.flags = flags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        typeProfileId = try? c.decodeIfPresent(String.self, forKey: .typeProfileId)
        ilaeType = try? c.decodeIfPresent(SeizureIlaeType.self, forKey: .ilaeType)
        effectiveIlaeType = try? c.decodeIfPresent(SeizureIlaeType.self, forKey: .effectiveIlaeType)
        onsetAt = try c.decode(String.self, forKey: .onsetAt)
        onsetPrecision = (try? c.decodeIfPresent(SeizureOnsetPrecision.self, forKey: .onsetPrecision)) ?? .exact
        durationSec = try? c.decodeIfPresent(Int.self, forKey: .durationSec)
        durationSource = (try? c.decodeIfPresent(SeizureDurationSource.self, forKey: .durationSource)) ?? .unknown
        count = max(1, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 1)
        certainty = (try? c.decodeIfPresent(SeizureCertainty.self, forKey: .certainty)) ?? .confirmed
        sleepState = (try? c.decodeIfPresent(SeizureSleepState.self, forKey: .sleepState)) ?? .unknown
        semiology = Self.list(c, .semiology)
        semiologyNote = try? c.decodeIfPresent(String.self, forKey: .semiologyNote)
        aura = try? c.decodeIfPresent(String.self, forKey: .aura)
        triggers = Self.list(c, .triggers)
        postictalMinutes = try? c.decodeIfPresent(Int.self, forKey: .postictalMinutes)
        postictal = Self.list(c, .postictal)
        injuries = Self.list(c, .injuries)
        incontinence = try? c.decodeIfPresent(Bool.self, forKey: .incontinence)
        emergency = (try? c.decodeIfPresent(SeizureEmergency.self, forKey: .emergency)) ?? .noneNoted
        witnessed = try? c.decodeIfPresent(Bool.self, forKey: .witnessed)
        witnessRole = try? c.decodeIfPresent(SeizureObserverRole.self, forKey: .witnessRole)
        witnessNote = try? c.decodeIfPresent(String.self, forKey: .witnessNote)
        loggedBy = (try? c.decodeIfPresent(LoggedBy.self, forKey: .loggedBy)) ?? .unknown
        loggedByViewer = (try? c.decodeIfPresent(Bool.self, forKey: .loggedByViewer)) ?? false
        loggedByName = try? c.decodeIfPresent(String.self, forKey: .loggedByName)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        rescueDoses = ((try? c.decodeIfPresent([SeizureLossy<SeizureRescueDoseDTO>].self, forKey: .rescueDoses)) ?? [])
            .compactMap(\.value)
        flags = (try? c.decodeIfPresent(Flags.self, forKey: .flags)) ?? Flags()
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
    }

    /// A list of vocabulary words; a word this build does not know is left out.
    private static func list<Value: TolerantServerEnum & Equatable>(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [Value] {
        ((try? c.decodeIfPresent([Value].self, forKey: key)) ?? []).filter { $0 != Value.unknownFallback }
    }

    private enum CodingKeys: String, CodingKey {
        case id, typeProfileId, ilaeType, effectiveIlaeType, onsetAt, onsetPrecision, durationSec, durationSource
        case count, certainty, sleepState, semiology, semiologyNote, aura, triggers, postictalMinutes, postictal
        case injuries, incontinence, emergency, witnessed, witnessRole, witnessNote, loggedBy, loggedByViewer
        case loggedByName, note, rescueDoses, flags, createdAt, updatedAt
    }

    /// The onset as an instant, `nil` for a malformed string.
    public var onsetDate: Date? {
        SeizureDateFormat.parse(onsetAt)
    }
}

/// `{ count, windowHours }` (`SeizureClusterRule`).
public struct SeizureClusterRule: Codable, Sendable, Equatable, Hashable {
    public let count: Int
    public let windowHours: Int

    /// The record's rule until one is saved: 2 in 24 hours.
    public static let standard = SeizureClusterRule(count: 2, windowHours: 24)
    /// NICE NG217's 3 in 24 hours, shown beside the record's own rule.
    public static let nice = SeizureClusterRule(count: 3, windowHours: 24)
    /// The server's bounds for a saved rule.
    public static let countRange = 2 ... 20
    public static let windowRange = 1 ... 168

    public init(count: Int, windowHours: Int) {
        self.count = count
        self.windowHours = windowHours
    }
}

/// `{ rule, niceRule }` (`SeizureSettings`), also the answer of the PATCH.
public struct SeizureSettingsDTO: Codable, Sendable, Equatable, Hashable {
    public let rule: SeizureClusterRule
    public let niceRule: SeizureClusterRule

    public init(rule: SeizureClusterRule = .standard, niceRule: SeizureClusterRule = .nice) {
        self.rule = rule
        self.niceRule = niceRule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rule = (try? c.decodeIfPresent(SeizureClusterRule.self, forKey: .rule)) ?? .standard
        niceRule = (try? c.decodeIfPresent(SeizureClusterRule.self, forKey: .niceRule)) ?? .nice
    }
}

/// The server-derived summary of the period (`SeizureDiarySummary`). Only
/// the counts the diary page shows; rendered as sent.
public struct SeizureDiarySummaryDTO: Codable, Sendable, Equatable, Hashable {
    public struct Streak: Codable, Sendable, Equatable, Hashable {
        public let daysSinceLast: Int?
        public let lastAt: String?
        public let longestFreeDays: Int

        public init(daysSinceLast: Int? = nil, lastAt: String? = nil, longestFreeDays: Int = 0) {
            self.daysSinceLast = daysSinceLast
            self.lastAt = lastAt
            self.longestFreeDays = longestFreeDays
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            daysSinceLast = try? c.decodeIfPresent(Int.self, forKey: .daysSinceLast)
            lastAt = try? c.decodeIfPresent(String.self, forKey: .lastAt)
            longestFreeDays = (try? c.decodeIfPresent(Int.self, forKey: .longestFreeDays)) ?? 0
        }
    }

    public struct Cluster: Codable, Sendable, Equatable, Hashable {
        public let startAt: String
        public let endAt: String
        public let seizureCount: Int
        public let eventIds: [String]

        public init(startAt: String, endAt: String, seizureCount: Int, eventIds: [String]) {
            self.startAt = startAt
            self.endAt = endAt
            self.seizureCount = seizureCount
            self.eventIds = eventIds
        }
    }

    public let from: String
    public let days: Int
    public let seizures: Int
    public let suspected: Int
    public let seizureDays: Int
    public let streak: Streak
    public let clusters: [Cluster]
    public let niceClusterCount: Int

    public init(
        from: String = "",
        days: Int = 90,
        seizures: Int = 0,
        suspected: Int = 0,
        seizureDays: Int = 0,
        streak: Streak = Streak(),
        clusters: [Cluster] = [],
        niceClusterCount: Int = 0
    ) {
        self.from = from
        self.days = days
        self.seizures = seizures
        self.suspected = suspected
        self.seizureDays = seizureDays
        self.streak = streak
        self.clusters = clusters
        self.niceClusterCount = niceClusterCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? ""
        days = (try? c.decodeIfPresent(Int.self, forKey: .days)) ?? 0
        seizures = (try? c.decodeIfPresent(Int.self, forKey: .seizures)) ?? 0
        suspected = (try? c.decodeIfPresent(Int.self, forKey: .suspected)) ?? 0
        seizureDays = (try? c.decodeIfPresent(Int.self, forKey: .seizureDays)) ?? 0
        streak = (try? c.decodeIfPresent(Streak.self, forKey: .streak)) ?? Streak()
        clusters = ((try? c.decodeIfPresent([SeizureLossy<Cluster>].self, forKey: .clusters)) ?? []).compactMap(\.value)
        niceClusterCount = (try? c.decodeIfPresent(Int.self, forKey: .niceClusterCount)) ?? 0
    }

    /// The events that belong to a cluster episode under the record's rule.
    public var clusteredEventIDs: Set<String> {
        Set(clusters.flatMap(\.eventIds))
    }
}

/// `GET /api/seizures` (`SeizureDiary`): the whole diary in one read.
public struct SeizureDiaryDTO: Codable, Sendable, Equatable {
    public let types: [SeizureTypeDTO]
    public let settings: SeizureSettingsDTO
    /// Newest first, as the list shows them.
    public let events: [SeizureEventDTO]
    public let summary: SeizureDiarySummaryDTO?
    /// The period held more events than one read returns.
    public let truncated: Bool

    public init(
        types: [SeizureTypeDTO] = [],
        settings: SeizureSettingsDTO = SeizureSettingsDTO(),
        events: [SeizureEventDTO] = [],
        summary: SeizureDiarySummaryDTO? = nil,
        truncated: Bool = false
    ) {
        self.types = types
        self.settings = settings
        self.events = events.sorted { $0.onsetAt > $1.onsetAt }
        self.summary = summary
        self.truncated = truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        types = ((try? c.decodeIfPresent([SeizureLossy<SeizureTypeDTO>].self, forKey: .types)) ?? []).compactMap(\.value)
        settings = (try? c.decodeIfPresent(SeizureSettingsDTO.self, forKey: .settings)) ?? SeizureSettingsDTO()
        events = ((try? c.decodeIfPresent([SeizureLossy<SeizureEventDTO>].self, forKey: .events)) ?? [])
            .compactMap(\.value)
            .sorted { $0.onsetAt > $1.onsetAt }
        summary = try? c.decodeIfPresent(SeizureDiarySummaryDTO.self, forKey: .summary)
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    }

    /// The types the quick log offers: not archived, in the person's order.
    public var activeTypes: [SeizureTypeDTO] {
        types.filter { !$0.archived }.sorted { ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName) }
    }

    public func type(id: String?) -> SeizureTypeDTO? {
        guard let id else { return nil }
        return types.first { $0.id == id }
    }
}

/// Decodes one element of a list and keeps going when it cannot.
struct SeizureLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Parsing and the clock text of the diary.
public enum SeizureDateFormat {
    public static func parse(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }

    public static func wire(_ date: Date) -> String {
        ISO8601DateFormatter.fractional.string(from: date)
    }

    /// "4:07" for seconds of a running or recorded seizure; hours as "1:04:07".
    public static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        let tail = String(format: "%02d", rest)
        if hours > 0 { return "\(hours):\(String(format: "%02d", minutes)):\(tail)" }
        return "\(minutes):\(tail)"
    }
}
