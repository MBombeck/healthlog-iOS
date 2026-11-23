import Foundation

/// One Apple Health symptom on `POST /api/symptoms/events/batch`
/// (`CONTRACT-apple-health-v2.md` §2.2). `externalId` is the HealthKit
/// sample UUID; a re-sent page folds into the rows already stored.
public struct AppleHealthSymptomEntryDTO: Codable, Sendable, Equatable {
    public let code: String
    public let occurredAt: Date
    /// Omitted when the sample has no duration.
    public let endAt: Date?
    public let intensity: Int
    public let externalId: String
    public let source: String

    public init(code: String, occurredAt: Date, endAt: Date?, intensity: Int, externalId: String) {
        self.code = code
        self.occurredAt = occurredAt
        self.endAt = endAt.flatMap { $0 > occurredAt ? $0 : nil }
        self.intensity = intensity
        self.externalId = externalId
        source = "APPLE_HEALTH"
    }
}

public struct AppleHealthSymptomBatchPayload: Codable, Sendable, Equatable {
    public let entries: [AppleHealthSymptomEntryDTO]

    public init(entries: [AppleHealthSymptomEntryDTO]) {
        self.entries = entries
    }
}

/// The Apple Health delete-by-externalId routes (§2.3 and §3). Each takes
/// `{ externalIds }` (at most 500) and touches only the caller's own
/// `APPLE_HEALTH` rows, so a repeat is a no-op.
public enum AppleHealthDeleteDomain: String, Codable, Sendable, CaseIterable {
    case measurement
    case symptoms
    case workout
    case ecg
    case cycleDayLog = "cycle.day-log"
    case mood
    case medicationIntake = "medication.intake"

    public var path: String {
        switch self {
        case .measurement: "/api/measurements/by-external-ids"
        case .symptoms: "/api/symptoms/events/by-external-ids"
        case .workout: "/api/workouts/by-external-ids"
        case .ecg: "/api/insights/ecg/by-external-ids"
        case .cycleDayLog: "/api/cycle/day-logs/by-external-ids"
        case .mood: "/api/mood-entries/by-external-ids"
        case .medicationIntake: "/api/medications/intake/by-external-ids"
        }
    }

    /// The route's bound.
    public static let maxIDsPerRequest = 500
}

public enum AppleHealthIngestRoute {
    public static let symptomsBatch = "/api/symptoms/events/batch"
}
