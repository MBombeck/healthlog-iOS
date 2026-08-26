import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping force_try

/// W-INTEGRITY-WRITEPATH G-9 — the recovery open path must distinguish a
/// transient/locked open failure (FAIL SOFT, destroy nothing) from genuine
/// corruption (MOVE ASIDE by rename, never `rm`), so a `BGProcessingTask` wake
/// before first unlock can't irreversibly delete un-synced writes.
@Suite("Outbox recovery — corrupt vs. unavailable (G-9)")
struct OutboxRecoveryMoveAsideTests {
    private struct OpenFailure: Error {}

    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hl-outbox-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("outbox.sqlite")
    }

    // MARK: - classifyOpenFailure

    @Test("No file on disk → transient (nothing to corrupt or delete)")
    func missingFileIsTransient() throws {
        let url = try tempStoreURL() // directory exists, file does not
        let result = ModelContainerRecovery.classifyOpenFailure(OpenFailure(), storeURL: url)
        #expect(result == .transient)
    }

    @Test("Nil store URL → transient (cannot even resolve the path)")
    func nilURLIsTransient() {
        let result = ModelContainerRecovery.classifyOpenFailure(OpenFailure(), storeURL: nil)
        #expect(result == .transient)
    }

    @Test("File present and readable but open failed → corrupt")
    func readableButFailedIsCorrupt() throws {
        let url = try tempStoreURL()
        // Write readable bytes that an SQLite open would reject — readable, so
        // the failure is in the CONTENTS, not in availability → corruption.
        try Data("this is not a valid sqlite database".utf8).write(to: url)
        let result = ModelContainerRecovery.classifyOpenFailure(OpenFailure(), storeURL: url)
        #expect(result == .corrupt)
    }

    // MARK: - moveAsideCorruptStore

    @Test("Move-aside renames the store + sidecars, never deletes the bytes")
    func moveAsidePreservesBytes() throws {
        let url = try tempStoreURL()
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        let original = Data("queued un-synced writes".utf8)
        try original.write(to: url)
        try Data("wal".utf8).write(to: url.deletingPathExtension().appendingPathExtension("sqlite-wal"))
        try Data("shm".utf8).write(to: url.deletingPathExtension().appendingPathExtension("sqlite-shm"))

        let moved = ModelContainerRecovery.moveAsideCorruptStore(at: url, log: HLLog.outbox, subsystem: "Outbox")
        #expect(moved, "the primary store file must be moved aside")

        // Original path is now free for a fresh store...
        #expect(!fm.fileExists(atPath: url.path), "the corrupt file is renamed out of the way")
        // ...and the bytes survive under a `*.corrupt-*` name (recoverable, not rm'd).
        let survivors = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        #expect(survivors.contains { $0.hasSuffix(".sqlite") }, "primary bytes survive under a corrupt-* name")
        #expect(survivors.contains { $0.hasSuffix(".sqlite-wal") }, "-wal sidecar survives")
        #expect(survivors.contains { $0.hasSuffix(".sqlite-shm") }, "-shm sidecar survives")

        // And the surviving primary still holds the un-synced bytes verbatim.
        let survivorPrimary = try #require(survivors.first { $0.hasSuffix(".sqlite") })
        let recovered = try Data(contentsOf: dir.appendingPathComponent(survivorPrimary))
        #expect(recovered == original, "move-aside preserves the exact un-synced bytes")
    }

    @Test("Move-aside on a missing file is a no-op returning false")
    func moveAsideMissingFileIsNoop() throws {
        let url = try tempStoreURL() // no file written
        let moved = ModelContainerRecovery.moveAsideCorruptStore(at: url, log: HLLog.outbox, subsystem: "Outbox")
        #expect(!moved)
    }

    // MARK: - End-to-end: transient recovery does NOT delete the on-disk store

    @Test("Transient classification leaves the on-disk store untouched")
    func transientLeavesStoreOnDisk() throws {
        let url = try tempStoreURL()
        let bytes = Data("survivable queued writes".utf8)
        try bytes.write(to: url)
        // A transient classification (here: simulate sealed/locked by making the
        // file unreadable) must NOT lead to deletion. We assert the contract at
        // the classifier level — the recovery ladder fails soft on `.transient`.
        let result = ModelContainerRecovery.classifyOpenFailure(OpenFailure(), storeURL: url)
        // Readable plaintext bytes classify as corrupt; to model the SEALED case
        // we drop read permission so the read-probe throws → transient.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let sealed = ModelContainerRecovery.classifyOpenFailure(OpenFailure(), storeURL: url)
        // Restore perms so cleanup can remove the temp dir.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(result == .corrupt, "readable bytes → corrupt")
        #expect(sealed == .transient, "unreadable (sealed/locked) bytes → transient, never deleted")
        // The bytes were never removed by classification.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// swiftlint:enable force_unwrapping force_try
