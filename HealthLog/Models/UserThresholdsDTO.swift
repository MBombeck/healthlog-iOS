import Foundation

/// Wire-form mirror of `GET / PUT /api/user/thresholds` (server route at
/// `src/app/api/user/thresholds/route.ts`).
///
/// The route backs per-user target-range overrides — the editable half of
/// the personal-targets surface. `GET /api/insights/targets` is a *computed*
/// read-only view (current value + trend + consistency strip); the raw,
/// editable `{ min, max }` band per metric lives in `User.thresholdsJson` and
/// is read / written through this endpoint.
///
/// **GET** returns `{ effective, overrides }`:
///   - `effective`: the resolved range per metric (default merged with the
///     user override) — what the rest of the app classifies against.
///   - `overrides`: only the metrics the user has explicitly set. Missing
///     keys fall back to the physiological default.
///
/// **PUT** accepts a partial `{ metric: { min, max } }` map (only the changed
/// metrics) and echoes the merged `{ overrides }`. Server validates each band
/// against the metric's physiological bounds + `min < max` and 422s on bad
/// input (multi-issue Zod envelope).
public struct UserThresholdsResponseDTO: Decodable, Sendable, Equatable {
    /// Resolved (default + override) range per metric key.
    public let effective: [String: ThresholdRange]
    /// User-set overrides only (subset of `effective`).
    public let overrides: [String: ThresholdRange]

    public init(
        effective: [String: ThresholdRange] = [:],
        overrides: [String: ThresholdRange] = [:]
    ) {
        self.effective = effective
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case effective
        case overrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `effective` may carry extra non-range shapes for metrics the iOS
        // editor doesn't surface — decode leniently, dropping unparseable
        // entries rather than failing the whole payload.
        effective = (try? c.decodeIfPresent([String: ThresholdRange].self, forKey: .effective)) ?? [:]
        overrides = (try? c.decodeIfPresent([String: ThresholdRange].self, forKey: .overrides)) ?? [:]
    }
}

/// A single `{ min, max }` target band. Shared by the GET response, the PUT
/// request body, and the PUT echo.
public struct ThresholdRange: Codable, Sendable, Equatable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

/// Echo of `PUT /api/user/thresholds` — `{ overrides }`.
public struct UserThresholdsUpdateEchoDTO: Decodable, Sendable, Equatable {
    public let overrides: [String: ThresholdRange]

    public init(overrides: [String: ThresholdRange] = [:]) {
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case overrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overrides = (try? c.decodeIfPresent([String: ThresholdRange].self, forKey: .overrides)) ?? [:]
    }
}

/// PUT request body — a partial `{ metric: { min, max } }` map. Only the
/// changed metrics are sent; the server merges them onto the existing
/// overrides (`PUT` is upsert-merge, not replace).
public typealias ThresholdsUpdatePayload = [String: ThresholdRange]

/// The metric keys `/api/user/thresholds` accepts, mirroring the server's
/// `ThresholdMetric` union + `METRIC_BOUNDS`. Each carries the outer
/// physiological bounds (`{ min, max }`) the server validates against, plus
/// the display unit — so the iOS editor can validate *before* the round-trip
/// and surface the same guardrails the server enforces.
///
/// Single source of truth for the editor's metric list + per-metric bounds.
/// Mirrors `src/lib/analytics/effective-range.ts` `METRIC_BOUNDS`.
public enum ThresholdMetric: String, CaseIterable, Sendable {
    case weight = "WEIGHT"
    case bloodPressureSys = "BLOOD_PRESSURE_SYS"
    case bloodPressureDia = "BLOOD_PRESSURE_DIA"
    case pulse = "PULSE"
    case bodyFat = "BODY_FAT"
    case sleepDuration = "SLEEP_DURATION"
    case activitySteps = "ACTIVITY_STEPS"
    case bloodGlucoseFasting = "BLOOD_GLUCOSE_FASTING"
    case bloodGlucosePostprandial = "BLOOD_GLUCOSE_POSTPRANDIAL"
    case bloodGlucoseRandom = "BLOOD_GLUCOSE_RANDOM"
    case bloodGlucoseBedtime = "BLOOD_GLUCOSE_BEDTIME"
    case totalBodyWater = "TOTAL_BODY_WATER"
    case boneMass = "BONE_MASS"
    case oxygenSaturation = "OXYGEN_SATURATION"

    /// Outer physiological bound + display unit for a metric. Mirrors the
    /// server's `METRIC_BOUNDS` entry shape.
    public struct Bounds: Sendable, Equatable {
        public let min: Double
        public let max: Double
        public let unit: String

        public init(min: Double, max: Double, unit: String) {
            self.min = min
            self.max = max
            self.unit = unit
        }
    }

    /// Outer physiological bound + display unit per metric. Mirrors the
    /// server's `METRIC_BOUNDS` verbatim so client-side validation rejects
    /// exactly what the server would 422 on.
    public var bounds: Bounds {
        switch self {
        case .weight: Bounds(min: 30, max: 300, unit: "kg")
        case .bloodPressureSys: Bounds(min: 80, max: 220, unit: "mmHg")
        case .bloodPressureDia: Bounds(min: 40, max: 140, unit: "mmHg")
        case .pulse: Bounds(min: 30, max: 220, unit: "bpm")
        case .bodyFat: Bounds(min: 3, max: 60, unit: "%")
        case .sleepDuration: Bounds(min: 3, max: 14, unit: "h")
        case .activitySteps: Bounds(min: 0, max: 50000, unit: "steps")
        case .bloodGlucoseFasting: Bounds(min: 40, max: 400, unit: "mg/dL")
        case .bloodGlucosePostprandial: Bounds(min: 40, max: 500, unit: "mg/dL")
        case .bloodGlucoseRandom: Bounds(min: 40, max: 500, unit: "mg/dL")
        case .bloodGlucoseBedtime: Bounds(min: 40, max: 400, unit: "mg/dL")
        case .totalBodyWater: Bounds(min: 5, max: 100, unit: "kg")
        case .boneMass: Bounds(min: 0.5, max: 8, unit: "kg")
        case .oxygenSaturation: Bounds(min: 50, max: 100, unit: "%")
        }
    }

    /// The `InsightsTargetsResponseDTO.TargetItem.type` value this metric maps
    /// to, so the editor can join an editable threshold to the read-only
    /// target card the user tapped. `nil` for metrics with no card counterpart
    /// (blood-glucose contexts, body composition — surfaced standalone).
    public var targetCardType: String? {
        switch self {
        case .weight: "WEIGHT"
        case .bloodPressureSys: "BLOOD_PRESSURE"
        case .pulse: "PULSE"
        case .bodyFat: "BODY_FAT"
        case .sleepDuration: "SLEEP_DURATION"
        case .activitySteps: "ACTIVITY_STEPS"
        case .bloodPressureDia, .bloodGlucoseFasting, .bloodGlucosePostprandial,
             .bloodGlucoseRandom, .bloodGlucoseBedtime, .totalBodyWater,
             .boneMass, .oxygenSaturation:
            nil
        }
    }
}
