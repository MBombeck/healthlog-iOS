import Foundation

/// Wire-form mirror of `GET /api/sync/state` (server v1.4.30).
///
/// The server route at `src/app/api/sync/state/route.ts` returns a
/// per-user handshake payload the iOS sync surface reads to decide
/// whether to drain the outbox, request a full refresh, or sit quiet
/// (see `22-standalone-and-server-pairing.md`). The earlier
/// `HealthLog/Sync/SyncState.swift` was specced against the R9 dream
/// shape (per-entity HWM map) — that endpoint was never built. This
/// DTO mirrors the contract the server actually emits.
///
/// **Wire shape:**
/// ```
/// {
///   "data": {
///     "userId": "usr_...",
///     "timezone": "Europe/Berlin",
///     "lastSyncedAt": "2026-05-15T14:22:00Z" | null,
///     "serverNow": "2026-05-17T12:34:56Z",
///     "measurements": {
///       "lastUpdatedAt": "2026-05-15T14:22:00Z" | null,
///       "liveCount": 1234,
///       "tombstonedCount": 7
///     }
///   },
///   "error": null
/// }
/// ```
///
/// **Side-effect of GET:** the call bumps `User.lastSyncedAt` server-side.
/// `lastSyncedAt` in the response is the value BEFORE the bump, so the
/// caller learns the previous checkpoint without re-reading.
///
/// **Clock-skew detection:** `serverNow` lets the iOS client compute
/// `Date.now() - serverNow` and surface a warning when the absolute
/// delta exceeds a tolerable window (locked at 5 min in the spec).
public struct ServerSyncStateDTO: Decodable, Sendable, Equatable {
    public let userId: String
    public let timezone: String
    public let lastSyncedAt: Date?
    public let serverNow: Date
    public let measurements: Measurements
    /// **#188 (1), stable in #191 — `medications.lastUpdatedAt`.** The last
    /// change to any medication or dose of the account. Compared on every
    /// foreground and every notification interaction; an inequality reloads
    /// the medications (``MedicationFreshness``). `nil` on an older server.
    public let medications: Medications?
    /// **#191 (final) — `intakes`.** Dose changes, the auto-skip cron
    /// included, move this block and not ``medications``; the freshness check
    /// compares both. `nil` on an older server.
    public let intakes: Intakes?

    /// `intakes: { lastUpdatedAt, liveCount, tombstonedCount }`, tolerant
    /// field by field like ``Medications``.
    public struct Intakes: Decodable, Sendable, Equatable {
        public let lastUpdatedAt: Date?
        public let liveCount: Int?
        public let tombstonedCount: Int?

        public init(lastUpdatedAt: Date?, liveCount: Int?, tombstonedCount: Int?) {
            self.lastUpdatedAt = lastUpdatedAt
            self.liveCount = liveCount
            self.tombstonedCount = tombstonedCount
        }

        private enum CodingKeys: String, CodingKey {
            case lastUpdatedAt, liveCount, tombstonedCount
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
            liveCount = try? c.decodeIfPresent(Int.self, forKey: .liveCount)
            tombstonedCount = try? c.decodeIfPresent(Int.self, forKey: .tombstonedCount)
        }
    }

    /// Tolerant on its own: a mistyped stamp is `nil` and never costs the
    /// handshake.
    public struct Medications: Decodable, Sendable, Equatable {
        public let lastUpdatedAt: Date?

        public init(lastUpdatedAt: Date?) {
            self.lastUpdatedAt = lastUpdatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case lastUpdatedAt
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        }
    }

    public struct Measurements: Decodable, Sendable, Equatable {
        public let lastUpdatedAt: Date?
        public let liveCount: Int
        public let tombstonedCount: Int

        public init(lastUpdatedAt: Date?, liveCount: Int, tombstonedCount: Int) {
            self.lastUpdatedAt = lastUpdatedAt
            self.liveCount = liveCount
            self.tombstonedCount = tombstonedCount
        }
    }

    public init(
        userId: String,
        timezone: String,
        lastSyncedAt: Date?,
        serverNow: Date,
        measurements: Measurements,
        medications: Medications? = nil,
        intakes: Intakes? = nil
    ) {
        self.userId = userId
        self.timezone = timezone
        self.lastSyncedAt = lastSyncedAt
        self.serverNow = serverNow
        self.measurements = measurements
        self.medications = medications
        self.intakes = intakes
    }

    private enum CodingKeys: String, CodingKey {
        case userId, timezone, lastSyncedAt, serverNow, measurements, medications, intakes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        timezone = try c.decode(String.self, forKey: .timezone)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        serverNow = try c.decode(Date.self, forKey: .serverNow)
        measurements = try c.decode(Measurements.self, forKey: .measurements)
        medications = try? c.decodeIfPresent(Medications.self, forKey: .medications)
        intakes = try? c.decodeIfPresent(Intakes.self, forKey: .intakes)
    }

    /// Absolute clock-skew in seconds. Positive when the device is
    /// AHEAD of the server. Caller decides what tolerance is "warn".
    public func clockSkewSeconds(now: Date = .now) -> TimeInterval {
        now.timeIntervalSince(serverNow)
    }
}
