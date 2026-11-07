import Foundation

/// Wire-form mirror of one `PersonalRecord` row from `GET /api/personal-records`
/// (server v1.4.25 W8d, route at `src/app/api/personal-records/route.ts`).
///
/// **Schema-only release status (v1.4.25):** the route + table exist
/// today; the detection worker that POPULATES rows ships in v1.4.26 /
/// v1.5. iOS-side the consumer must tolerate an empty array gracefully
/// — that is the current production state.
///
/// **Direction semantics:**
///   - `.max` — higher is the record (steps / VO2 max / HRV / distance)
///   - `.min` — lower is the record (resting HR / body fat / audio exposure)
///
/// **`metricSlot`:** per-sport-type bucket for workout-driven PRs
/// (e.g. `"running_5km_time"`). NULL for plain measurement-driven PRs
/// where the metric type alone is the dimension.
public struct PersonalRecordDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let userId: String
    public let metricType: String
    public let metricSlot: String?
    public let direction: Direction
    public let value: Double
    public let unit: String
    public let achievedAt: Date
    public let sourceMeasurementId: String?
    public let source: String
    public let externalId: String?
    public let createdAt: Date
    /// #135 (server v1.43) — an age- and sex-aware comparison band from a
    /// cited norm, in the record's unit. `nil` when no norm exists and on every
    /// older server; the comparison band then omits itself.
    public let benchmark: RecordBenchmark?

    public enum Direction: String, Decodable, Sendable, Equatable, TolerantServerEnum {
        case max = "MAX"
        case min = "MIN"
        /// #115 · 1.7 — unrecognised record direction; the record still shows
        /// its value, without claiming "highest" or "lowest".
        case unknown

        public static let unknownFallback = Direction.unknown
        public static let wireVocabulary: StaticString = "personal record direction"
    }

    public init(
        id: String,
        userId: String,
        metricType: String,
        metricSlot: String?,
        direction: Direction,
        value: Double,
        unit: String,
        achievedAt: Date,
        sourceMeasurementId: String?,
        source: String,
        externalId: String?,
        createdAt: Date,
        benchmark: RecordBenchmark? = nil
    ) {
        self.id = id
        self.userId = userId
        self.metricType = metricType
        self.metricSlot = metricSlot
        self.direction = direction
        self.value = value
        self.unit = unit
        self.achievedAt = achievedAt
        self.sourceMeasurementId = sourceMeasurementId
        self.source = source
        self.externalId = externalId
        self.createdAt = createdAt
        self.benchmark = benchmark
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, metricType, metricSlot, direction, value, unit, achievedAt
        case sourceMeasurementId, source, externalId, createdAt, benchmark
    }

    /// The row fields exactly as the synthesized decoder read them, plus the
    /// v1.43 `benchmark`, which is read tolerantly: a block this build cannot
    /// read is "no benchmark", never a lost list of records.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        metricType = try c.decode(String.self, forKey: .metricType)
        metricSlot = try c.decodeIfPresent(String.self, forKey: .metricSlot)
        direction = try c.decode(Direction.self, forKey: .direction)
        value = try c.decode(Double.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        achievedAt = try c.decode(Date.self, forKey: .achievedAt)
        sourceMeasurementId = try c.decodeIfPresent(String.self, forKey: .sourceMeasurementId)
        source = try c.decode(String.self, forKey: .source)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        benchmark = (try? c.decodeIfPresent(RecordBenchmark.self, forKey: .benchmark)).flatMap { $0.isDrawable ? $0 : nil }
    }
}

// MARK: - Account unit (#115 P2)

public extension PersonalRecordDTO {
    /// **#115 P2** — `GET /api/personal-records` hands back the stored row:
    /// canonical value, canonical unit ("kg", "°C", "mg/dL", "m"). The record
    /// surfaces printed both verbatim, so an imperial account read its best
    /// weight in kg next to a dashboard in lb. This is the record's transform
    /// into the account's unit — and only when the row's unit IS the kind's
    /// canonical unit, so a row stamped in anything else is never rescaled.
    func accountTransform(_ units: UnitPreferences) -> UnitDisplayTransform {
        let kind = metricType.uppercased() == "WALKING_RUNNING_DISTANCE"
            ? MetricKind.distanceWalkingRunning
            : MetricTypeKindResolver.kind(forMetricType: metricType)
        guard let kind, kind.unitFamily != .bloodPressure else { return .identity }
        let stamped = unit.trimmingCharacters(in: .whitespaces)
        guard stamped.isEmpty || stamped == kind.unit else { return .identity }
        return units.transform(for: kind)
    }

    /// The record value in the account's unit.
    func displayValue(_ units: UnitPreferences) -> Double {
        accountTransform(units).display(value)
    }

    /// The unit label the record reads in.
    func displayUnit(_ units: UnitPreferences) -> String {
        accountTransform(units).suffix ?? Self.localizedUnit(unit)
    }

    /// 1.4 B4 — the server stamps a step record "steps"; printed verbatim it
    /// read "12.999 steps" in German. A count unit takes the app's own word
    /// ("Schritte"); every measured unit ("kg", "bpm", "km") stays as sent.
    /// POLISH-B (SHOTS F-REC-1) — the same for "floors" ("27 floors").
    static func localizedUnit(_ unit: String) -> String {
        switch unit.trimmingCharacters(in: .whitespaces).lowercased() {
        case "steps": String(localized: "dashboard.metric.unit.steps")
        case "floors": String(localized: "dashboard.metric.unit.floors")
        default: unit
        }
    }
}
