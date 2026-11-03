import Foundation

/// Per-day cache for on-device briefings, keyed by
/// `ondevice_briefing.<yyyy-MM-dd>.<lang>`. Entries auto-expire on key
/// change (next-day rollover) — `write` keeps only the most-recent key.
///
/// **1.4 B4 — no writer left.** The on-device briefing hero that read and
/// wrote this cache had no caller and was deleted. The cache stays because an
/// install from an earlier build can still hold a `briefing-cache.json` with
/// health-derived text, and `clearOnLogout()` is what removes it.
///
/// **v0.9.0 — storage moved off `UserDefaults` to a file-protected JSON
/// file** (`Application Support/HealthLog/Briefing/briefing-cache.json`) with
/// `.completeUntilFirstUserAuthentication` protection, matching the Outbox /
/// GLP1 / HKStats stores. The project rule (PROJECT_GUIDE.md) is: no health-derived
/// data in `UserDefaults`; the briefing text is derived from health
/// measurements, so it belongs in the protected app store. A one-time
/// migration drops any legacy `ondevice_briefing.*` `UserDefaults` keys.
///
/// QS-1 reconcile: `@unchecked Sendable` with an `NSLock`-guarded barrier
/// around the whole read-modify-write so concurrent `write` / `clearOnLogout`
/// calls can't interleave the load-dict-then-rewrite-file pattern.
final class OnDeviceBriefingCache: @unchecked Sendable {
    static let shared = OnDeviceBriefingCache()
    private let fileURL: URL?
    private let lock = NSLock()
    private static let legacyPrefix = "ondevice_briefing."

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
                fileURL = directory.appendingPathComponent("briefing-cache.json", isDirectory: false)
            } catch {
                fileURL = nil
            }
        }
    #endif

    func read(for key: String) -> DailyBriefing? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key]
    }

    func write(_ briefing: DailyBriefing, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        // Auto-expire: only the most-recent key survives a write.
        persist([key: briefing])
    }

    /// Drops all cached briefings — called from `AppContainer.handleLocalLogout`
    /// (QC-1 / Arch-H3 reconcile). Previously the cache survived logout,
    /// leaking the previous user's briefing text on the next account that
    /// signed in on the same device.
    func clearOnLogout() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File I/O (caller holds `lock`)

    private func load() -> [String: DailyBriefing] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: DailyBriefing].self, from: data)) ?? [:]
    }

    private func persist(_ entries: [String: DailyBriefing]) {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        do {
            try SensitiveDataBackupExclusion.prepareDirectory(at: dir)
            // Health-derived content at rest → protect until first unlock, the
            // same tier as the Outbox / GLP1 stores (ADR-011/012).
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
    }

    /// One-time sweep of any legacy `ondevice_briefing.*` keys left in
    /// `UserDefaults.standard` by pre-v0.9.0 builds. We don't migrate the
    /// values (a per-day cache is cheap to regenerate); we just clear them so
    /// no health-derived text lingers in the unprotected store.
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
            .appendingPathComponent("Briefing", isDirectory: true)
        do {
            try SensitiveDataBackupExclusion.prepareDirectory(at: directory, fileManager: fm)
        } catch {
            return nil
        }
        return directory
            .appendingPathComponent("briefing-cache.json", isDirectory: false)
    }
}
