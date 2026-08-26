import Foundation

// Wire DTOs for the v1.15 LOCKED cycle-tracking contract.
//
// Source of truth (verified 2026-06-06 against `HealthLog` server repo):
//   - `src/lib/cycle/dto.ts`          → CycleDayLogDTO / MenstrualCycleDTO /
//                                        CyclePredictionDTO / CycleProfileDTO
//   - `src/lib/cycle/engine-adapter.ts` → CalendarDayDTO
//   - `src/app/api/cycle/calendar/route.ts` → calendar envelope (slim profile)
//   - `src/app/api/cycle/cycles/route.ts`   → cycles envelope + stats
//   - `src/app/api/cycle/day-logs/bulk/route.ts` → bulk per-entry results
//   - `src/lib/cycle/gate.ts`         → 403 errorCode "cycle.disabled"
//
// Every struct is `Sendable` + `Codable` with **tolerant decode**
// (`decodeIfPresent` + safe defaults) so a server field added later — or an
// unknown enum member — never hard-fails the whole envelope (MoodEntry
// precedent, `Mood.swift:113`). Enum-typed wire values are decoded as `String`
// and surfaced through typed accessors that fall back gracefully; the canonical
// raw-value enums live on `CyclePredictionEngine` (already shipped) and are
// reused via typealias so there is exactly one casing table in the app.

// MARK: - Enum aliases (single casing table — engine owns the raw values)

public typealias CycleFlowLevel = CyclePredictionEngine.FlowLevel
public typealias CycleOvulationTest = CyclePredictionEngine.OvulationTest
public typealias CycleCervicalMucus = CyclePredictionEngine.CervicalMucus
public typealias CyclePhaseValue = CyclePredictionEngine.CyclePhase
public typealias CyclePredictionMethod = CyclePredictionEngine.PredictionMethod
public typealias CycleGoal = CyclePredictionEngine.CycleTrackingGoal

/// `{ NEGATIVE | POSITIVE | INDETERMINATE }` for pregnancy/progesterone tests.
public enum CycleTestResult: String, Codable, Sendable, CaseIterable, Equatable {
    case negative = "NEGATIVE"
    case positive = "POSITIVE"
    case indeterminate = "INDETERMINATE"
}

/// `{ NONE | UNSPECIFIED | IMPLANT | INJECTION | IUD | INTRAVAGINAL_RING |
/// ORAL | PATCH | EMERGENCY }` — the day-log contraceptive method (v1.15
/// contract `contraceptiveKindEnum`, mirrors the server's
/// `HK_CONTRACEPTIVE_VALUES` table).
public enum CycleContraceptiveKind: String, Codable, Sendable, CaseIterable, Equatable {
    case none = "NONE"
    case unspecified = "UNSPECIFIED"
    case implant = "IMPLANT"
    case injection = "INJECTION"
    case iud = "IUD"
    case intravaginalRing = "INTRAVAGINAL_RING"
    case oral = "ORAL"
    case patch = "PATCH"
    case emergency = "EMERGENCY"
}

/// `{ REGULAR | IRREGULAR | LEARNING }` — `cycles` stats regularity verdict.
public enum CycleRegularity: String, Codable, Sendable, CaseIterable, Equatable {
    case regular = "REGULAR"
    case irregular = "IRREGULAR"
    case learning = "LEARNING"
}

// MARK: - Cervix secondary-symptom observations (v1.16.15, manual-only)

/// `{ LOW | HIGH | null }` — the cervix position observation. **Manual-only**
/// (HealthKit has no cervix category). Part of the symptothermal secondary
/// sign when ``CycleProfileDTO/secondarySymptomValue`` is ``CycleSecondarySymptom/cervix``.
public enum CycleCervixPosition: String, Codable, Sendable, CaseIterable, Equatable {
    case low = "LOW"
    case high = "HIGH"
}

/// `{ FIRM | SOFT | null }` — the cervix firmness observation. Manual-only.
public enum CycleCervixFirmness: String, Codable, Sendable, CaseIterable, Equatable {
    case firm = "FIRM"
    case soft = "SOFT"
}

/// `{ CLOSED | OPEN | null }` — the cervix opening observation. Manual-only.
public enum CycleCervixOpening: String, Codable, Sendable, CaseIterable, Equatable {
    case closed = "CLOSED"
    case open = "OPEN"
}

/// `{ MUCUS | CERVIX }` — the chosen secondary symptothermal sign (v1.16.15
/// `CycleProfileDTO.secondarySymptom`, default `MUCUS`). Surfaced in advanced
/// cycle settings only (progressive disclosure).
public enum CycleSecondarySymptom: String, Codable, Sendable, CaseIterable, Equatable {
    case mucus = "MUCUS"
    case cervix = "CERVIX"
}

// MARK: - CycleSymptomDTO

public struct CycleSymptomDTO: Codable, Sendable, Equatable, Hashable {
    public let key: String
    /// 1...4, or nil.
    public let severity: Int?

    public init(key: String, severity: Int? = nil) {
        self.key = key
        self.severity = severity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        severity = try c.decodeIfPresent(Int.self, forKey: .severity)
    }
}

// MARK: - CycleDayLogDTO

/// One day's canonical cycle row. `note` arrives decrypted from the server.
public struct CycleDayLogDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// `YYYY-MM-DD` (the canonical day key).
    public let date: String
    public let cycleId: String?
    /// Raw flow string — see ``flowLevel`` for the typed accessor.
    public let flow: String?
    public let intermenstrualBleeding: Bool
    public let basalBodyTempC: Double?
    /// v1.16.15 — the BBT reading was marked "disturbed" (fever / late) and is
    /// excluded from the temperature evaluation. Defaults `false`.
    public let temperatureExcluded: Bool
    public let ovulationTest: String?
    public let cervicalMucus: String?
    /// v1.16.15 — cervix secondary-symptom observations (manual-only). See the
    /// typed accessors below.
    public let cervixPosition: String?
    public let cervixFirmness: String?
    public let cervixOpening: String?
    public let sexualActivity: Bool
    public let protectedSex: Bool?
    public let pregnancyTest: String?
    public let progesteroneTest: String?
    public let contraceptive: String?
    public let symptoms: [CycleSymptomDTO]
    public let note: String?
    public let source: String
    public let externalId: String?
    public let syncVersion: Int
    /// ISO-8601.
    public let updatedAt: Date?
    public let deletedAt: Date?

    public var flowLevel: CycleFlowLevel? {
        flow.flatMap(CycleFlowLevel.init)
    }

    public var ovulationTestValue: CycleOvulationTest? {
        ovulationTest.flatMap(CycleOvulationTest.init)
    }

    public var cervicalMucusValue: CycleCervicalMucus? {
        cervicalMucus.flatMap(CycleCervicalMucus.init)
    }

    public var cervixPositionValue: CycleCervixPosition? {
        cervixPosition.flatMap(CycleCervixPosition.init)
    }

    public var cervixFirmnessValue: CycleCervixFirmness? {
        cervixFirmness.flatMap(CycleCervixFirmness.init)
    }

    public var cervixOpeningValue: CycleCervixOpening? {
        cervixOpening.flatMap(CycleCervixOpening.init)
    }

    public var contraceptiveKind: CycleContraceptiveKind? {
        contraceptive.flatMap(CycleContraceptiveKind.init)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        cycleId = try c.decodeIfPresent(String.self, forKey: .cycleId)
        flow = try c.decodeIfPresent(String.self, forKey: .flow)
        intermenstrualBleeding = try c.decodeIfPresent(Bool.self, forKey: .intermenstrualBleeding) ?? false
        basalBodyTempC = try c.decodeIfPresent(Double.self, forKey: .basalBodyTempC)
        temperatureExcluded = try c.decodeIfPresent(Bool.self, forKey: .temperatureExcluded) ?? false
        ovulationTest = try c.decodeIfPresent(String.self, forKey: .ovulationTest)
        cervicalMucus = try c.decodeIfPresent(String.self, forKey: .cervicalMucus)
        cervixPosition = try c.decodeIfPresent(String.self, forKey: .cervixPosition)
        cervixFirmness = try c.decodeIfPresent(String.self, forKey: .cervixFirmness)
        cervixOpening = try c.decodeIfPresent(String.self, forKey: .cervixOpening)
        sexualActivity = try c.decodeIfPresent(Bool.self, forKey: .sexualActivity) ?? false
        protectedSex = try c.decodeIfPresent(Bool.self, forKey: .protectedSex)
        pregnancyTest = try c.decodeIfPresent(String.self, forKey: .pregnancyTest)
        progesteroneTest = try c.decodeIfPresent(String.self, forKey: .progesteroneTest)
        contraceptive = try c.decodeIfPresent(String.self, forKey: .contraceptive)
        symptoms = try c.decodeIfPresent([CycleSymptomDTO].self, forKey: .symptoms) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "MANUAL"
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        syncVersion = try c.decodeIfPresent(Int.self, forKey: .syncVersion) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

// MARK: - MenstrualCycleDTO

public struct MenstrualCycleDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let startDate: String
    public let endDate: String?
    public let periodEndDate: String?
    public let lengthDays: Int?
    public let ovulationDate: String?
    public let ovulationConfirmed: Bool
    public let isPredicted: Bool
    public let syncVersion: Int
    public let updatedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate) ?? ""
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        periodEndDate = try c.decodeIfPresent(String.self, forKey: .periodEndDate)
        lengthDays = try c.decodeIfPresent(Int.self, forKey: .lengthDays)
        ovulationDate = try c.decodeIfPresent(String.self, forKey: .ovulationDate)
        ovulationConfirmed = try c.decodeIfPresent(Bool.self, forKey: .ovulationConfirmed) ?? false
        isPredicted = try c.decodeIfPresent(Bool.self, forKey: .isPredicted) ?? false
        syncVersion = try c.decodeIfPresent(Int.self, forKey: .syncVersion) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - CyclePredictionDTO

/// Server-authoritative prediction (mirrors the on-device engine 1:1). Fertile
/// fields are `null` unless the goal allows them (server suppresses).
public struct CyclePredictionDTO: Codable, Sendable, Equatable, Hashable {
    public let method: String
    public let nextPeriodStart: String
    public let nextPeriodStartLow: String
    public let nextPeriodStartHigh: String
    public let fertileWindowStart: String?
    public let fertileWindowEnd: String?
    public let predictedOvulation: String?
    public let ovulationConfirmed: Bool
    public let confidence: Double
    public let cyclesObserved: Int
    public let stillLearning: Bool
    public let disclaimer: String

    public var methodValue: CyclePredictionMethod? {
        CyclePredictionMethod(rawValue: method)
    }

    /// Memberwise construction — the ONLY non-decode construction path, used by
    /// the offline engine bridge (`CyclePredictionEngine.Prediction
    /// .asPredictionDTO(goalAllowsFertile:)`, CU-25/#72) so the on-device
    /// fallback lands in exactly the same wire shape the server sends.
    public init(
        method: String,
        nextPeriodStart: String,
        nextPeriodStartLow: String,
        nextPeriodStartHigh: String,
        fertileWindowStart: String?,
        fertileWindowEnd: String?,
        predictedOvulation: String?,
        ovulationConfirmed: Bool,
        confidence: Double,
        cyclesObserved: Int,
        stillLearning: Bool,
        disclaimer: String
    ) {
        self.method = method
        self.nextPeriodStart = nextPeriodStart
        self.nextPeriodStartLow = nextPeriodStartLow
        self.nextPeriodStartHigh = nextPeriodStartHigh
        self.fertileWindowStart = fertileWindowStart
        self.fertileWindowEnd = fertileWindowEnd
        self.predictedOvulation = predictedOvulation
        self.ovulationConfirmed = ovulationConfirmed
        self.confidence = confidence
        self.cyclesObserved = cyclesObserved
        self.stillLearning = stillLearning
        self.disclaimer = disclaimer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "CALENDAR"
        nextPeriodStart = try c.decodeIfPresent(String.self, forKey: .nextPeriodStart) ?? ""
        nextPeriodStartLow = try c.decodeIfPresent(String.self, forKey: .nextPeriodStartLow) ?? ""
        nextPeriodStartHigh = try c.decodeIfPresent(String.self, forKey: .nextPeriodStartHigh) ?? ""
        fertileWindowStart = try c.decodeIfPresent(String.self, forKey: .fertileWindowStart)
        fertileWindowEnd = try c.decodeIfPresent(String.self, forKey: .fertileWindowEnd)
        predictedOvulation = try c.decodeIfPresent(String.self, forKey: .predictedOvulation)
        ovulationConfirmed = try c.decodeIfPresent(Bool.self, forKey: .ovulationConfirmed) ?? false
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        cyclesObserved = try c.decodeIfPresent(Int.self, forKey: .cyclesObserved) ?? 0
        stillLearning = try c.decodeIfPresent(Bool.self, forKey: .stillLearning) ?? true
        disclaimer = try c.decodeIfPresent(String.self, forKey: .disclaimer) ?? ""
    }
}

// MARK: - CalendarDayDTO

public struct CalendarDayDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String {
        date
    }

    public let date: String
    /// Raw phase string — see ``phaseValue``.
    public let phase: String?
    public let isPredictedPeriod: Bool
    public let isFertileWindow: Bool
    public let isPredictedOvulation: Bool
    public let isPeriodLogged: Bool
    public let flow: String?
    public let hasSymptoms: Bool
    public let confidence: Double
    public let basalBodyTempC: Double?
    /// v1.16.15 — the day's BBT reading was excluded from the temperature
    /// evaluation (disturbed). Defaults `false`.
    public let temperatureExcluded: Bool
    public let ovulationTest: String?
    public let cervicalMucus: String?
    /// v1.16.15 — cervix secondary-symptom observations (manual-only).
    public let cervixPosition: String?
    public let cervixFirmness: String?
    public let cervixOpening: String?

    public var phaseValue: CyclePhaseValue? {
        phase.flatMap(CyclePhaseValue.init)
    }

    /// Typed flow accessor — the calendar day's logged flow. Drives the CU-25
    /// (#72) flow-without-period reconciliation check, which needs to know
    /// whether the PRECEDING day already carried bleeding.
    public var flowLevel: CycleFlowLevel? {
        flow.flatMap(CycleFlowLevel.init)
    }

    public var cervixPositionValue: CycleCervixPosition? {
        cervixPosition.flatMap(CycleCervixPosition.init)
    }

    public var cervixFirmnessValue: CycleCervixFirmness? {
        cervixFirmness.flatMap(CycleCervixFirmness.init)
    }

    public var cervixOpeningValue: CycleCervixOpening? {
        cervixOpening.flatMap(CycleCervixOpening.init)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        isPredictedPeriod = try c.decodeIfPresent(Bool.self, forKey: .isPredictedPeriod) ?? false
        isFertileWindow = try c.decodeIfPresent(Bool.self, forKey: .isFertileWindow) ?? false
        isPredictedOvulation = try c.decodeIfPresent(Bool.self, forKey: .isPredictedOvulation) ?? false
        isPeriodLogged = try c.decodeIfPresent(Bool.self, forKey: .isPeriodLogged) ?? false
        flow = try c.decodeIfPresent(String.self, forKey: .flow)
        hasSymptoms = try c.decodeIfPresent(Bool.self, forKey: .hasSymptoms) ?? false
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        basalBodyTempC = try c.decodeIfPresent(Double.self, forKey: .basalBodyTempC)
        temperatureExcluded = try c.decodeIfPresent(Bool.self, forKey: .temperatureExcluded) ?? false
        ovulationTest = try c.decodeIfPresent(String.self, forKey: .ovulationTest)
        cervicalMucus = try c.decodeIfPresent(String.self, forKey: .cervicalMucus)
        cervixPosition = try c.decodeIfPresent(String.self, forKey: .cervixPosition)
        cervixFirmness = try c.decodeIfPresent(String.self, forKey: .cervixFirmness)
        cervixOpening = try c.decodeIfPresent(String.self, forKey: .cervixOpening)
    }
}

// MARK: - CycleProfileDTO

public struct CycleProfileDTO: Codable, Sendable, Equatable, Hashable {
    public let goal: String
    public let cycleTrackingEnabled: Bool
    public let rawChartMode: Bool
    public let predictionEnabled: Bool
    public let discreetNotifications: Bool
    public let sensitiveCategoryEncryption: Bool
    public let typicalCycleLength: Int?
    public let typicalPeriodLength: Int?
    public let lutealPhaseLength: Int?
    /// v1.16.15 — the chosen secondary symptothermal sign (`MUCUS` default or
    /// `CERVIX`). Raw string; see ``secondarySymptomValue``.
    public let secondarySymptom: String
    public let updatedAt: Date?

    public var goalValue: CycleGoal? {
        CycleGoal(rawValue: goal)
    }

    /// Typed secondary-symptom accessor — falls back to ``CycleSecondarySymptom/mucus``
    /// (the server default) when absent or unknown.
    public var secondarySymptomValue: CycleSecondarySymptom {
        CycleSecondarySymptom(rawValue: secondarySymptom) ?? .mucus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? "GENERAL_HEALTH"
        cycleTrackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .cycleTrackingEnabled) ?? false
        rawChartMode = try c.decodeIfPresent(Bool.self, forKey: .rawChartMode) ?? false
        predictionEnabled = try c.decodeIfPresent(Bool.self, forKey: .predictionEnabled) ?? true
        discreetNotifications = try c.decodeIfPresent(Bool.self, forKey: .discreetNotifications) ?? false
        sensitiveCategoryEncryption = try c.decodeIfPresent(Bool.self, forKey: .sensitiveCategoryEncryption) ?? false
        typicalCycleLength = try c.decodeIfPresent(Int.self, forKey: .typicalCycleLength)
        typicalPeriodLength = try c.decodeIfPresent(Int.self, forKey: .typicalPeriodLength)
        lutealPhaseLength = try c.decodeIfPresent(Int.self, forKey: .lutealPhaseLength)
        secondarySymptom = try c.decodeIfPresent(String.self, forKey: .secondarySymptom) ?? "MUCUS"
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

extension CycleProfileDTO {
    /// Re-encode this profile with a new `secondarySymptom` raw value — used for
    /// the optimistic local fold in ``CycleStore/updateSecondarySymptom(_:)``
    /// before the server-merged profile lands. Round-trips through JSON so the
    /// single tolerant decoder stays the only construction path (no memberwise
    /// init to keep in sync). Falls back to `self` if the round-trip ever fails.
    func withSecondarySymptom(_ raw: String) -> CycleProfileDTO {
        guard let data = try? JSONEncoder().encode(SecondarySymptomOverlay(base: self, secondarySymptom: raw)),
              let merged = try? JSONDecoder().decode(CycleProfileDTO.self, from: data) else { return self }
        return merged
    }
}

/// Minimal re-encoder that emits every ``CycleProfileDTO`` field with the
/// `secondarySymptom` overridden — the optimistic-fold helper's wire shape.
private struct SecondarySymptomOverlay: Encodable {
    let base: CycleProfileDTO
    let secondarySymptom: String

    enum CodingKeys: String, CodingKey {
        case goal, cycleTrackingEnabled, rawChartMode, predictionEnabled, discreetNotifications
        case sensitiveCategoryEncryption, typicalCycleLength, typicalPeriodLength, lutealPhaseLength
        case secondarySymptom
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(base.goal, forKey: .goal)
        try c.encode(base.cycleTrackingEnabled, forKey: .cycleTrackingEnabled)
        try c.encode(base.rawChartMode, forKey: .rawChartMode)
        try c.encode(base.predictionEnabled, forKey: .predictionEnabled)
        try c.encode(base.discreetNotifications, forKey: .discreetNotifications)
        try c.encode(base.sensitiveCategoryEncryption, forKey: .sensitiveCategoryEncryption)
        try c.encodeIfPresent(base.typicalCycleLength, forKey: .typicalCycleLength)
        try c.encodeIfPresent(base.typicalPeriodLength, forKey: .typicalPeriodLength)
        try c.encodeIfPresent(base.lutealPhaseLength, forKey: .lutealPhaseLength)
        try c.encode(secondarySymptom, forKey: .secondarySymptom)
    }
}

// MARK: - Envelopes

/// Slim profile block embedded in the calendar envelope (NOT the full
/// `CycleProfileDTO` — see `calendar/route.ts:178`).
public struct CycleCalendarProfile: Codable, Sendable, Equatable, Hashable {
    public let goal: String
    public let rawChartMode: Bool
    public let predictionEnabled: Bool
    public let cyclesObserved: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? "GENERAL_HEALTH"
        rawChartMode = try c.decodeIfPresent(Bool.self, forKey: .rawChartMode) ?? false
        predictionEnabled = try c.decodeIfPresent(Bool.self, forKey: .predictionEnabled) ?? true
        cyclesObserved = try c.decodeIfPresent(Int.self, forKey: .cyclesObserved) ?? 0
    }
}

/// `GET /api/cycle/calendar` → `{ profile, prediction, verdict, days, meta }`.
public struct CycleCalendarResponse: Codable, Sendable, Equatable {
    public let profile: CycleCalendarProfile?
    public let prediction: CyclePredictionDTO?
    /// **Z1 (#72) — the resolved cycle verdict (server ≥ v1.35.2).** Non-optional
    /// on the wire; optional here only so a self-hosted server that predates
    /// v1.35.2 still decodes. Where it is missing the app makes NO state claim
    /// rather than reconstructing one (see ``CycleVerdictDTO``).
    public let verdict: CycleVerdictDTO?
    public let days: [CalendarDayDTO]
    /// `meta.generatedAt` — when the SERVER built this envelope. Anchors the
    /// "as of" stamp on a stored verdict; the receive time would overstate
    /// freshness because the envelope can be served from the persistent cache.
    public let generatedAt: Date?

    private enum MetaKeys: String, CodingKey {
        case generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(CycleCalendarProfile.self, forKey: .profile)
        prediction = try c.decodeIfPresent(CyclePredictionDTO.self, forKey: .prediction)
        verdict = try c.decodeIfPresent(CycleVerdictDTO.self, forKey: .verdict)
        days = try c.decodeIfPresent([CalendarDayDTO].self, forKey: .days) ?? []
        let meta = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        generatedAt = try meta?.decodeIfPresent(Date.self, forKey: .generatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encodeIfPresent(prediction, forKey: .prediction)
        try c.encodeIfPresent(verdict, forKey: .verdict)
        try c.encode(days, forKey: .days)
        if let generatedAt {
            var meta = c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
            try meta.encode(generatedAt, forKey: .generatedAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case profile, prediction, verdict, days, meta
    }
}

public struct CycleStatsDTO: Codable, Sendable, Equatable, Hashable {
    public let avgLengthDays: Int?
    public let lengthVariabilityDays: Double?
    public let avgPeriodLengthDays: Int?
    public let regularity: String

    public var regularityValue: CycleRegularity? {
        CycleRegularity(rawValue: regularity)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avgLengthDays = try c.decodeIfPresent(Int.self, forKey: .avgLengthDays)
        lengthVariabilityDays = try c.decodeIfPresent(Double.self, forKey: .lengthVariabilityDays)
        avgPeriodLengthDays = try c.decodeIfPresent(Int.self, forKey: .avgPeriodLengthDays)
        regularity = try c.decodeIfPresent(String.self, forKey: .regularity) ?? "LEARNING"
    }
}

/// `GET /api/cycle/cycles` → `{ cycles, stats }`.
public struct CycleListResponse: Codable, Sendable, Equatable {
    public let cycles: [MenstrualCycleDTO]
    public let stats: CycleStatsDTO?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cycles = try c.decodeIfPresent([MenstrualCycleDTO].self, forKey: .cycles) ?? []
        stats = try c.decodeIfPresent(CycleStatsDTO.self, forKey: .stats)
    }
}

// MARK: - Bulk drain results

public enum CycleBulkEntryStatus: String, Codable, Sendable, Equatable {
    case inserted, duplicate, updated, skipped
}

public struct CycleBulkEntryResult: Codable, Sendable, Equatable {
    public let index: Int
    public let status: CycleBulkEntryStatus
    public let id: String?
    public let externalId: String?
    public let reason: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? "skipped"
        status = CycleBulkEntryStatus(rawValue: raw) ?? .skipped
        id = try c.decodeIfPresent(String.self, forKey: .id)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// `POST /api/cycle/day-logs/bulk` → `{ entries: [CycleBulkEntryResult] }`.
public struct CycleBulkResponse: Codable, Sendable, Equatable {
    public let entries: [CycleBulkEntryResult]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([CycleBulkEntryResult].self, forKey: .entries) ?? []
    }
}

/// `DELETE /api/cycle/all` → `{ purged, dayLogs, customSymptoms, predictions,
/// cycles, auditRows, pushRows }` — the one-tap hard purge (server v1.16).
/// Counts decode tolerantly (0 when absent) so a server that adds/renames a
/// counter never breaks the purge confirmation.
public struct CyclePurgeResponse: Decodable, Sendable, Equatable {
    public let purged: Bool
    public let dayLogs: Int
    public let customSymptoms: Int
    public let predictions: Int
    public let cycles: Int

    private enum CodingKeys: String, CodingKey {
        case purged, dayLogs, customSymptoms, predictions, cycles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purged = try c.decodeIfPresent(Bool.self, forKey: .purged) ?? false
        dayLogs = try c.decodeIfPresent(Int.self, forKey: .dayLogs) ?? 0
        customSymptoms = try c.decodeIfPresent(Int.self, forKey: .customSymptoms) ?? 0
        predictions = try c.decodeIfPresent(Int.self, forKey: .predictions) ?? 0
        cycles = try c.decodeIfPresent(Int.self, forKey: .cycles) ?? 0
    }
}
