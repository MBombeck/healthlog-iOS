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
        measurements: Measurements
    ) {
        self.userId = userId
        self.timezone = timezone
        self.lastSyncedAt = lastSyncedAt
        self.serverNow = serverNow
        self.measurements = measurements
    }

    /// Absolute clock-skew in seconds. Positive when the device is
    /// AHEAD of the server. Caller decides what tolerance is "warn".
    public func clockSkewSeconds(now: Date = .now) -> TimeInterval {
        now.timeIntervalSince(serverNow)
    }
}
