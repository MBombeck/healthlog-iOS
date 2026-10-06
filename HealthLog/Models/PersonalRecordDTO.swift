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
        createdAt: Date
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
        accountTransform(units).suffix ?? unit
    }
}
