import Foundation

public enum CycleInsightDisplay: Sendable, Equatable {
    case hours, steps, bpm, milliseconds, kilograms, celsius, glucose, mood, unknown
}

public enum CycleInsightConfidence: Sendable, Equatable {
    case low, medium, high, unknown
}

public struct CyclePhaseMetricRow: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let metricKey: String
    public let display: String
    public let lutealDays: Int
    public let follicularDays: Int
    public let lutealAvg: Double
    public let follicularAvg: Double
    public let delta: Double
    public let pValue: Double
    public let qValue: Double
    public let confidence: String

    public var id: String {
        metricKey
    }

    public var displayValue: CycleInsightDisplay {
        switch display {
        case "hours": .hours
        case "steps": .steps
        case "bpm": .bpm
        case "ms": .milliseconds
        case "kg": .kilograms
        case "celsius": .celsius
        case "glucose": .glucose
        case "mood": .mood
        default: .unknown
        }
    }

    public var confidenceValue: CycleInsightConfidence {
        switch confidence {
        case "low": .low
        case "medium": .medium
        case "high": .high
        default: .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metricKey = try c.decodeIfPresent(String.self, forKey: .metricKey) ?? ""
        display = try c.decodeIfPresent(String.self, forKey: .display) ?? "unknown"
        lutealDays = try c.decodeIfPresent(Int.self, forKey: .lutealDays) ?? 0
        follicularDays = try c.decodeIfPresent(Int.self, forKey: .follicularDays) ?? 0
        lutealAvg = try c.decodeIfPresent(Double.self, forKey: .lutealAvg) ?? 0
        follicularAvg = try c.decodeIfPresent(Double.self, forKey: .follicularAvg) ?? 0
        delta = try c.decodeIfPresent(Double.self, forKey: .delta) ?? 0
        pValue = try c.decodeIfPresent(Double.self, forKey: .pValue) ?? 1
        qValue = try c.decodeIfPresent(Double.self, forKey: .qValue) ?? 1
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? "unknown"
    }
}

public struct CycleSymptomPhaseCounts: Codable, Sendable, Equatable, Hashable {
    public let menstrual: Int
    public let follicular: Int
    public let ovulatory: Int
    public let luteal: Int

    public init(menstrual: Int = 0, follicular: Int = 0, ovulatory: Int = 0, luteal: Int = 0) {
        self.menstrual = menstrual
        self.follicular = follicular
        self.ovulatory = ovulatory
        self.luteal = luteal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menstrual = try c.decodeIfPresent(Int.self, forKey: .menstrual) ?? 0
        follicular = try c.decodeIfPresent(Int.self, forKey: .follicular) ?? 0
        ovulatory = try c.decodeIfPresent(Int.self, forKey: .ovulatory) ?? 0
        luteal = try c.decodeIfPresent(Int.self, forKey: .luteal) ?? 0
    }

    public subscript(phase: CyclePhaseValue) -> Int {
        switch phase {
        case .menstrual: menstrual
        case .follicular: follicular
        case .ovulatory: ovulatory
        case .luteal: luteal
        }
    }

    private enum CodingKeys: String, CodingKey {
        case menstrual = "MENSTRUAL"
        case follicular = "FOLLICULAR"
        case ovulatory = "OVULATORY"
        case luteal = "LUTEAL"
    }
}

public struct CycleSymptomPhasePattern: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let symptomKey: String
    public let counts: CycleSymptomPhaseCounts
    public let total: Int
    public let topPhase: String
    public let topShare: Double

    public var id: String {
        symptomKey
    }

    public var topPhaseValue: CyclePhaseValue? {
        CyclePhaseValue(rawValue: topPhase)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symptomKey = try c.decodeIfPresent(String.self, forKey: .symptomKey) ?? ""
        counts = try c.decodeIfPresent(CycleSymptomPhaseCounts.self, forKey: .counts) ?? CycleSymptomPhaseCounts()
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        topPhase = try c.decodeIfPresent(String.self, forKey: .topPhase) ?? ""
        topShare = try c.decodeIfPresent(Double.self, forKey: .topShare) ?? 0
    }
}

public struct CycleInsightsContrast: Codable, Sendable, Equatable, Hashable {
    public let high: String
    public let low: String

    public init(high: String = "LUTEAL", low: String = "FOLLICULAR") {
        self.high = high
        self.low = low
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        high = try c.decodeIfPresent(String.self, forKey: .high) ?? "LUTEAL"
        low = try c.decodeIfPresent(String.self, forKey: .low) ?? "FOLLICULAR"
    }
}

public struct CycleInsightsDTO: Codable, Sendable, Equatable {
    public let rows: [CyclePhaseMetricRow]
    public let headline: CyclePhaseMetricRow?
    public let lagged: CorrelationDiscoveryResponse
    public let symptomPatterns: [CycleSymptomPhasePattern]
    public let contrast: CycleInsightsContrast
    public let windowDays: Int
    public let cyclesObserved: Int

    public var isLearning: Bool {
        rows.isEmpty && symptomPatterns.isEmpty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent([CyclePhaseMetricRow].self, forKey: .rows) ?? []
        headline = try c.decodeIfPresent(CyclePhaseMetricRow.self, forKey: .headline)
        lagged = try c.decodeIfPresent(CorrelationDiscoveryResponse.self, forKey: .lagged)
            ?? CorrelationDiscoveryResponse(discovered: [], pairsTested: 0, fdrQ: 0.1, minPairs: 0)
        symptomPatterns = try c.decodeIfPresent([CycleSymptomPhasePattern].self, forKey: .symptomPatterns) ?? []
        contrast = try c.decodeIfPresent(CycleInsightsContrast.self, forKey: .contrast) ?? CycleInsightsContrast()
        windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 365
        cyclesObserved = try c.decodeIfPresent(Int.self, forKey: .cyclesObserved) ?? 0
    }
}
