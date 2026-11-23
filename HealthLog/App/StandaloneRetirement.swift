import Foundation

/// What an install from the time of the offline mode may still carry, and the
/// two ways it is cleaned up.
///
/// The offline ("standalone") mode was never reachable in an App Store build,
/// but TestFlight builds up to b197 could store it. Such an install now starts
/// at the server sign-in like any signed-out install. Its local records stay on
/// disk until the user asks for local data to be removed; they are not read
/// again, and Welcome says so while they are there.
enum StandaloneRetirement {
    /// `UserDefaults.standard` keys the mode wrote. None of them is read any
    /// more, so removing them on launch leaves every later launch identical.
    static let legacyDefaultsKeys = [
        "hl.syncMode",
        "hl.onboarding.mode",
        "hl.disclaimer.standaloneAckVersion"
    ]

    /// The two mode keys and the raw value they held while the mode was on.
    static let legacyModeKeys = ["hl.syncMode", "hl.onboarding.mode"]
    static let legacyModeValue = "standalone"

    /// Set once when an install that still ran the mode meets this build with
    /// its records on disk. Outlives the mode keys, which are dropped right
    /// after, so Welcome can still tell this install apart.
    static let leftoverDataKey = "hl.standaloneRetirement.leftoverData"

    /// Folder under Application Support that held the offline records
    /// (`standalone.sqlite` with its `-shm` / `-wal` siblings).
    static let legacyStoreFolder = "HealthLog/Standalone"
    static let legacyStoreFile = "standalone.sqlite"

    /// Runs on every launch after the launch prologue (the fresh-install guard
    /// still reads two of the mode keys as evidence of an earlier launch).
    ///
    /// The file alone is not enough: an install that moved to a server kept it
    /// (the adopt upload left the local mirror in place as its offline cache and
    /// for the idempotent re-run), but its mode keys already read `paired` /
    /// `server`. Only a mode that was still on marks the records as leftover.
    static func retireStoredMode(
        in defaults: UserDefaults,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let modeWasOn = legacyModeKeys.contains { defaults.string(forKey: $0) == legacyModeValue }
        if modeWasOn, storeExists(applicationSupport: applicationSupport, fileManager: fileManager) {
            defaults.set(true, forKey: leftoverDataKey)
        }
        for key in legacyDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether Welcome shows the note about the leftover records.
    static func showsLeftoverDataNotice(
        defaults: UserDefaults,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        defaults.bool(forKey: leftoverDataKey)
            && storeExists(applicationSupport: applicationSupport, fileManager: fileManager)
    }

    /// Deletes the offline records and the note about them. Called by the paths
    /// that remove all local data of an account (account deletion, server
    /// switch), as before.
    static func removeLocalStore(
        defaults: UserDefaults = .standard,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        defaults.removeObject(forKey: leftoverDataKey)
        guard let folder = storeFolder(applicationSupport: applicationSupport, fileManager: fileManager),
              fileManager.fileExists(atPath: folder.path) else { return }
        try fileManager.removeItem(at: folder)
    }

    private static func storeFolder(applicationSupport: URL?, fileManager: FileManager) -> URL? {
        guard let base = applicationSupport
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(legacyStoreFolder, isDirectory: true)
    }

    private static func storeExists(applicationSupport: URL?, fileManager: FileManager) -> Bool {
        guard let folder = storeFolder(applicationSupport: applicationSupport, fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(atPath: folder.appendingPathComponent(legacyStoreFile).path)
    }
}
