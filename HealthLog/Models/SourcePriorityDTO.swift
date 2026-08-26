import Foundation

/// Wire-form mirror of `GET / PUT /api/auth/me/source-priority`
/// (server v1.4.25 W5e + W8c, route at
/// `src/app/api/auth/me/source-priority/route.ts`).
///
/// **Two-axis model:**
///   - `metricPriority` — per-metric-class source ladder (`steps`,
///     `weight`, …) telling the server's `pickCanonicalSource()` which
///     source wins when multiple sources have a row for the same
///     timestamp. e.g. `weight: ["WITHINGS","APPLE_HEALTH","MANUAL"]`.
///   - `deviceTypePriority` — secondary axis after the source narrows
///     it down. Lets the user say "for HRV prefer the watch over the
///     ring" even when both rows have `source = APPLE_HEALTH`.
///
/// **Flat-shape backward-compat (W5e):** the server also accepts the
/// old flat-keys shape (`{ steps: [...], weight: [...], ... }`). The
/// nested `metricPriority` wins when both are present. iOS-side the
/// `metricPriority` is the authoritative read; the flat aliases are
/// kept on the DTO for round-tripping older server snapshots without
/// data loss.
///
/// **Wire form (current shape per `parseSourcePriority()`):**
/// ```
/// {
///   "data": {
///     "steps": ["APPLE_HEALTH","WITHINGS","MANUAL"],
///     "activeEnergy": [...],
///     ...
///     "metricPriority": { "steps": [...], ... },
///     "deviceTypePriority": { "default": ["watch","band",...], "WEIGHT": ["scale",...] }
///   },
///   "error": null
/// }
/// ```
public struct SourcePriorityDTO: Codable, Sendable, Equatable {
    // Flat-keys (W5e shape) — every metric-class on the top level.
    public var steps: [String]?
    public var activeEnergy: [String]?
    public var walkingRunningDistance: [String]?
    public var flightsClimbed: [String]?
    public var sleep: [String]?
    public var weight: [String]?
    public var bloodPressure: [String]?
    public var pulse: [String]?
    public var bodyFat: [String]?
    public var bodyTemperature: [String]?
    public var spo2: [String]?
    public var hrv: [String]?
    public var restingHeartRate: [String]?
    public var respiratoryRate: [String]?
    public var skinTemperature: [String]?
    public var vo2Max: [String]?
    public var recovery: [String]?

    // Nested (W8c shape).
    public var metricPriority: MetricPriority?
    public var deviceTypePriority: [String: [String]]?

    public struct MetricPriority: Codable, Sendable, Equatable {
        public var steps: [String]?
        public var activeEnergy: [String]?
        public var walkingRunningDistance: [String]?
        public var flightsClimbed: [String]?
        public var sleep: [String]?
        public var weight: [String]?
        public var bloodPressure: [String]?
        public var pulse: [String]?
        public var bodyFat: [String]?
        public var bodyTemperature: [String]?
        public var spo2: [String]?
        public var hrv: [String]?
        public var restingHeartRate: [String]?
        public var respiratoryRate: [String]?
        public var skinTemperature: [String]?
        public var vo2Max: [String]?
        public var recovery: [String]?

        public init(
            steps: [String]? = nil,
            activeEnergy: [String]? = nil,
            walkingRunningDistance: [String]? = nil,
            flightsClimbed: [String]? = nil,
            sleep: [String]? = nil,
            weight: [String]? = nil,
            bloodPressure: [String]? = nil,
            pulse: [String]? = nil,
            bodyFat: [String]? = nil,
            bodyTemperature: [String]? = nil,
            spo2: [String]? = nil,
            hrv: [String]? = nil,
            restingHeartRate: [String]? = nil,
            respiratoryRate: [String]? = nil,
            skinTemperature: [String]? = nil,
            vo2Max: [String]? = nil,
            recovery: [String]? = nil
        ) {
            self.steps = steps
            self.activeEnergy = activeEnergy
            self.walkingRunningDistance = walkingRunningDistance
            self.flightsClimbed = flightsClimbed
            self.sleep = sleep
            self.weight = weight
            self.bloodPressure = bloodPressure
            self.pulse = pulse
            self.bodyFat = bodyFat
            self.bodyTemperature = bodyTemperature
            self.spo2 = spo2
            self.hrv = hrv
            self.restingHeartRate = restingHeartRate
            self.respiratoryRate = respiratoryRate
            self.skinTemperature = skinTemperature
            self.vo2Max = vo2Max
            self.recovery = recovery
        }
    }

    public init(
        steps: [String]? = nil,
        activeEnergy: [String]? = nil,
        walkingRunningDistance: [String]? = nil,
        flightsClimbed: [String]? = nil,
        sleep: [String]? = nil,
        weight: [String]? = nil,
        bloodPressure: [String]? = nil,
        pulse: [String]? = nil,
        bodyFat: [String]? = nil,
        bodyTemperature: [String]? = nil,
        spo2: [String]? = nil,
        hrv: [String]? = nil,
        restingHeartRate: [String]? = nil,
        respiratoryRate: [String]? = nil,
        skinTemperature: [String]? = nil,
        vo2Max: [String]? = nil,
        recovery: [String]? = nil,
        metricPriority: MetricPriority? = nil,
        deviceTypePriority: [String: [String]]? = nil
    ) {
        self.steps = steps
        self.activeEnergy = activeEnergy
        self.walkingRunningDistance = walkingRunningDistance
        self.flightsClimbed = flightsClimbed
        self.sleep = sleep
        self.weight = weight
        self.bloodPressure = bloodPressure
        self.pulse = pulse
        self.bodyFat = bodyFat
        self.bodyTemperature = bodyTemperature
        self.spo2 = spo2
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.respiratoryRate = respiratoryRate
        self.skinTemperature = skinTemperature
        self.vo2Max = vo2Max
        self.recovery = recovery
        self.metricPriority = metricPriority
        self.deviceTypePriority = deviceTypePriority
    }

    /// Authoritative source-ladder for a metric key. Reads the nested
    /// `metricPriority` first (W8c shape) and falls back to the flat
    /// top-level key (W5e shape) so the caller learns one canonical
    /// answer regardless of which shape the server emits.
    public func ladder(forMetric metric: String) -> [String]? {
        if let m = metricPriority, let nested = Self.lookup(metric: metric, in: m.dictionary) {
            return nested
        }
        return Self.lookup(metric: metric, in: flatDictionary)
    }

    /// Produces a new DTO with `sources` installed for `metric` on **both**
    /// shapes (flat W5e alias + nested W8c map). Unknown metric keys
    /// return the receiver unchanged — the caller may rely on this as a
    /// no-op for unsupported keys without branching first.
    ///
    /// **Why two helpers, not one switch:** SwiftLint pins
    /// `cyclomatic_complexity` at 12 and we have 14 metric keys × 2 shapes.
    /// Splitting flat + nested across two helpers keeps each one's switch
    /// at 14 + default = 15 branches, which is acceptable per the matching
    /// `function_body_length` exception convention used by
    /// `SourcePriorityStore.metricKeyLabels`.
    public func replacingLadder(forMetric metric: String, to sources: [String]) -> SourcePriorityDTO {
        var next = self
        next.applyToFlat(metric: metric, sources: sources)
        var nested = next.metricPriority ?? MetricPriority()
        nested.apply(metric: metric, sources: sources)
        next.metricPriority = nested
        return next
    }

    // swiftlint:disable cyclomatic_complexity
    private mutating func applyToFlat(metric: String, sources: [String]) {
        switch metric {
        case "steps": steps = sources
        case "activeEnergy": activeEnergy = sources
        case "walkingRunningDistance": walkingRunningDistance = sources
        case "flightsClimbed": flightsClimbed = sources
        case "sleep": sleep = sources
        case "weight": weight = sources
        case "bloodPressure": bloodPressure = sources
        case "pulse": pulse = sources
        case "bodyFat": bodyFat = sources
        case "bodyTemperature": bodyTemperature = sources
        case "spo2": spo2 = sources
        case "hrv": hrv = sources
        case "restingHeartRate": restingHeartRate = sources
        case "respiratoryRate": respiratoryRate = sources
        case "skinTemperature": skinTemperature = sources
        case "vo2Max": vo2Max = sources
        case "recovery": recovery = sources
        default: break
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// Lookup helper — pure, branchless, low-complexity. Returns
    /// `nil` for both "metric key absent" and "metric key present
    /// but value is nil"; callers don't distinguish the two cases.
    private static func lookup(metric: String, in dict: [String: [String]?]) -> [String]? {
        guard let slot = dict[metric] else { return nil }
        return slot
    }

    /// Flat-shape values as a dictionary for the lookup helper.
    private var flatDictionary: [String: [String]?] {
        [
            "steps": steps,
            "activeEnergy": activeEnergy,
            "walkingRunningDistance": walkingRunningDistance,
            "flightsClimbed": flightsClimbed,
            "sleep": sleep,
            "weight": weight,
            "bloodPressure": bloodPressure,
            "pulse": pulse,
            "bodyFat": bodyFat,
            "bodyTemperature": bodyTemperature,
            "spo2": spo2,
            "hrv": hrv,
            "restingHeartRate": restingHeartRate,
            "respiratoryRate": respiratoryRate,
            "skinTemperature": skinTemperature,
            "vo2Max": vo2Max,
            "recovery": recovery
        ]
    }
}

private extension SourcePriorityDTO.MetricPriority {
    /// Nested shape values as a dictionary for the lookup helper. Same
    /// keying as `flatDictionary` on the outer DTO so callers can hand
    /// either to `SourcePriorityDTO.lookup(metric:in:)`.
    var dictionary: [String: [String]?] {
        [
            "steps": steps,
            "activeEnergy": activeEnergy,
            "walkingRunningDistance": walkingRunningDistance,
            "flightsClimbed": flightsClimbed,
            "sleep": sleep,
            "weight": weight,
            "bloodPressure": bloodPressure,
            "pulse": pulse,
            "bodyFat": bodyFat,
            "bodyTemperature": bodyTemperature,
            "spo2": spo2,
            "hrv": hrv,
            "restingHeartRate": restingHeartRate,
            "respiratoryRate": respiratoryRate,
            "skinTemperature": skinTemperature,
            "vo2Max": vo2Max,
            "recovery": recovery
        ]
    }

    // swiftlint:disable cyclomatic_complexity
    /// Mirror of `SourcePriorityDTO.applyToFlat(metric:sources:)` — writes
    /// `sources` into the nested W8c slot for `metric`. Mutating because
    /// `MetricPriority` is the value-type owner; the outer DTO writes
    /// the result back via `metricPriority = nested`.
    mutating func apply(metric: String, sources: [String]) {
        switch metric {
        case "steps": steps = sources
        case "activeEnergy": activeEnergy = sources
        case "walkingRunningDistance": walkingRunningDistance = sources
        case "flightsClimbed": flightsClimbed = sources
        case "sleep": sleep = sources
        case "weight": weight = sources
        case "bloodPressure": bloodPressure = sources
        case "pulse": pulse = sources
        case "bodyFat": bodyFat = sources
        case "bodyTemperature": bodyTemperature = sources
        case "spo2": spo2 = sources
        case "hrv": hrv = sources
        case "restingHeartRate": restingHeartRate = sources
        case "respiratoryRate": respiratoryRate = sources
        case "skinTemperature": skinTemperature = sources
        case "vo2Max": vo2Max = sources
        case "recovery": recovery = sources
        default: break
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
