import Foundation

/// Central backup policy for local health-bearing stores.
///
/// HealthLog does not use CloudKit for these stores, but ordinary files under
/// Application Support and App Group containers are still eligible for device
/// backup unless they carry `NSURLIsExcludedFromBackupKey`. Persistent stores
/// call ``prepareDirectory(at:fileManager:)`` before opening SQLite so the
/// database and every later WAL/SHM sidecar sit below one excluded directory.
/// Standalone payload files use ``secureCreatedItem(at:fileManager:)`` after an
/// atomic write; if the resource value cannot be applied and verified, that
/// newly-created payload is removed instead of being left backup-eligible.
public enum SensitiveDataBackupExclusion {
    public enum Error: Swift.Error, Equatable {
        case itemDoesNotExist(URL)
        case verificationFailed(URL)
    }

    /// Create a sensitive store directory, apply the backup exclusion, and
    /// verify the value before the caller is allowed to create payload files.
    public static func prepareDirectory(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeAndVerify(directory, fileManager: fileManager)
    }

    /// Seal a newly-written standalone payload. On failure, remove only that
    /// payload so the write fails closed rather than leaving PHI eligible for
    /// backup. Directory-backed databases use ``prepareDirectory`` instead.
    public static func secureCreatedItem(
        at item: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: item.path) else {
            throw Error.itemDoesNotExist(item)
        }
        do {
            try excludeAndVerify(item, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: item)
            throw error
        }
    }

    /// Returns true when the item itself or any existing ancestor carries the
    /// exclusion value. This models directory-backed SQLite coverage and is a
    /// deterministic test seam for database, WAL, and SHM paths.
    public static func isCoveredByExclusion(
        _ item: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        var candidate = item.standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: candidate.path) {
                let values = try candidate.resourceValues(forKeys: [.isExcludedFromBackupKey])
                if values.isExcludedFromBackup == true {
                    return true
                }
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return false }
            candidate = parent
        }
    }

    private static func excludeAndVerify(
        _ item: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: item.path) else {
            throw Error.itemDoesNotExist(item)
        }
        try (item as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        let values = try item.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard values.isExcludedFromBackup == true else {
            throw Error.verificationFailed(item)
        }
    }
}
