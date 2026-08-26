import Foundation

/// **A360 H1/H2 (v0156)** — the metric/correlation context the user was looking at
/// when they opened the Coach. Mirrors the web `CoachLaunchScope`
/// (`src/lib/insights/coach-launch-context.tsx`): a primary `metric`, optional
/// `also` sources (a correlation card spans two metrics), and an optional
/// `window`. The store collapses this into the chat route's wire `scope`
/// (`{ sources, window }`) and attaches it ONLY to the FIRST turn of a fresh
/// server conversation — a continued thread keeps its own established scope
/// (web parity, `coach-conversation.tsx:317`).
///
/// The server (`coachScopeSchema`, `src/lib/ai/coach/types.ts`) defaults any
/// missing field, so an unrecognised / older server ignores the extra body key
/// harmlessly (v1.21.0 may not be on prod/demo yet — sending it is back-compat).
public struct CoachLaunchScope: Sendable, Equatable {
    /// Primary metric source the conversation narrows to. Stable contract token
    /// matching the server `coachScopeSourceSchema` enum.
    public let metric: CoachScopeSource
    /// Extra sources to include alongside `metric` — a correlation card spanning
    /// two metrics (e.g. BP × compliance) seeds both so the snapshot covers the
    /// relationship the card describes.
    public let also: [CoachScopeSource]
    /// Optional day-window the conversation anchors on. `nil` → the route's
    /// default (`last30days`).
    public let window: CoachScopeWindow?

    public init(metric: CoachScopeSource, also: [CoachScopeSource] = [], window: CoachScopeWindow? = nil) {
        self.metric = metric
        self.also = also
        self.window = window
    }

    /// Collapse the launch scope into the chat route's wire `scope`
    /// (`{ sources, window }`), de-duplicating `[metric, ...also]` while
    /// preserving order. Mirrors web `launchScopeToCoachScope`
    /// (`coach-conversation.tsx:77`).
    public var wireScope: CoachScopeWire {
        var seen = Set<CoachScopeSource>()
        var ordered: [CoachScopeSource] = []
        for source in [metric] + also where seen.insert(source).inserted {
            ordered.append(source)
        }
        return CoachScopeWire(sources: ordered.map(\.rawValue), window: window?.rawValue)
    }
}

/// Stable source tokens the server `coachScopeSourceSchema` accepts
/// (`src/lib/ai/coach/types.ts`). iOS only enumerates the subset its surfaces
/// can actually launch from; the wire value is the raw string, so a token the
/// server doesn't know is simply ignored server-side (additive-safe).
public enum CoachScopeSource: String, Sendable, Equatable, Hashable {
    case bp
    case weight
    case pulse
    case mood
    case compliance
    case hrv
    case sleep
    case restingHR = "resting_hr"
    case steps
    case activeEnergy = "active_energy"
    case flights
    case distance
    case vo2Max = "vo2_max"
    case bodyTemp = "body_temp"
    case walkingHR = "walking_hr"
    case respiratoryRate = "respiratory_rate"
    case spo2
    case pulseWaveVelocity = "pulse_wave_velocity"
    case vascularAge = "vascular_age"
    case bodyFat = "body_fat"
    case fatMass = "fat_mass"
    case fatFreeMass = "fat_free_mass"
    case muscleMass = "muscle_mass"
    case leanBodyMass = "lean_body_mass"
    case boneMass = "bone_mass"
    case totalBodyWater = "total_body_water"
    case bmi
    case visceralFat = "visceral_fat"
    case glucose
    case walkingSteadiness = "walking_steadiness"
    case walkingAsymmetry = "walking_asymmetry"
    case walkingDoubleSupport = "walking_double_support"
    case walkingStepLength = "walking_step_length"
    case walkingSpeed = "walking_speed"
    case skinTemp = "skin_temp"
    case daylight
    case workouts
}

/// Window tokens the server `coachScopeWindowSchema` accepts.
public enum CoachScopeWindow: String, Sendable, Equatable {
    case last7days
    case last30days
    case last90days
    case lastYear
    case allTime
}

/// Wire shape encoded into the chat request body's `scope` field — exactly the
/// server's `coachScopeSchema` (`{ sources?: string[], window?: string }`).
/// Omits `sources` when empty so a degenerate scope never narrows the snapshot
/// to nothing (the server treats an empty `sources` array as "no metrics").
public struct CoachScopeWire: Codable, Sendable, Equatable {
    public let sources: [String]
    public let window: String?

    public init(sources: [String], window: String?) {
        self.sources = sources
        self.window = window
    }

    private enum CodingKeys: String, CodingKey {
        case sources
        case window
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !sources.isEmpty {
            try container.encode(sources, forKey: .sources)
        }
        try container.encodeIfPresent(window, forKey: .window)
    }

    /// Tolerant decode (used by tests that read the scope back off the encoded
    /// request body) — a missing `sources` reads as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        window = try container.decodeIfPresent(String.self, forKey: .window)
    }
}

// MARK: - MetricKind → CoachScopeSource

extension MetricKind {
    /// Maps a `MetricKind` to the Coach scope source token the server snapshot
    /// builder recognises, when one exists. `nil` for kinds the server snapshot
    /// has no dedicated source for (the launch then falls back to the default
    /// all-source snapshot rather than narrowing to nothing). Used by the
    /// per-metric / per-tile "Ask the coach about this" launch sites.
    var coachScopeSource: CoachScopeSource? {
        switch self {
        case .bloodPressure: .bp
        case .weight: .weight
        case .pulse: .pulse
        case .glucose: .glucose
        case .bodyFat: .bodyFat
        case .bodyTemperature: .bodyTemp
        case .spo2: .spo2
        case .bodyWater: .totalBodyWater
        case .boneMass: .boneMass
        case .sleep: .sleep
        case .steps: .steps
        case .restingHeartRate: .restingHR
        case .hrv: .hrv
        case .vo2Max: .vo2Max
        case .walkingSpeed: .walkingSpeed
        case .walkingAsymmetry: .walkingAsymmetry
        case .walkingStepLength: .walkingStepLength
        case .bmi: .bmi
        case .walkingDoubleSupport: .walkingDoubleSupport
        case .walkingSteadiness: .walkingSteadiness
        case .respiratoryRate: .respiratoryRate
        case .audioExposureEnvironment: nil
        case .audioExposureHeadphone: nil
        case .activeEnergy: .activeEnergy
        case .flightsClimbed: .flights
        case .distanceWalkingRunning: .distance
        case .timeInDaylight: .daylight
        case .fatFreeMass: .fatFreeMass
        case .leanBodyMass: .leanBodyMass
        case .muscleMass: .muscleMass
        case .skinTemperature: .skinTemp
        case .pulseWaveVelocity: .pulseWaveVelocity
        case .vascularAge: .vascularAge
        case .visceralFat: .visceralFat
        case .walkingHeartRate: .walkingHR
        case .fatMass: .fatMass
        // Kinds the server snapshot carries no dedicated scope source for →
        // launch falls back to the default all-source snapshot.
        case .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types have no dedicated coach scope source
             // server-side (surfaces.coachSnapshot == false) → all-source snapshot.
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types carry no
             // dedicated coach-scope source server-side → all-source snapshot.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood has no dedicated coach-scope source
             // server-side → all-source snapshot.
             .mood:
            nil
        }
    }
}
