import Foundation
import Synchronization

/// **V1 (1.2, #66 / HealthLog#1173) — when each `stats:` type last reached the
/// server, and which trigger carried it.**
///
/// The session counters in ``HKSyncDiagnostics`` start from zero on every cold
/// launch, and a day on the charger is many launches. The question an
/// acceptance screenshot has to answer ("did the day totals and pulse buckets
/// arrive without a manual sync?") therefore needs a record that survives the
/// process: per HealthKit identifier the last accepted upload with its time,
/// its trigger and its row count, plus the last daily-statistics sweep.
///
/// One JSON value per account under `hl.healthkit.statsUploadLog.<token>`, the
/// same partition token the backfill window and the daily-stats one-shot use,
/// so an account reads only its own record. Counts and fixed trigger words
/// only; no value and no day.
struct HealthKitStatsUploadLog: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var at: Date
        /// A ``SyncTrigger`` raw value. Kept as text so a record written by a
        /// later build with a new word still decodes.
        var trigger: String
        var count: Int
    }

    /// Last accepted upload per HealthKit identifier.
    var uploads: [String: Entry] = [:]
    /// Last daily-statistics sweep that ran to its end; `count` is the rows it
    /// uploaded (0 when every day was unchanged).
    var lastSweep: Entry?
}

enum HealthKitStatsUploadLogStore {
    static let keyPrefix = "hl.healthkit.statsUploadLog."

    /// Read-modify-write from two actors (daily statistics, pulse buckets).
    private static let lock = Mutex(())

    static func key(ownerID: String?) -> String {
        keyPrefix + HealthKitBackfillWindowStore.partitionToken(for: ownerID)
    }

    static func load(ownerID: String?, defaults: UserDefaults = .standard) -> HealthKitStatsUploadLog {
        lock.withLock { _ in read(ownerID: ownerID, defaults: defaults) }
    }

    static func recordUpload(
        identifier: String,
        count: Int,
        trigger: SyncTrigger,
        at date: Date,
        ownerID: String?,
        defaults: UserDefaults = .standard
    ) {
        guard count > 0 else { return }
        update(ownerID: ownerID, defaults: defaults) { log in
            log.uploads[identifier] = .init(at: date, trigger: trigger.rawValue, count: count)
        }
    }

    static func recordSweep(
        uploaded: Int,
        trigger: SyncTrigger,
        at date: Date,
        ownerID: String?,
        defaults: UserDefaults = .standard
    ) {
        update(ownerID: ownerID, defaults: defaults) { log in
            log.lastSweep = .init(at: date, trigger: trigger.rawValue, count: uploaded)
        }
    }

    private static func update(
        ownerID: String?,
        defaults: UserDefaults,
        _ change: (inout HealthKitStatsUploadLog) -> Void
    ) {
        lock.withLock { _ in
            var log = read(ownerID: ownerID, defaults: defaults)
            change(&log)
            if let data = try? JSONEncoder().encode(log) {
                defaults.set(data, forKey: key(ownerID: ownerID))
            }
        }
    }

    private static func read(ownerID: String?, defaults: UserDefaults) -> HealthKitStatsUploadLog {
        guard let data = defaults.data(forKey: key(ownerID: ownerID)),
              let log = try? JSONDecoder().decode(HealthKitStatsUploadLog.self, from: data) else
        {
            return HealthKitStatsUploadLog()
        }
        return log
    }
}
