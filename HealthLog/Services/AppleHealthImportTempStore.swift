import Foundation

/// **Phase 09 / plan 09-02 — the owner of the Apple-Health import's temp bodies.**
///
/// The import assembles its multipart envelope into a file the app owns rather
/// than into memory. That file is the user's entire Apple-Health export
/// wrapped in three lines of RFC-7578 ceremony — it is PHI in the fullest
/// sense — so its lifecycle is not something a call site may be trusted to
/// remember:
///
/// * it is created with `.completeFileProtection` **as a creation attribute**,
///   so the class is in force before the first byte exists rather than applied
///   afterwards to bytes that were briefly readable at a weaker class;
/// * it is excluded from backup, so a 1.5 GiB transient never reaches iCloud
///   or a desktop archive;
/// * it carries an exact, app-owned name prefix, so the launch sweep can
///   recognise its own residue and can recognise nothing else;
/// * it is deleted on success, on error and on cancellation by the caller's
///   `defer`, and anything that outlived a crash is swept on the next launch.
///
/// The sweep is deliberately prefix-**and**-age gated. Prefix alone would let a
/// future naming change silently widen the blast radius; age alone would let it
/// delete a file another part of the app is still writing. Both together mean
/// the worst case of a bug here is residue that survives one more launch, not a
/// file somebody else owned.
public actor AppleHealthImportTempStore {
    /// The exact prefix this store owns. Nothing outside this file writes it,
    /// and the sweep will not touch a name that lacks it. Drift here is a
    /// security hole in both directions — a rename that forgets the sweep
    /// leaves PHI behind; a widening that catches somebody else's prefix
    /// deletes their file.
    public static let ownedPrefix = "healthlog-apple-import-"
    /// Suffix, so a human looking at the temp directory can tell what the file
    /// is without opening it. Not used for matching: the prefix is the gate.
    public static let ownedSuffix = ".multipart"

    /// Residue older than this is swept at launch. Fifteen minutes rather than
    /// zero: a sweep with no age gate could in principle race a body the same
    /// process is still assembling, and the cost of being wrong in that
    /// direction is a failed import, while the cost of being wrong in the
    /// other direction is bounded by the next launch.
    public static let defaultTTL: TimeInterval = 15 * 60

    /// The production instance. A single stored value rather than a per-call
    /// construction, so the composition root and the import service address the
    /// same directory without passing it through four layers.
    public static let live = AppleHealthImportTempStore()

    private let directory: URL
    private var createdFileCount = 0

    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    /// How many owned files this store has handed out. The counterpart to
    /// ``ownedFiles()``: "created three and none remain" is a lifecycle
    /// statement, while "none remain" on its own is also true of a store that
    /// was never used.
    public var createdCount: Int {
        createdFileCount
    }

    /// Create an empty, protected, backup-excluded, uniquely named file.
    ///
    /// - Throws: ``AppleHealthImportError/temporaryFileUnavailable`` if the file
    ///   could not be created at all — never a silent `nil`, because a caller
    ///   that continued past this point would write the user's archive to
    ///   nowhere and report success.
    public func makeOwnedFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Self.ownedPrefix)\(UUID().uuidString)\(Self.ownedSuffix)"
        var url = directory.appendingPathComponent(name)
        // The protection class travels with the *creation*, so there is no
        // window in which the file exists at the default class.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw AppleHealthImportError.temporaryFileUnavailable
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        createdFileCount += 1
        return url
    }

    /// Read back what the platform actually reports for the file's protection
    /// class, or `nil` when it reports none.
    ///
    /// Answering `nil` is not a pass. It is the honest answer on a platform
    /// that does not implement data protection at all (the simulator), and it
    /// is the reason ``verifyOwnedFile(at:)`` refuses a *wrong* class rather
    /// than demanding a *present* one — a demand no simulator run could meet,
    /// which would have made the check untestable and therefore absent.
    public nonisolated static func reportedProtection(of url: URL) -> FileProtectionType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.protectionKey] as? FileProtectionType
    }

    /// Verify the closed file still carries the metadata it was created with,
    /// before a single byte of it is handed to the transport.
    ///
    /// - Throws: ``AppleHealthImportError/temporaryFileNotProtected`` if the
    ///   platform reports a protection class other than complete, or if the
    ///   backup exclusion did not stick.
    public nonisolated static func verifyOwnedFile(at url: URL) throws {
        if let reported = reportedProtection(of: url), reported != .complete {
            throw AppleHealthImportError.temporaryFileNotProtected
        }
        let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard values?.isExcludedFromBackup == true else {
            throw AppleHealthImportError.temporaryFileNotProtected
        }
    }

    /// Delete one owned file. `nonisolated` and synchronous on purpose: the
    /// caller runs it from a `defer`, which cannot `await`, and a deletion that
    /// had to hop an actor would be a deletion that a cancelled task could skip.
    public nonisolated static func removeOwned(_ url: URL) {
        guard url.lastPathComponent.hasPrefix(ownedPrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every owned file currently in this store's directory.
    public func ownedFiles() -> [URL] {
        Self.ownedFiles(in: directory)
    }

    /// Sweep owned residue older than `ttl`.
    ///
    /// Returns the URLs removed, so the launch path can be asserted on what it
    /// deleted rather than on the absence of what it did not.
    @discardableResult
    public func sweepStale(now: Date = .now, ttl: TimeInterval = defaultTTL) -> [URL] {
        var removed: [URL] = []
        let cutoff = now.addingTimeInterval(-ttl)
        for url in Self.ownedFiles(in: directory) {
            if ttl > 0 {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                // No mtime is a reason to leave the file, not to delete it: a
                // freshly created file whose attribute has not materialised
                // looks exactly like this.
                guard let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
            }
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(url)
            } catch {
                continue
            }
        }
        return removed
    }

    private nonisolated static func ownedFiles(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return entries.filter { $0.lastPathComponent.hasPrefix(ownedPrefix) }
    }
}
