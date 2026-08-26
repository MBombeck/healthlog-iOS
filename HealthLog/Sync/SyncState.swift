import Foundation

/// Wire-format mirror of the server's `GET /api/sync/state` response per the
/// R9 hard-spec. Read by the iOS client to determine per-entity high-water-marks
/// for incremental-sync resume.
///
/// **Specced in:** `.planning/v05x-marathon/STANDALONE-ARCHITECTURE-SPEC.md` §0 (R9)
/// and §4.3 (first-pair pull phase).
///
/// **Server response shape (R9 verbatim):**
/// ```json
/// {
///   "measurement":      "2026-05-15T14:22:00Z",
///   "moodEntry":        "2026-05-15T13:11:42Z",
///   "medication":       "2026-05-14T09:00:00Z",
///   "medicationIntake": "2026-05-15T07:30:00Z"
/// }
/// ```
///
/// Each value is the server's max `updatedAt` for that entity-kind across the
/// user's rows. iOS calls `GET /api/<entity>?since=<value>&limit=500` paginated
/// until empty to pull all changes since the last sync.
///
/// **`nil` semantics:** an entity-kind missing from the response (or with a
/// `null` value) means the server has zero rows for the user in that kind. iOS
/// treats this as "no incremental-sync needed for this kind" on first sync,
/// or "the server lost all rows" on subsequent syncs (which would be a server
/// incident, not a client-handlable state — surface as audit-log entry).
///
/// **Date format:** ISO-8601 with UTC offset, millisecond precision. JSONDecoder
/// uses `.iso8601` strategy (which accepts both `Z` and `+00:00` notations).
///
/// **Consumer:** `SyncStateClient` (added in sub-phase S3) + `HighWaterMarkStore`
/// for per-entity HWM persistence under `UserDefaults` key `hl.hwm.<entityKind>`.
public struct SyncState: Sendable, Equatable, Codable {
    /// Server's max `updatedAt` across the user's `Measurement` rows.
    public let measurement: Date?

    /// Server's max `updatedAt` across the user's `MoodEntry` rows.
    public let moodEntry: Date?

    /// Server's max `updatedAt` across the user's `Medication` (prescription) rows.
    public let medication: Date?

    /// Server's max `updatedAt` across the user's `MedicationIntake` rows.
    public let medicationIntake: Date?

    /// v0.14.8 cycle marathon — server's max `updatedAt` across the user's
    /// `CycleDayLog` rows (the `changes.cycleDays` block, contract §3).
    public let cycleDays: Date?

    /// v0.14.8 — server's max `updatedAt` across the user's `MenstrualCycle`
    /// rows (the `changes.cycles` block).
    public let cycles: Date?

    public init(
        measurement: Date? = nil,
        moodEntry: Date? = nil,
        medication: Date? = nil,
        medicationIntake: Date? = nil,
        cycleDays: Date? = nil,
        cycles: Date? = nil
    ) {
        self.measurement = measurement
        self.moodEntry = moodEntry
        self.medication = medication
        self.medicationIntake = medicationIntake
        self.cycleDays = cycleDays
        self.cycles = cycles
    }

    private enum CodingKeys: String, CodingKey {
        case measurement
        case moodEntry
        case medication
        case medicationIntake
        case cycleDays
        case cycles
    }
}

/// Sync cursor schema version. The server bumps `CURSOR_VERSION` → 2 with the
/// cycle domains (contract §3); a client holding an older cursor must clean
/// re-init (drop persisted HWMs + full re-pull) on mismatch.
public enum SyncCursorVersion {
    /// The version this client speaks. Bumped from 1 → 2 for `cycleDays`/`cycles`.
    public static let current = 2

    /// True when a persisted cursor version differs from `current` and the
    /// client must wipe its HWMs and re-initialise from scratch.
    public static func requiresReinit(persisted: Int?) -> Bool {
        persisted != current
    }
}

/// Canonical entity-kind keys mirroring `SyncState`'s field names. Used as the
/// suffix in `UserDefaults` HWM keys (`hl.hwm.<entityKind>`) and as the
/// path-segment in `GET /api/<entity>?since=...` URLs.
///
/// **Added in sub-phase S3** alongside `HighWaterMarkStore`. Defined here in
/// S-0 so the wire-contract is self-contained in one file.
public enum SyncEntityKind: String, Sendable, CaseIterable, Codable {
    case measurement
    case moodEntry
    case medication
    case medicationIntake
    /// v0.14.8 — `CycleDayLog` rows. Tombstone identity keys on `externalId`
    /// when present, else `id` (contract §3); apply tombstones before upserts.
    case cycleDays
    /// v0.14.8 — `MenstrualCycle` rows. Tombstone identity keys on `id`.
    case cycles

    /// Path-segment for the per-entity REST endpoint. Used as
    /// `GET /api/<urlSegment>?since=<hwm>&limit=500`.
    public var urlSegment: String {
        switch self {
        case .measurement: "measurements"
        case .moodEntry: "mood-entries"
        case .medication: "medications"
        case .medicationIntake: "medications/intake"
        case .cycleDays: "cycle/day-logs"
        case .cycles: "cycle/cycles"
        }
    }

    /// Tombstone identity field for incremental change-apply (contract §3):
    /// cycleDays key on `externalId` (falling back to `id`), cycles on `id`.
    public var tombstoneKeysOnExternalId: Bool {
        self == .cycleDays
    }
}

public extension SyncState {
    /// Convenience accessor by entity-kind. Returns the corresponding HWM, or
    /// `nil` if the server reported zero rows for that kind.
    func highWaterMark(for kind: SyncEntityKind) -> Date? {
        switch kind {
        case .measurement: measurement
        case .moodEntry: moodEntry
        case .medication: medication
        case .medicationIntake: medicationIntake
        case .cycleDays: cycleDays
        case .cycles: cycles
        }
    }
}
