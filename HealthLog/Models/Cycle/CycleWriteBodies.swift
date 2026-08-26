import Foundation

// Encodable request bodies for the v1.15 LOCKED cycle write contract. Each
// carries `encodeIfPresent` so a partial PATCH never sends a `null` the server
// would interpret as "clear this field". `externalId` is the client-stable
// dedup key (UPSERT on `(userId, source, externalId)`); the same id rides the
// Outbox payload so a replay is idempotent (last-writer-wins, MoodEntry
// precedent). `loggedAt` is ISO-8601; `date` is `YYYY-MM-DD`.

/// `POST /api/cycle/day-logs` + `PATCH …/{id}` body (also one bulk entry).
public struct CycleDayLogWrite: Codable, Sendable, Equatable {
    public var date: String
    public var flow: CycleFlowLevel?
    public var intermenstrualBleeding: Bool?
    public var basalBodyTempC: Double?
    /// v1.16.15 — mark this BBT reading "disturbed" so the server excludes it
    /// from the temperature evaluation. Only meaningful with `basalBodyTempC`.
    public var temperatureExcluded: Bool?
    public var ovulationTest: CycleOvulationTest?
    public var cervicalMucus: CycleCervicalMucus?
    /// v1.16.15 — cervix secondary-symptom observations (manual-only).
    public var cervixPosition: CycleCervixPosition?
    public var cervixFirmness: CycleCervixFirmness?
    public var cervixOpening: CycleCervixOpening?
    public var sexualActivity: Bool?
    public var protectedSex: Bool?
    public var pregnancyTest: CycleTestResult?
    public var progesteroneTest: CycleTestResult?
    /// v0.14.8 — the active contraceptive method on the day (HK
    /// `HKCategoryTypeIdentifierContraceptive` ingest; server folds it onto
    /// the day-log timeline, `contraceptiveKindEnum`).
    public var contraceptive: CycleContraceptiveKind?
    public var symptoms: [CycleSymptomDTO]?
    public var note: String?
    /// ISO-8601 with offset — the LWW timestamp.
    public var loggedAt: String
    public var source: String
    /// 1...120; the client-stable UPSERT key.
    public var externalId: String?

    public init(
        date: String,
        flow: CycleFlowLevel? = nil,
        intermenstrualBleeding: Bool? = nil,
        basalBodyTempC: Double? = nil,
        temperatureExcluded: Bool? = nil,
        ovulationTest: CycleOvulationTest? = nil,
        cervicalMucus: CycleCervicalMucus? = nil,
        cervixPosition: CycleCervixPosition? = nil,
        cervixFirmness: CycleCervixFirmness? = nil,
        cervixOpening: CycleCervixOpening? = nil,
        sexualActivity: Bool? = nil,
        protectedSex: Bool? = nil,
        pregnancyTest: CycleTestResult? = nil,
        progesteroneTest: CycleTestResult? = nil,
        contraceptive: CycleContraceptiveKind? = nil,
        symptoms: [CycleSymptomDTO]? = nil,
        note: String? = nil,
        loggedAt: String,
        source: String = "MANUAL",
        externalId: String? = nil
    ) {
        self.date = date
        self.flow = flow
        self.intermenstrualBleeding = intermenstrualBleeding
        self.basalBodyTempC = basalBodyTempC
        self.temperatureExcluded = temperatureExcluded
        self.ovulationTest = ovulationTest
        self.cervicalMucus = cervicalMucus
        self.cervixPosition = cervixPosition
        self.cervixFirmness = cervixFirmness
        self.cervixOpening = cervixOpening
        self.sexualActivity = sexualActivity
        self.protectedSex = protectedSex
        self.pregnancyTest = pregnancyTest
        self.progesteroneTest = progesteroneTest
        self.contraceptive = contraceptive
        self.symptoms = symptoms
        self.note = note
        self.loggedAt = loggedAt
        self.source = source
        self.externalId = externalId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(flow, forKey: .flow)
        try c.encodeIfPresent(intermenstrualBleeding, forKey: .intermenstrualBleeding)
        try c.encodeIfPresent(basalBodyTempC, forKey: .basalBodyTempC)
        try c.encodeIfPresent(temperatureExcluded, forKey: .temperatureExcluded)
        try c.encodeIfPresent(ovulationTest, forKey: .ovulationTest)
        try c.encodeIfPresent(cervicalMucus, forKey: .cervicalMucus)
        try c.encodeIfPresent(cervixPosition, forKey: .cervixPosition)
        try c.encodeIfPresent(cervixFirmness, forKey: .cervixFirmness)
        try c.encodeIfPresent(cervixOpening, forKey: .cervixOpening)
        try c.encodeIfPresent(sexualActivity, forKey: .sexualActivity)
        try c.encodeIfPresent(protectedSex, forKey: .protectedSex)
        try c.encodeIfPresent(pregnancyTest, forKey: .pregnancyTest)
        try c.encodeIfPresent(progesteroneTest, forKey: .progesteroneTest)
        try c.encodeIfPresent(contraceptive, forKey: .contraceptive)
        try c.encodeIfPresent(symptoms, forKey: .symptoms)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(loggedAt, forKey: .loggedAt)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(externalId, forKey: .externalId)
    }
}

/// `PATCH /api/cycle/day-logs/{id}` body. Unlike the create body, nullable
/// fields preserve all three server states: omit, explicit `null`, or value.
/// `symptoms` uses `.set([])` to clear links without deleting their catalogue
/// entries. Immutable create fields (`date`, `source`, `externalId`) are absent.
public struct CycleDayLogPatch: Codable, Sendable, Equatable {
    public var flow: RecordPatchField<CycleFlowLevel>
    public var intermenstrualBleeding: Bool?
    public var basalBodyTempC: RecordPatchField<Double>
    public var temperatureExcluded: Bool?
    public var ovulationTest: RecordPatchField<CycleOvulationTest>
    public var cervicalMucus: RecordPatchField<CycleCervicalMucus>
    public var cervixPosition: RecordPatchField<CycleCervixPosition>
    public var cervixFirmness: RecordPatchField<CycleCervixFirmness>
    public var cervixOpening: RecordPatchField<CycleCervixOpening>
    public var sexualActivity: Bool?
    public var protectedSex: RecordPatchField<Bool>
    public var pregnancyTest: RecordPatchField<CycleTestResult>
    public var progesteroneTest: RecordPatchField<CycleTestResult>
    public var contraceptive: RecordPatchField<CycleContraceptiveKind>
    public var symptoms: RecordPatchField<[CycleSymptomDTO]>
    public var note: RecordPatchField<String>
    public var loggedAt: String?

    private enum CodingKeys: String, CodingKey {
        case flow, intermenstrualBleeding, basalBodyTempC, temperatureExcluded
        case ovulationTest, cervicalMucus, cervixPosition, cervixFirmness, cervixOpening
        case sexualActivity, protectedSex, pregnancyTest, progesteroneTest
        case contraceptive, symptoms, note, loggedAt
    }

    public init(
        flow: RecordPatchField<CycleFlowLevel> = .unchanged,
        intermenstrualBleeding: Bool? = nil,
        basalBodyTempC: RecordPatchField<Double> = .unchanged,
        temperatureExcluded: Bool? = nil,
        ovulationTest: RecordPatchField<CycleOvulationTest> = .unchanged,
        cervicalMucus: RecordPatchField<CycleCervicalMucus> = .unchanged,
        cervixPosition: RecordPatchField<CycleCervixPosition> = .unchanged,
        cervixFirmness: RecordPatchField<CycleCervixFirmness> = .unchanged,
        cervixOpening: RecordPatchField<CycleCervixOpening> = .unchanged,
        sexualActivity: Bool? = nil,
        protectedSex: RecordPatchField<Bool> = .unchanged,
        pregnancyTest: RecordPatchField<CycleTestResult> = .unchanged,
        progesteroneTest: RecordPatchField<CycleTestResult> = .unchanged,
        contraceptive: RecordPatchField<CycleContraceptiveKind> = .unchanged,
        symptoms: RecordPatchField<[CycleSymptomDTO]> = .unchanged,
        note: RecordPatchField<String> = .unchanged,
        loggedAt: String? = nil
    ) {
        self.flow = flow
        self.intermenstrualBleeding = intermenstrualBleeding
        self.basalBodyTempC = basalBodyTempC
        self.temperatureExcluded = temperatureExcluded
        self.ovulationTest = ovulationTest
        self.cervicalMucus = cervicalMucus
        self.cervixPosition = cervixPosition
        self.cervixFirmness = cervixFirmness
        self.cervixOpening = cervixOpening
        self.sexualActivity = sexualActivity
        self.protectedSex = protectedSex
        self.pregnancyTest = pregnancyTest
        self.progesteroneTest = progesteroneTest
        self.contraceptive = contraceptive
        self.symptoms = symptoms
        self.note = note
        self.loggedAt = loggedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flow = try .decode(from: c, forKey: .flow)
        intermenstrualBleeding = try c.decodeIfPresent(Bool.self, forKey: .intermenstrualBleeding)
        basalBodyTempC = try .decode(from: c, forKey: .basalBodyTempC)
        temperatureExcluded = try c.decodeIfPresent(Bool.self, forKey: .temperatureExcluded)
        ovulationTest = try .decode(from: c, forKey: .ovulationTest)
        cervicalMucus = try .decode(from: c, forKey: .cervicalMucus)
        cervixPosition = try .decode(from: c, forKey: .cervixPosition)
        cervixFirmness = try .decode(from: c, forKey: .cervixFirmness)
        cervixOpening = try .decode(from: c, forKey: .cervixOpening)
        sexualActivity = try c.decodeIfPresent(Bool.self, forKey: .sexualActivity)
        protectedSex = try .decode(from: c, forKey: .protectedSex)
        pregnancyTest = try .decode(from: c, forKey: .pregnancyTest)
        progesteroneTest = try .decode(from: c, forKey: .progesteroneTest)
        contraceptive = try .decode(from: c, forKey: .contraceptive)
        symptoms = try .decode(from: c, forKey: .symptoms)
        note = try .decode(from: c, forKey: .note)
        loggedAt = try c.decodeIfPresent(String.self, forKey: .loggedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try flow.encode(into: &c, forKey: .flow)
        try c.encodeIfPresent(intermenstrualBleeding, forKey: .intermenstrualBleeding)
        try basalBodyTempC.encode(into: &c, forKey: .basalBodyTempC)
        try c.encodeIfPresent(temperatureExcluded, forKey: .temperatureExcluded)
        try ovulationTest.encode(into: &c, forKey: .ovulationTest)
        try cervicalMucus.encode(into: &c, forKey: .cervicalMucus)
        try cervixPosition.encode(into: &c, forKey: .cervixPosition)
        try cervixFirmness.encode(into: &c, forKey: .cervixFirmness)
        try cervixOpening.encode(into: &c, forKey: .cervixOpening)
        try c.encodeIfPresent(sexualActivity, forKey: .sexualActivity)
        try protectedSex.encode(into: &c, forKey: .protectedSex)
        try pregnancyTest.encode(into: &c, forKey: .pregnancyTest)
        try progesteroneTest.encode(into: &c, forKey: .progesteroneTest)
        try contraceptive.encode(into: &c, forKey: .contraceptive)
        try symptoms.encode(into: &c, forKey: .symptoms)
        try note.encode(into: &c, forKey: .note)
        try c.encodeIfPresent(loggedAt, forKey: .loggedAt)
    }
}

/// `POST /api/cycle/day-logs/bulk` body — the Outbox + HealthKit drain target.
public struct CycleBulkRequest: Codable, Sendable, Equatable {
    public let entries: [CycleDayLogWrite]
    public init(entries: [CycleDayLogWrite]) {
        self.entries = entries
    }
}

public enum CyclePeriodAction: String, Codable, Sendable, Equatable {
    case start, end
}

/// `POST /api/cycle/period` — one-tap start/end (Widget/Control quick action).
public struct CyclePeriodRequest: Codable, Sendable, Equatable {
    public let action: CyclePeriodAction
    public let date: String
    public let loggedAt: String
    public let externalId: String?

    public init(action: CyclePeriodAction, date: String, loggedAt: String, externalId: String? = nil) {
        self.action = action
        self.date = date
        self.loggedAt = loggedAt
        self.externalId = externalId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(date, forKey: .date)
        try c.encode(loggedAt, forKey: .loggedAt)
        try c.encodeIfPresent(externalId, forKey: .externalId)
    }
}

/// `PATCH /api/auth/me/cycle-prefs` — deep-merge prefs mutation.
public struct CyclePrefsPatch: Codable, Sendable, Equatable {
    /// **Build 9 (Server-Prefs) / 9.3** — the server-owned cycle-tracking opt-in
    /// (`cycleTrackingEnabled` column). Deep-merge (field-by-field): sent ONLY by
    /// an explicit toggle or the one flag-guarded 9.3 migration, so `encodeIfPresent`
    /// keeps it off the wire otherwise (a bare `{"enabled":true}` must not drag any
    /// sibling field along).
    public var enabled: Bool?
    public var goal: CycleGoal?
    public var rawChartMode: Bool?
    public var typicalCycleLength: RecordPatchField<Int>
    public var typicalPeriodLength: RecordPatchField<Int>
    public var lutealPhaseLength: RecordPatchField<Int>
    public var predictionEnabled: Bool?
    public var discreetNotifications: Bool?
    public var sensitiveCategoryEncryption: Bool?
    private enum CodingKeys: String, CodingKey {
        case enabled
        case goal, rawChartMode, typicalCycleLength, typicalPeriodLength, lutealPhaseLength
        case predictionEnabled, discreetNotifications, sensitiveCategoryEncryption, secondarySymptom
    }

    public var secondarySymptom: CycleSecondarySymptom?

    public init(
        enabled: Bool? = nil,
        goal: CycleGoal? = nil,
        rawChartMode: Bool? = nil,
        typicalCycleLength: RecordPatchField<Int> = .unchanged,
        typicalPeriodLength: RecordPatchField<Int> = .unchanged,
        lutealPhaseLength: RecordPatchField<Int> = .unchanged,
        predictionEnabled: Bool? = nil,
        discreetNotifications: Bool? = nil,
        sensitiveCategoryEncryption: Bool? = nil,
        secondarySymptom: CycleSecondarySymptom? = nil
    ) {
        self.enabled = enabled
        self.goal = goal
        self.rawChartMode = rawChartMode
        self.typicalCycleLength = typicalCycleLength
        self.typicalPeriodLength = typicalPeriodLength
        self.lutealPhaseLength = lutealPhaseLength
        self.predictionEnabled = predictionEnabled
        self.discreetNotifications = discreetNotifications
        self.sensitiveCategoryEncryption = sensitiveCategoryEncryption
        self.secondarySymptom = secondarySymptom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        goal = try c.decodeIfPresent(CycleGoal.self, forKey: .goal)
        rawChartMode = try c.decodeIfPresent(Bool.self, forKey: .rawChartMode)
        typicalCycleLength = try .decode(from: c, forKey: .typicalCycleLength)
        typicalPeriodLength = try .decode(from: c, forKey: .typicalPeriodLength)
        lutealPhaseLength = try .decode(from: c, forKey: .lutealPhaseLength)
        predictionEnabled = try c.decodeIfPresent(Bool.self, forKey: .predictionEnabled)
        discreetNotifications = try c.decodeIfPresent(Bool.self, forKey: .discreetNotifications)
        sensitiveCategoryEncryption = try c.decodeIfPresent(Bool.self, forKey: .sensitiveCategoryEncryption)
        secondarySymptom = try c.decodeIfPresent(CycleSecondarySymptom.self, forKey: .secondarySymptom)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(goal, forKey: .goal)
        try c.encodeIfPresent(rawChartMode, forKey: .rawChartMode)
        try typicalCycleLength.encode(into: &c, forKey: .typicalCycleLength)
        try typicalPeriodLength.encode(into: &c, forKey: .typicalPeriodLength)
        try lutealPhaseLength.encode(into: &c, forKey: .lutealPhaseLength)
        try c.encodeIfPresent(predictionEnabled, forKey: .predictionEnabled)
        try c.encodeIfPresent(discreetNotifications, forKey: .discreetNotifications)
        try c.encodeIfPresent(sensitiveCategoryEncryption, forKey: .sensitiveCategoryEncryption)
        try c.encodeIfPresent(secondarySymptom, forKey: .secondarySymptom)
    }
}
