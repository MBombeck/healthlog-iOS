import Foundation

/// A rescue dose as the quick log or the detail page sends it
/// (`CreateSeizureRescueDoseRequest`). With a `medicationId` the server also
/// records an intake on that as-needed medication; without one
/// `medicationName` is required (a dose given by paramedics).
public struct SeizureRescueDoseCreate: Codable, Sendable, Equatable, Hashable {
    public var medicationId: String?
    public var medicationName: String?
    public var doseAmount: Double?
    public var doseUnit: String?
    public var route: SeizureRescueRoute?
    public var givenAt: String
    public var givenBy: SeizureObserverRole?
    public var effect: SeizureRescueEffect?
    public var seizureEndedAt: String?

    public init(
        medicationId: String? = nil,
        medicationName: String? = nil,
        doseAmount: Double? = nil,
        doseUnit: String? = nil,
        route: SeizureRescueRoute? = nil,
        givenAt: String,
        givenBy: SeizureObserverRole? = nil,
        effect: SeizureRescueEffect? = nil,
        seizureEndedAt: String? = nil
    ) {
        self.medicationId = medicationId
        self.medicationName = medicationName
        self.doseAmount = doseAmount
        self.doseUnit = doseUnit
        self.route = route
        self.givenAt = givenAt
        self.givenBy = givenBy
        self.effect = effect
        self.seizureEndedAt = seizureEndedAt
    }

    /// The dose the type's plan names, stamped at `givenAt`: the drug,
    /// amount, unit and route as they stand in the plan.
    public static func fromPlan(_ type: SeizureTypeDTO, givenAt: Date) -> SeizureRescueDoseCreate {
        SeizureRescueDoseCreate(
            medicationId: type.rescueMedicationId,
            medicationName: type.rescueMedicationName,
            doseAmount: type.rescueDoseAmount,
            doseUnit: type.rescueDoseUnit,
            route: type.rescueRoute,
            givenAt: SeizureDateFormat.wire(givenAt)
        )
    }
}

/// The edits to a rescue dose (`UpdateSeizureRescueDoseRequest`).
public struct SeizureRescueDosePatch: Encodable, Sendable, Equatable {
    public var effect: SeizureRescueEffect?
    public var givenBy: RecordPatchField<SeizureObserverRole>
    public var route: RecordPatchField<SeizureRescueRoute>

    public init(
        effect: SeizureRescueEffect? = nil,
        givenBy: RecordPatchField<SeizureObserverRole> = .unchanged,
        route: RecordPatchField<SeizureRescueRoute> = .unchanged
    ) {
        self.effect = effect
        self.givenBy = givenBy
        self.route = route
    }

    private enum CodingKeys: String, CodingKey {
        case effect, givenBy, route
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(effect, forKey: .effect)
        try givenBy.encode(into: &c, forKey: .givenBy)
        try route.encode(into: &c, forKey: .route)
    }
}

/// A seizure as the form sends it: `POST /api/seizures/events` on create,
/// `PATCH /api/seizures/events/{id}` on edit. On a create an absent value is
/// left out; on an edit every field the form shows is sent, an empty one as
/// `null` (or `""` for the note), so a cleared field is cleared on the
/// server. Fields the form does not show are never sent and stay as they are.
public struct SeizureEventWrite: Encodable, Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case create
        case update
    }

    public var mode: Mode
    public var typeProfileId: String?
    public var onsetAt: String
    public var onsetPrecision: SeizureOnsetPrecision
    public var durationSec: Int?
    public var durationSource: SeizureDurationSource
    public var count: Int
    public var certainty: SeizureCertainty
    public var sleepState: SeizureSleepState
    public var semiology: [SeizureSemiology]
    public var triggers: [SeizureTrigger]
    public var postictal: [SeizurePostictal]
    public var injuries: [SeizureInjury]
    public var emergency: SeizureEmergency
    public var witnessed: Bool?
    public var witnessRole: SeizureObserverRole?
    public var note: String
    /// Written with the seizure in one go; create only, at most five.
    public var rescueDoses: [SeizureRescueDoseCreate]

    public static let maxRescueDoses = 5
    public static let maxDurationSec = 86400
    public static let countRange = 1 ... 500

    public init(
        mode: Mode,
        typeProfileId: String? = nil,
        onsetAt: String,
        onsetPrecision: SeizureOnsetPrecision = .exact,
        durationSec: Int? = nil,
        durationSource: SeizureDurationSource = .unknown,
        count: Int = 1,
        certainty: SeizureCertainty = .confirmed,
        sleepState: SeizureSleepState = .unknown,
        semiology: [SeizureSemiology] = [],
        triggers: [SeizureTrigger] = [],
        postictal: [SeizurePostictal] = [],
        injuries: [SeizureInjury] = [],
        emergency: SeizureEmergency = .noneNoted,
        witnessed: Bool? = nil,
        witnessRole: SeizureObserverRole? = nil,
        note: String = "",
        rescueDoses: [SeizureRescueDoseCreate] = []
    ) {
        self.mode = mode
        self.typeProfileId = typeProfileId
        self.onsetAt = onsetAt
        self.onsetPrecision = onsetPrecision
        self.durationSec = durationSec
        self.durationSource = durationSource
        self.count = count
        self.certainty = certainty
        self.sleepState = sleepState
        self.semiology = semiology
        self.triggers = triggers
        self.postictal = postictal
        self.injuries = injuries
        self.emergency = emergency
        self.witnessed = witnessed
        self.witnessRole = witnessRole
        self.note = note
        self.rescueDoses = rescueDoses
    }

    /// The server's duration rule (`durationConsistent`): no duration means
    /// UNKNOWN, a duration is TIMED or ESTIMATED.
    public var resolvedDurationSource: SeizureDurationSource {
        guard durationSec != nil else { return .unknown }
        return durationSource == .unknown || durationSource == .unrecognized ? .estimated : durationSource
    }

    private enum CodingKeys: String, CodingKey {
        case typeProfileId, onsetAt, onsetPrecision, durationSec, durationSource, count, certainty, sleepState
        case semiology, triggers, postictal, injuries, emergency, witnessed, witnessRole, note, rescueDoses
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(onsetAt, forKey: .onsetAt)
        try c.encode(onsetPrecision, forKey: .onsetPrecision)
        try c.encode(min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound), forKey: .count)
        try c.encode(certainty, forKey: .certainty)
        try c.encode(sleepState, forKey: .sleepState)
        try c.encode(semiology, forKey: .semiology)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(postictal, forKey: .postictal)
        try c.encode(injuries, forKey: .injuries)
        try c.encode(emergency, forKey: .emergency)
        try c.encode(resolvedDurationSource, forKey: .durationSource)
        let duration = durationSec.map { min(max($0, 0), Self.maxDurationSec) }
        switch mode {
        case .create:
            try c.encodeIfPresent(typeProfileId, forKey: .typeProfileId)
            try c.encodeIfPresent(duration, forKey: .durationSec)
            try c.encodeIfPresent(witnessed, forKey: .witnessed)
            try c.encodeIfPresent(witnessRole, forKey: .witnessRole)
            if !trimmedNote.isEmpty { try c.encode(trimmedNote, forKey: .note) }
            if !rescueDoses.isEmpty {
                try c.encode(Array(rescueDoses.prefix(Self.maxRescueDoses)), forKey: .rescueDoses)
            }
        case .update:
            try c.encode(typeProfileId, forKey: .typeProfileId)
            try c.encode(duration, forKey: .durationSec)
            try c.encode(witnessed, forKey: .witnessed)
            try c.encode(witnessRole, forKey: .witnessRole)
            try c.encode(trimmedNote, forKey: .note)
        }
    }
}

/// A seizure type as the app sends it (`CreateSeizureTypeRequest` /
/// `UpdateSeizureTypeRequest`). The plan text and the rescue medication are
/// edited on the web and never sent from here, so they stay as they are.
public struct SeizureTypeWrite: Encodable, Sendable, Equatable {
    public var label: String?
    public var ilaeType: SeizureIlaeType?
    public var usualDurationSec: RecordPatchField<Int>
    public var archived: Bool?

    public static let labelMax = 40

    public init(
        label: String? = nil,
        ilaeType: SeizureIlaeType? = nil,
        usualDurationSec: RecordPatchField<Int> = .unchanged,
        archived: Bool? = nil
    ) {
        self.label = label
        self.ilaeType = ilaeType
        self.usualDurationSec = usualDurationSec
        self.archived = archived
    }

    private enum CodingKeys: String, CodingKey {
        case label, ilaeType, usualDurationSec, archived
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label.map { String($0.trimmingCharacters(in: .whitespaces).prefix(Self.labelMax)) }, forKey: .label)
        try c.encodeIfPresent(ilaeType, forKey: .ilaeType)
        try usualDurationSec.encode(into: &c, forKey: .usualDurationSec)
        try c.encodeIfPresent(archived, forKey: .archived)
    }
}

/// `PATCH /api/seizures/settings`.
public struct SeizureSettingsPatch: Encodable, Sendable, Equatable {
    public let clusterCount: Int
    public let clusterWindowHours: Int

    public init(rule: SeizureClusterRule) {
        clusterCount = min(max(rule.count, SeizureClusterRule.countRange.lowerBound), SeizureClusterRule.countRange.upperBound)
        clusterWindowHours = min(
            max(rule.windowHours, SeizureClusterRule.windowRange.lowerBound),
            SeizureClusterRule.windowRange.upperBound
        )
    }
}
