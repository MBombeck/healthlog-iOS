import Foundation

/// Provenance of a medication-intake row (server `source` column).
///
/// **GH #47 (server v1.28) — Apple Health medications mirror.** The server now
/// stamps intake rows created by the iOS 26+ HealthKit dose-event import with
/// `source: "APPLE_HEALTH"`. Older / app-managed rows carry `"MANUAL"` (or omit
/// the field entirely against pre-v1.28 servers). This enum is the tolerant,
/// **exhaustive** decode surface: every wire string maps to a case (unknown →
/// ``other``), so an intake row on `/api/sync/changes` carrying a `source` the
/// client does not model NEVER fails to decode and drops the row — a decode-drop
/// would silently lose a dose from the mirror.
public enum IntakeSource: Sendable, Equatable, Hashable {
    /// App-managed dose (server default; wire `"MANUAL"` or absent).
    case manual
    /// Mirrored from Apple Health's HealthKit Medications (wire `"APPLE_HEALTH"`).
    /// The exact spelling is the server contract — do not localise / re-case.
    case appleHealth
    /// Any forward-compat server source string the client does not yet model.
    /// Preserved verbatim so a re-encode round-trips and the row is never lost.
    case other(String)

    /// The canonical server wire string.
    public var wireValue: String {
        switch self {
        case .manual: "MANUAL"
        case .appleHealth: "APPLE_HEALTH"
        case let .other(raw): raw
        }
    }

    /// Tolerant parse — every string resolves to a case, none throws.
    public init(wireValue raw: String) {
        switch raw {
        case "APPLE_HEALTH": self = .appleHealth
        case "MANUAL", "": self = .manual
        default: self = .other(raw)
        }
    }

    /// `true` only for the Apple-Health-mirrored source. Drives the
    /// source-exclusive policy (a mirrored dose never gets a manual sibling).
    public var isAppleHealth: Bool {
        self == .appleHealth
    }
}

extension IntakeSource: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = IntakeSource(wireValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Delta-page intake upsert row from `GET /api/sync/changes`
/// (`SyncIntakeUpsert` in the OpenAPI). Decoded **tolerantly** so a row whose
/// `source` is `APPLE_HEALTH` — or any other/absent value — always survives the
/// page decode. Intake identity is the server `id` (an intake is immutable;
/// a correction is a tombstone + re-insert).
public struct SyncIntakeUpsert: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let medicationId: String
    public let scheduledFor: Date
    public let takenAt: Date?
    public let skipped: Bool
    public let source: IntakeSource
    public let syncVersion: Int?

    public init(
        id: String,
        medicationId: String,
        scheduledFor: Date,
        takenAt: Date? = nil,
        skipped: Bool = false,
        source: IntakeSource = .manual,
        syncVersion: Int? = nil
    ) {
        self.id = id
        self.medicationId = medicationId
        self.scheduledFor = scheduledFor
        self.takenAt = takenAt
        self.skipped = skipped
        self.source = source
        self.syncVersion = syncVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, medicationId, scheduledFor, takenAt, skipped, source, syncVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        medicationId = try container.decode(String.self, forKey: .medicationId)
        scheduledFor = try container.decode(Date.self, forKey: .scheduledFor)
        takenAt = try container.decodeIfPresent(Date.self, forKey: .takenAt)
        skipped = try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        // Tolerant: an absent OR unmodelled `source` never drops the row — the
        // whole point of the exhaustive `IntakeSource` decode (GH #47).
        if let raw = try container.decodeIfPresent(String.self, forKey: .source) {
            source = IntakeSource(wireValue: raw)
        } else {
            source = .manual
        }
        syncVersion = try container.decodeIfPresent(Int.self, forKey: .syncVersion)
    }
}
