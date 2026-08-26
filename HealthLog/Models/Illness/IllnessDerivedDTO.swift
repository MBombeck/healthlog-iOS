import Foundation

// Server-COMPUTED, render-only `Derived<T>` DTOs for the illness surface
// (v1.18.1 §B). Split from `IllnessDTO.swift` for file-length discipline — pure
// move, no behaviour change. These carry the per-episode correlation
// (`IllnessCorrelationDTO`) and the cross-episode insights summary
// (`IllnessInsightsDTO`). iOS pattern-matches `status` and renders the findings;
// it NEVER recomputes a baseline, a deviation, or a recovery gap.

// MARK: - Derived correlation (server-computed; render-only)

/// `{ ok | insufficient }` — the coverage-gated `Derived<T>` status. `ok`
/// carries a `value`; `insufficient` carries coverage + a reason and a null
/// `value` (the surface renders "still learning", never a fabricated number).
/// Tolerant decode falls back to ``insufficient`` so an unknown future status
/// never paints a misleading "ok".
public enum IllnessDerivedStatus: String, Codable, Sendable, Equatable {
    case ok
    case insufficient

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IllnessDerivedStatus(rawValue: raw) ?? .insufficient
    }
}

/// `{ above | below }` — the direction of a vital's deviation from baseline.
public enum IllnessDeviationDirection: String, Codable, Sendable, Equatable {
    case above
    case below

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IllnessDeviationDirection(rawValue: raw) ?? .above
    }
}

/// One vital's deviation finding on a day: signed deviation in robust-SD units
/// from the user's OWN baseline (median ± MAD), the direction, and whether the
/// move is illness-adverse for that metric. **Server-computed — render as-is.**
public struct IllnessVitalDeviation: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// Vital type string (e.g. `RESTING_HEART_RATE`, `RESPIRATORY_RATE`,
    /// `BODY_TEMPERATURE`, `HEART_RATE_VARIABILITY`). Kept as a raw string for
    /// forward-compat; the UI maps known types to a localized label.
    public let type: String
    /// `YYYY-MM-DD` the deviation was observed.
    public let day: String
    public let value: Double
    public let baselineCenter: Double
    /// Signed deviation in robust-SD (MAD) units.
    public let deviationSd: Double
    public let direction: IllnessDeviationDirection
    public let adverse: Bool

    public var id: String {
        "\(type)|\(day)"
    }

    public init(
        type: String,
        day: String,
        value: Double,
        baselineCenter: Double,
        deviationSd: Double,
        direction: IllnessDeviationDirection,
        adverse: Bool
    ) {
        self.type = type
        self.day = day
        self.value = value
        self.baselineCenter = baselineCenter
        self.deviationSd = deviationSd
        self.direction = direction
        self.adverse = adverse
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        baselineCenter = try c.decodeIfPresent(Double.self, forKey: .baselineCenter) ?? 0
        deviationSd = try c.decodeIfPresent(Double.self, forKey: .deviationSd) ?? 0
        direction = try c.decodeIfPresent(IllnessDeviationDirection.self, forKey: .direction) ?? .above
        adverse = try c.decodeIfPresent(Bool.self, forKey: .adverse) ?? false
    }
}

/// A vital's physiological return: the first day it re-entered its band AND
/// held, and the signed gap (days) from the felt-better marker (positive = the
/// body lagged the feeling). **Server-computed — render as-is.**
public struct IllnessVitalReturn: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let type: String
    /// `YYYY-MM-DD` or `nil` if the vital had not returned to band yet.
    public let returnedDay: String?
    /// Signed gap in days from the felt-better marker (positive = body lagged).
    public let gapDays: Double?

    public var id: String {
        type
    }

    public init(type: String, returnedDay: String?, gapDays: Double?) {
        self.type = type
        self.returnedDay = returnedDay
        self.gapDays = gapDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        returnedDay = try c.decodeIfPresent(String.self, forKey: .returnedDay)
        gapDays = try c.decodeIfPresent(Double.self, forKey: .gapDays)
    }
}

/// A retrospective red-flag escalation (sustained low SpO2 or sustained fever)
/// against absolute clinical floors. **Copy must escalate ("seek care if this
/// recurs"), never reassure.** `reason` kept tolerant for forward-compat.
public struct IllnessRedFlag: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let type: String
    /// `{ sustained_low_spo2 | sustained_fever }` — raw for forward-compat.
    public let reason: String
    public let worstValue: Double
    public let days: Int

    public var id: String {
        "\(type)|\(reason)"
    }

    public init(type: String, reason: String, worstValue: Double, days: Int) {
        self.type = type
        self.reason = reason
        self.worstValue = worstValue
        self.days = days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        worstValue = try c.decodeIfPresent(Double.self, forKey: .worstValue) ?? 0
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 0
    }
}

/// A neutral sleep-as-context observation (v1.21.0): the user's median asleep
/// minutes over the well baseline vs the mean over the episode window, and the
/// signed delta (positive = slept more than usual). A pure OBSERVATION surfaced
/// alongside the gap — **NEVER a recovery return and NEVER part of the headline
/// recovery-gap.** The server withholds it (the field is `nil`) on thin sleep
/// data or a sub-floor delta. **Server-computed — render as-is.**
public struct IllnessSleepContext: Codable, Sendable, Equatable, Hashable {
    public let baselineMeanMinutes: Double
    public let episodeMeanMinutes: Double
    /// Signed delta in minutes (positive = slept more than usual during the episode).
    public let deltaMinutes: Double
    public let nightsCounted: Int

    public init(
        baselineMeanMinutes: Double,
        episodeMeanMinutes: Double,
        deltaMinutes: Double,
        nightsCounted: Int
    ) {
        self.baselineMeanMinutes = baselineMeanMinutes
        self.episodeMeanMinutes = episodeMeanMinutes
        self.deltaMinutes = deltaMinutes
        self.nightsCounted = nightsCounted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baselineMeanMinutes = try c.decodeIfPresent(Double.self, forKey: .baselineMeanMinutes) ?? 0
        episodeMeanMinutes = try c.decodeIfPresent(Double.self, forKey: .episodeMeanMinutes) ?? 0
        deltaMinutes = try c.decodeIfPresent(Double.self, forKey: .deltaMinutes) ?? 0
        nightsCounted = try c.decodeIfPresent(Int.self, forKey: .nightsCounted) ?? 0
    }
}

/// The retrospective correlation findings for one episode: pre-onset anomaly
/// scan, nadir, per-vital physiological returns, the headline recovery-gap
/// (median of per-vital gaps), the driving metric (`gapDriverType`), any red
/// flags, and an optional sleep-as-context observation (`sleepContext`, never
/// in the gap). **Server-computed.**
public struct IllnessCorrelationValue: Codable, Sendable, Equatable, Hashable {
    public let episodeId: String
    public let preOnset: [IllnessVitalDeviation]
    public let nadir: [IllnessVitalDeviation]
    public let returns: [IllnessVitalReturn]
    public let recoveryGapDays: Double?
    /// `YYYY-MM-DD` the user marked feeling better, or `nil`.
    public let feltBetterDay: String?
    /// The metric whose physiological return dominated the recovery gap — a
    /// `MeasurementType` string (e.g. `RESTING_HEART_RATE`), `FUNCTIONAL_IMPACT`
    /// for the user-logged symptom-burden track, or `nil` when no adverse return
    /// drove the gap. v1.21.0. Render-only; the UI names it.
    public let gapDriverType: String?
    public let redFlags: [IllnessRedFlag]
    /// Neutral sleep-as-context observation, or `nil` when the server withheld
    /// it (thin data / sub-floor delta). v1.21.0. **Never part of the gap.**
    public let sleepContext: IllnessSleepContext?

    public init(
        episodeId: String,
        preOnset: [IllnessVitalDeviation],
        nadir: [IllnessVitalDeviation],
        returns: [IllnessVitalReturn],
        recoveryGapDays: Double?,
        feltBetterDay: String?,
        gapDriverType: String?,
        redFlags: [IllnessRedFlag],
        sleepContext: IllnessSleepContext?
    ) {
        self.episodeId = episodeId
        self.preOnset = preOnset
        self.nadir = nadir
        self.returns = returns
        self.recoveryGapDays = recoveryGapDays
        self.feltBetterDay = feltBetterDay
        self.gapDriverType = gapDriverType
        self.redFlags = redFlags
        self.sleepContext = sleepContext
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId) ?? ""
        preOnset = try c.decodeIfPresent([IllnessVitalDeviation].self, forKey: .preOnset) ?? []
        nadir = try c.decodeIfPresent([IllnessVitalDeviation].self, forKey: .nadir) ?? []
        returns = try c.decodeIfPresent([IllnessVitalReturn].self, forKey: .returns) ?? []
        recoveryGapDays = try c.decodeIfPresent(Double.self, forKey: .recoveryGapDays)
        feltBetterDay = try c.decodeIfPresent(String.self, forKey: .feltBetterDay)
        gapDriverType = try c.decodeIfPresent(String.self, forKey: .gapDriverType)
        redFlags = try c.decodeIfPresent([IllnessRedFlag].self, forKey: .redFlags) ?? []
        sleepContext = try c.decodeIfPresent(IllnessSleepContext.self, forKey: .sleepContext)
    }
}

/// Coverage detail for a `Derived<T>` — how much of the required input was
/// present, the trailing history depth, and which inputs are missing.
public struct IllnessCoverage: Codable, Sendable, Equatable, Hashable {
    public let requiredInputs: Int
    public let presentInputs: Int
    public let historyDays: Int
    public let missing: [String]

    public init(requiredInputs: Int, presentInputs: Int, historyDays: Int, missing: [String]) {
        self.requiredInputs = requiredInputs
        self.presentInputs = presentInputs
        self.historyDays = historyDays
        self.missing = missing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requiredInputs = try c.decodeIfPresent(Int.self, forKey: .requiredInputs) ?? 0
        presentInputs = try c.decodeIfPresent(Int.self, forKey: .presentInputs) ?? 0
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? 0
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
    }
}

/// Confidence band on a `Derived<T>` (`{ score, band }`), or absent.
public struct IllnessConfidence: Codable, Sendable, Equatable, Hashable {
    public let score: Double
    public let band: String

    public init(score: Double, band: String) {
        self.score = score
        self.band = band
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        band = try c.decodeIfPresent(String.self, forKey: .band) ?? ""
    }
}

/// Provenance trail on a `Derived<T>` — the inputs, source, window, and compute
/// timestamp. Render-only.
public struct IllnessProvenance: Codable, Sendable, Equatable, Hashable {
    public let inputs: [String]
    public let source: String
    public let windowDays: Int
    public let computedAt: String

    public init(inputs: [String], source: String, windowDays: Int, computedAt: String) {
        self.inputs = inputs
        self.source = source
        self.windowDays = windowDays
        self.computedAt = computedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 0
        computedAt = try c.decodeIfPresent(String.self, forKey: .computedAt) ?? ""
    }
}

/// `GET /api/illness/episodes/{id}/correlation` → the coverage-gated
/// `Derived<T>` wire shape (`IllnessCorrelationResponse`). iOS pattern-matches
/// ``status``: `ok` → render ``value``; `insufficient` → render the "still
/// learning" state from ``coverage`` + ``reason``. **NEVER recompute the
/// baseline.**
public struct IllnessCorrelationDTO: Codable, Sendable, Equatable, Hashable {
    public let episodeId: String
    public let status: IllnessDerivedStatus
    public let value: IllnessCorrelationValue?
    public let coverage: IllnessCoverage
    public let confidence: IllnessConfidence?
    public let provenance: IllnessProvenance
    public let reason: String?

    public init(
        episodeId: String,
        status: IllnessDerivedStatus,
        value: IllnessCorrelationValue?,
        coverage: IllnessCoverage,
        confidence: IllnessConfidence?,
        provenance: IllnessProvenance,
        reason: String?
    ) {
        self.episodeId = episodeId
        self.status = status
        self.value = value
        self.coverage = coverage
        self.confidence = confidence
        self.provenance = provenance
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId) ?? ""
        status = try c.decodeIfPresent(IllnessDerivedStatus.self, forKey: .status) ?? .insufficient
        value = try c.decodeIfPresent(IllnessCorrelationValue.self, forKey: .value)
        coverage = try c.decodeIfPresent(IllnessCoverage.self, forKey: .coverage)
            ?? IllnessCoverage(requiredInputs: 0, presentInputs: 0, historyDays: 0, missing: [])
        confidence = try c.decodeIfPresent(IllnessConfidence.self, forKey: .confidence)
        provenance = try c.decodeIfPresent(IllnessProvenance.self, forKey: .provenance)
            ?? IllnessProvenance(inputs: [], source: "", windowDays: 0, computedAt: "")
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

// MARK: - Insights (cross-episode, server-computed)

/// `GET /api/illness/insights` → the cross-episode retrospective summary
/// (`IllnessInsightsResponse`): episode + resolved counts, the typical (median)
/// recovery gap (`nil` below the min-sample floor — withholds a thin claim), a
/// recurrence-by-month tally, and a per-type breakdown. **Retrospective only.**
public struct IllnessInsightsDTO: Codable, Sendable, Equatable, Hashable {
    public let windowDays: Int
    public let episodeCount: Int
    public let resolvedCount: Int
    /// Median recovery gap in days, or `nil` below the min-sample floor.
    public let typicalRecoveryGapDays: Double?
    public let gapSampleSize: Int
    /// `{ "YYYY-MM": count }` recurrence-by-month tally.
    public let byMonth: [String: Int]
    /// `{ "<IllnessType>": count }` per-type breakdown.
    public let byType: [String: Int]
    /// The dominant driving vital across episodes — a `MeasurementType` string,
    /// `FUNCTIONAL_IMPACT`, or `nil` when no gap is surfaced. v1.21.0.
    /// Render-only; the summary names it.
    public let gapDriverType: String?

    public init(
        windowDays: Int,
        episodeCount: Int,
        resolvedCount: Int,
        typicalRecoveryGapDays: Double?,
        gapSampleSize: Int,
        byMonth: [String: Int],
        byType: [String: Int],
        gapDriverType: String?
    ) {
        self.windowDays = windowDays
        self.episodeCount = episodeCount
        self.resolvedCount = resolvedCount
        self.typicalRecoveryGapDays = typicalRecoveryGapDays
        self.gapSampleSize = gapSampleSize
        self.byMonth = byMonth
        self.byType = byType
        self.gapDriverType = gapDriverType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 0
        episodeCount = try c.decodeIfPresent(Int.self, forKey: .episodeCount) ?? 0
        resolvedCount = try c.decodeIfPresent(Int.self, forKey: .resolvedCount) ?? 0
        typicalRecoveryGapDays = try c.decodeIfPresent(Double.self, forKey: .typicalRecoveryGapDays)
        gapSampleSize = try c.decodeIfPresent(Int.self, forKey: .gapSampleSize) ?? 0
        byMonth = try c.decodeIfPresent([String: Int].self, forKey: .byMonth) ?? [:]
        byType = try c.decodeIfPresent([String: Int].self, forKey: .byType) ?? [:]
        gapDriverType = try c.decodeIfPresent(String.self, forKey: .gapDriverType)
    }
}
