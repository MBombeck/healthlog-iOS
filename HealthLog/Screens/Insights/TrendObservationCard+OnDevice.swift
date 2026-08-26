import Foundation

/// In-memory + UserDefaults-backed cache for resolved on-device
/// observations. One entry per `metric.locale.yyyy-MM-dd`. Single global
/// instance — the cache itself has no per-card state. Same pattern as
/// `OnDeviceBriefingCache` (I-1).
///
/// QS-1 reconcile: `@unchecked Sendable` swapped for an `NSLock`-guarded
/// barrier around mutations so write + clearOnLogout don't race on the
/// `UserDefaults.dictionaryRepresentation()` snapshot.
final class TrendObservationCache: @unchecked Sendable {
    static let shared = TrendObservationCache()

    private let fileURL: URL?
    private let lock = NSLock()
    private static let legacyPrefix = "trend_observation_cache."

    /// Designated init resolves the protected on-disk store + runs the
    /// one-time legacy `UserDefaults` migration. The DEBUG `init(directory:)`
    /// is a test seam pointing at a throwaway temp directory.
    private init() {
        fileURL = Self.defaultStoreURL()
        migrateLegacyUserDefaultsIfNeeded()
    }

    #if DEBUG
        init(directory: URL) {
            do {
                try SensitiveDataBackupExclusion.prepareDirectory(at: directory)
                fileURL = directory.appendingPathComponent("trend-cache.json", isDirectory: false)
            } catch {
                fileURL = nil
            }
        }
    #endif

    func read(for cacheKey: String) -> TrendObservation? {
        lock.lock()
        defer { lock.unlock() }
        return load()[cacheKey]?.toObservation()
    }

    func write(_ observation: TrendObservation, for cacheKey: String) {
        lock.lock()
        defer { lock.unlock() }
        // Multiple metrics are cached for the same day (one entry per
        // `metric.locale.date`), so merge into the dict rather than expiring
        // to a single key.
        var entries = load()
        entries[cacheKey] = CachedObservation(from: observation)
        persist(entries)
    }

    /// Drops every cached trend observation — called from
    /// `AppContainer.handleLocalLogout` (QC-1 / Arch-H3 reconcile).
    /// Previously the previous user's trend strings (and metric kinds)
    /// would survive logout and surface on the next account that signed
    /// in on the same device.
    func clearOnLogout() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File I/O (caller holds `lock`)

    private func load() -> [String: CachedObservation] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedObservation].self, from: data)) ?? [:]
    }

    private func persist(_ entries: [String: CachedObservation]) {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        do {
            try SensitiveDataBackupExclusion.prepareDirectory(at: dir)
            // QoS-M1 (v0.12 P3): health-derived trend text at rest → protect until
            // first unlock, the same tier as the Outbox / briefing stores
            // (ADR-011/012). Previously this cache sat in unprotected UserDefaults.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
    }

    /// One-time sweep of any legacy `trend_observation_cache.*` keys left in
    /// `UserDefaults.standard` by pre-v0.12 builds. The per-day cache is cheap
    /// to regenerate, so we just clear the unprotected copies rather than
    /// migrate the values.
    private func migrateLegacyUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let dict = defaults.dictionaryRepresentation()
        for key in dict.keys where key.hasPrefix(Self.legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func defaultStoreURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = appSupport
            .appendingPathComponent("HealthLog", isDirectory: true)
            .appendingPathComponent("Trends", isDirectory: true)
        do {
            try SensitiveDataBackupExclusion.prepareDirectory(at: directory, fileManager: fm)
        } catch {
            return nil
        }
        return directory
            .appendingPathComponent("trend-cache.json", isDirectory: false)
    }

    private struct CachedObservation: Codable {
        let observation: String
        let metric: String
        let delta: Double?
        let direction: String
        let confidence: Float
        let safetyApplied: Bool

        init(from observation: TrendObservation) {
            self.observation = observation.observation
            metric = observation.metric.rawValue
            delta = observation.delta
            direction = observation.direction.rawValue
            confidence = observation.confidence
            safetyApplied = observation.safetyApplied
        }

        func toObservation() -> TrendObservation? {
            guard let metricKind = MetricKind(rawValue: metric),
                  let dir = TrendObservationDirection(rawValue: direction) else
            {
                return nil
            }
            return TrendObservation(
                observation: observation,
                metric: metricKind,
                delta: delta,
                direction: dir,
                confidence: confidence,
                safetyApplied: safetyApplied
            )
        }
    }
}
