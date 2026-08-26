import Foundation

// MARK: - ComprehensiveDigest

//
// Mirrors the production envelope shape emitted by `GET /api/insights/comprehensive`
// (server source: `src/app/api/insights/comprehensive/route.ts:377-400`).
//
// **Background (A8 §1):** Until v0.3.0 the iOS decoder discarded everything except
// `recommendations` — `AIInsightResponse` was modelled against a Zod schema the
// production route does not emit. The production route emits a *metric-digest*
// envelope: per-metric summaries, BMI + classification, BP windows + ESH-2023
// classification, four correlation matrices, mood summary, alerts, data-span.
//
// This DTO captures the **digest** half of that envelope. The AI-shaped half
// (`summary`, `recommendations`, `dailyBriefing`, …) ships from a separate
// endpoint — `POST /api/insights/generate` — and rides on
// `AIInsightResponse`.
//
// **Decode-tolerance:** every field is Optional. Server sends `null` when
// the user does not yet have enough data for a given block (e.g. correlations
// gated at n < 5, BP-in-target gated on having `bpTargets`). The UI hides
// each section's card per the empty-state strategy.
//
// All structs are `Sendable` + value-typed so they cross actor boundaries safely.

/// Full envelope returned by `GET /api/insights/comprehensive`. Every field
/// is Optional / nullable-tolerant per Stream Alpha's pattern.
public struct ComprehensiveDigest: Codable, Sendable, Hashable {
    public let summaries: [String: MetricSummary]?
    public let bmi: Double?
    public let bmiClassification: BMIClassification?
    public let bpClassification: BPClassification?
    public let bpPctInTarget: Int?
    public let bpTargets: BPTargets?
    public let weightBpCorrelation: CorrelationStat?
    public let scatterData: [WeightBPPoint]?
    public let bpMedicationCorrelation: BPMedicationCorrelation?
    public let bpMedicationScatterData: [BPCompliancePoint]?
    public let moodSummary: MetricSummary?
    public let moodBpCorrelation: CorrelationStat?
    public let moodBpScatterData: [MoodBPPoint]?
    public let moodWeightCorrelation: CorrelationStat?
    public let moodWeightScatterData: [MoodWeightPoint]?
    public let moodPulseCorrelation: CorrelationStat?
    public let moodPulseScatterData: [MoodPulsePoint]?
    public let medications: [MedicationComplianceSummary]?
    public let alerts: [HealthAlert]?
    public let hasProvider: Bool?
    public let dataSpanDays: Int?
    public let totalMeasurements: Int?

    public init(
        summaries: [String: MetricSummary]? = nil,
        bmi: Double? = nil,
        bmiClassification: BMIClassification? = nil,
        bpClassification: BPClassification? = nil,
        bpPctInTarget: Int? = nil,
        bpTargets: BPTargets? = nil,
        weightBpCorrelation: CorrelationStat? = nil,
        scatterData: [WeightBPPoint]? = nil,
        bpMedicationCorrelation: BPMedicationCorrelation? = nil,
        bpMedicationScatterData: [BPCompliancePoint]? = nil,
        moodSummary: MetricSummary? = nil,
        moodBpCorrelation: CorrelationStat? = nil,
        moodBpScatterData: [MoodBPPoint]? = nil,
        moodWeightCorrelation: CorrelationStat? = nil,
        moodWeightScatterData: [MoodWeightPoint]? = nil,
        moodPulseCorrelation: CorrelationStat? = nil,
        moodPulseScatterData: [MoodPulsePoint]? = nil,
        medications: [MedicationComplianceSummary]? = nil,
        alerts: [HealthAlert]? = nil,
        hasProvider: Bool? = nil,
        dataSpanDays: Int? = nil,
        totalMeasurements: Int? = nil
    ) {
        self.summaries = summaries
        self.bmi = bmi
        self.bmiClassification = bmiClassification
        self.bpClassification = bpClassification
        self.bpPctInTarget = bpPctInTarget
        self.bpTargets = bpTargets
        self.weightBpCorrelation = weightBpCorrelation
        self.scatterData = scatterData
        self.bpMedicationCorrelation = bpMedicationCorrelation
        self.bpMedicationScatterData = bpMedicationScatterData
        self.moodSummary = moodSummary
        self.moodBpCorrelation = moodBpCorrelation
        self.moodBpScatterData = moodBpScatterData
        self.moodWeightCorrelation = moodWeightCorrelation
        self.moodWeightScatterData = moodWeightScatterData
        self.moodPulseCorrelation = moodPulseCorrelation
        self.moodPulseScatterData = moodPulseScatterData
        self.medications = medications
        self.alerts = alerts
        self.hasProvider = hasProvider
        self.dataSpanDays = dataSpanDays
        self.totalMeasurements = totalMeasurements
    }
}

// MARK: - MetricSummary

//
// Per-metric trends summary from `src/lib/analytics/trends.ts:summarize()`.

public struct MetricSummary: Codable, Sendable, Hashable {
    public let count: Int?
    public let latest: Double?
    public let min: Double?
    public let max: Double?
    public let mean: Double?
    public let avg7: Double?
    public let avg30: Double?
    public let slope7: TrendSlope?
    public let slope30: TrendSlope?
    public let slope90: TrendSlope?
    public let anomalyCount: Int?
    public let avg30LastMonth: Double?
    public let avg30LastYear: Double?

    public init(
        count: Int? = nil,
        latest: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        mean: Double? = nil,
        avg7: Double? = nil,
        avg30: Double? = nil,
        slope7: TrendSlope? = nil,
        slope30: TrendSlope? = nil,
        slope90: TrendSlope? = nil,
        anomalyCount: Int? = nil,
        avg30LastMonth: Double? = nil,
        avg30LastYear: Double? = nil
    ) {
        self.count = count
        self.latest = latest
        self.min = min
        self.max = max
        self.mean = mean
        self.avg7 = avg7
        self.avg30 = avg30
        self.slope7 = slope7
        self.slope30 = slope30
        self.slope90 = slope90
        self.anomalyCount = anomalyCount
        self.avg30LastMonth = avg30LastMonth
        self.avg30LastYear = avg30LastYear
    }
}

public struct TrendSlope: Codable, Sendable, Hashable {
    public let slope: Double?
    public let direction: TrendDirection?
    public let confidence: Double?

    public init(slope: Double? = nil, direction: TrendDirection? = nil, confidence: Double? = nil) {
        self.slope = slope
        self.direction = direction
        self.confidence = confidence
    }
}

public enum TrendDirection: String, Codable, Sendable {
    case up
    case down
    case stable

    /// Tolerant decoder — unknown tokens decode to `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown TrendDirection: \(raw)"
            )
        }
        self = value
    }
}

// MARK: - BMI classification

//
// Server source: `src/lib/analytics/classifications.ts:classifyBMI()`.
// Wire is lowercase + underscore — WHO categories.

public enum BMIClassification: String, Codable, Sendable, CaseIterable {
    case underweight
    case normal
    case overweight
    case obeseGradeI = "obese_grade_i"
    case obeseGradeII = "obese_grade_ii"
    case obeseGradeIII = "obese_grade_iii"
    /// v0.7.0 W-API-RENDER — token the contract doesn't recognise. The
    /// prior decoder coalesced any unknown wire token into `.normal`,
    /// which is **medically misleading** (an unrecognised category is not
    /// evidence of a normal BMI). We now keep the value distinct so the UI
    /// renders an honest "Unbekannt" / "Unknown" chip instead of a false
    /// green "Normalgewicht" badge.
    case unknown

    /// Tolerant decoder — server wire actually emits `{category, color, severity}`
    /// objects in some routes and raw string in others. We accept BOTH shapes,
    /// favouring the string path. Object path reads `category` and normalises.
    public init(from decoder: Decoder) throws {
        // Try string first.
        if let container = try? decoder.singleValueContainer() {
            if let raw = try? container.decode(String.self) {
                self = Self.normalise(raw)
                return
            }
        }
        // Object fallback — `{ category, color, severity }`.
        struct Object: Decodable { let category: String? }
        let object = try? Object(from: decoder)
        guard let category = object?.category else {
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "BMIClassification expects a string or {category} object"
            )
        }
        self = Self.normalise(category)
    }

    private static func normalise(_ raw: String) -> BMIClassification {
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "_")
        switch key {
        case "underweight": return .underweight
        case "normal": return .normal
        case "overweight": return .overweight
        case "obese_grade_i", "obesity_grade_i", "obesity_grade_1": return .obeseGradeI
        case "obese_grade_ii", "obesity_grade_ii", "obesity_grade_2": return .obeseGradeII
        case "obese_grade_iii", "obesity_grade_iii", "obesity_grade_3": return .obeseGradeIII
        // v0.7.0 W-API-RENDER — never silently masquerade an unrecognised
        // token as "normal". A new WHO sub-band or a server typo surfaces
        // as `.unknown` so the operator sees "Unbekannt" rather than a
        // reassuring-but-false classification.
        default: return .unknown
        }
    }
}

// MARK: - BP classification

//
// Server source: `src/lib/analytics/classifications.ts:classifyBP()`.
// ESH 2023 categories. Same dual-shape decode as BMI.

public enum BPClassification: String, Codable, Sendable, CaseIterable {
    case optimal
    case normal
    case highNormal = "high_normal"
    case hypertensionGrade1 = "hypertension_grade_1"
    case hypertensionGrade2 = "hypertension_grade_2"
    case hypertensionGrade3 = "hypertension_grade_3"
    /// v0.7.0 W-API-RENDER — unrecognised ESH token. See the matching
    /// `BMIClassification.unknown` rationale: coalescing an unknown blood-
    /// pressure category into `.normal` is the dangerous default for a
    /// hypertension surface. `.unknown` renders "Unbekannt" / "Unknown".
    case unknown

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let raw = try? container.decode(String.self) {
                self = Self.normalise(raw)
                return
            }
        }
        struct Object: Decodable { let category: String? }
        let object = try? Object(from: decoder)
        guard let category = object?.category else {
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "BPClassification expects a string or {category} object"
            )
        }
        self = Self.normalise(category)
    }

    private static func normalise(_ raw: String) -> BPClassification {
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        switch key {
        case "optimal": return .optimal
        case "normal": return .normal
        case "high_normal", "elevated": return .highNormal
        case "hypertension_grade_1", "hypertension_grade_i": return .hypertensionGrade1
        case "hypertension_grade_2", "hypertension_grade_ii": return .hypertensionGrade2
        case "hypertension_grade_3", "hypertension_grade_iii": return .hypertensionGrade3
        // v0.7.0 W-API-RENDER — unrecognised token surfaces as `.unknown`,
        // never a false-reassuring `.normal`.
        default: return .unknown
        }
    }
}

// MARK: - BP targets (ESH 2023)

public struct BPTargets: Codable, Sendable, Hashable {
    public let sysLow: Int?
    public let sysHigh: Int?
    public let diaLow: Int?
    public let diaHigh: Int?

    public init(sysLow: Int? = nil, sysHigh: Int? = nil, diaLow: Int? = nil, diaHigh: Int? = nil) {
        self.sysLow = sysLow
        self.sysHigh = sysHigh
        self.diaLow = diaLow
        self.diaHigh = diaHigh
    }
}

// MARK: - Correlations

//
// Server source: `src/lib/analytics/correlations.ts:pearsonCorrelation()`.
// `r ∈ [-1, 1]`, `strength` enum, `n` ≥ minPairs (default 5).

public struct CorrelationStat: Codable, Sendable, Hashable {
    /// Pearson coefficient. Server rounds to 3 decimal places.
    public let r: Double
    /// Server-emitted strength bucket. Use as locale-friendly label.
    public let strength: CorrelationStrength?
    /// Number of pairs used.
    public let n: Int

    public init(r: Double, strength: CorrelationStrength? = nil, n: Int) {
        self.r = r
        self.strength = strength
        self.n = n
    }
}

/// Server-emitted strength tokens (German enum literals — `src/lib/analytics/correlations.ts:100-103`).
public enum CorrelationStrength: String, Codable, Sendable {
    case stark
    case moderat
    case schwach
    case keine

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        guard let value = Self(rawValue: raw) else {
            // Permissive — unknown tokens fall back to .keine ("no signal").
            self = .keine
            return
        }
        self = value
    }
}

/// BP × Medication-Compliance correlation extends `CorrelationStat` with the
/// number of BP medications in scope (server emits this alongside r/n).
public struct BPMedicationCorrelation: Codable, Sendable, Hashable {
    public let r: Double
    public let strength: CorrelationStrength?
    public let n: Int
    public let medicationCount: Int

    public init(r: Double, strength: CorrelationStrength? = nil, n: Int, medicationCount: Int) {
        self.r = r
        self.strength = strength
        self.n = n
        self.medicationCount = medicationCount
    }
}

// MARK: - Scatter point shapes

//
// Server emits a tailored shape per correlation pair (see `route.ts:139-207`).
// Each is a flat object — we capture both numeric axes as `Double`.

public struct WeightBPPoint: Codable, Sendable, Hashable {
    public let weight: Double
    public let sysBP: Double

    public init(weight: Double, sysBP: Double) {
        self.weight = weight
        self.sysBP = sysBP
    }
}

public struct BPCompliancePoint: Codable, Sendable, Hashable {
    /// 0..100, server already multiplied by 100.
    public let continuityPct: Double
    public let sysBP: Double

    public init(continuityPct: Double, sysBP: Double) {
        self.continuityPct = continuityPct
        self.sysBP = sysBP
    }
}

public struct MoodBPPoint: Codable, Sendable, Hashable {
    public let mood: Double
    public let sysBP: Double

    public init(mood: Double, sysBP: Double) {
        self.mood = mood
        self.sysBP = sysBP
    }
}

public struct MoodWeightPoint: Codable, Sendable, Hashable {
    public let mood: Double
    public let weight: Double

    public init(mood: Double, weight: Double) {
        self.mood = mood
        self.weight = weight
    }
}

public struct MoodPulsePoint: Codable, Sendable, Hashable {
    public let mood: Double
    public let pulse: Double

    public init(mood: Double, pulse: Double) {
        self.mood = mood
        self.pulse = pulse
    }
}

// MARK: - Medication compliance summary

//
// Server source: `route.ts:259-270`. Per-active-medication row inside
// `comprehensive.medications[]`.

public struct MedicationComplianceSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let dose: String?
    /// Category enum — wire is `BLOOD_PRESSURE`, `GLP1`, `OTHER`, …
    /// kept as raw string so a new server category doesn't break decoding.
    public let category: String?
    public let compliance7: Double?
    public let compliance30: Double?
    public let streak: Int?
    public let taken7: Int?
    public let skipped7: Int?
    public let missed7: Int?

    public init(
        id: String,
        name: String,
        dose: String? = nil,
        category: String? = nil,
        compliance7: Double? = nil,
        compliance30: Double? = nil,
        streak: Int? = nil,
        taken7: Int? = nil,
        skipped7: Int? = nil,
        missed7: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.category = category
        self.compliance7 = compliance7
        self.compliance30 = compliance30
        self.streak = streak
        self.taken7 = taken7
        self.skipped7 = skipped7
        self.missed7 = missed7
    }
}

// MARK: - Health alerts

//
// Server source: `src/lib/analytics/classifications.ts:generateAlerts()`.

public struct HealthAlert: Codable, Sendable, Hashable, Identifiable {
    public var id: String {
        "\(level.rawValue)-\(title.hashValue)"
    }

    public let level: AlertLevel
    public let title: String
    public let message: String

    public init(level: AlertLevel, title: String, message: String) {
        self.level = level
        self.title = title
        self.message = message
    }
}

public enum AlertLevel: String, Codable, Sendable {
    case success
    case info
    case warning
    case danger

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        self = Self(rawValue: raw) ?? .info
    }
}

// MARK: - Convenience

public extension ComprehensiveDigest {
    /// Returns `nil` when every field is missing. Used by the `AIInsightResponse`
    /// decoder so callers can switch on `.digest == nil` instead of inspecting
    /// individual fields.
    var nonEmpty: ComprehensiveDigest? {
        let hasAny = summaries?.isEmpty == false
            || bmi != nil
            || bmiClassification != nil
            || bpClassification != nil
            || bpPctInTarget != nil
            || bpTargets != nil
            || weightBpCorrelation != nil
            || (scatterData?.isEmpty == false)
            || bpMedicationCorrelation != nil
            || (bpMedicationScatterData?.isEmpty == false)
            || moodSummary != nil
            || moodBpCorrelation != nil
            || moodWeightCorrelation != nil
            || moodPulseCorrelation != nil
            || (medications?.isEmpty == false)
            || (alerts?.isEmpty == false)
            || hasProvider != nil
            || dataSpanDays != nil
            || totalMeasurements != nil
        return hasAny ? self : nil
    }
}
