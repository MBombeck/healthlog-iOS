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

    public enum Direction: String, Decodable, Sendable, Equatable {
        case max = "MAX"
        case min = "MIN"
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
