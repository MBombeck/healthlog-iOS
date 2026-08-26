import Foundation
@testable import HealthLog
import Testing

@Suite("Sensitive local data is excluded from device backups", .serialized)
struct SensitiveDataBackupExclusionTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("prepared sensitive directory is excluded and covers SQLite sidecars")
    func directoryExclusionCoversDescendants() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HealthLog/Cache", isDirectory: true)

        try SensitiveDataBackupExclusion.prepareDirectory(at: directory)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        for name in ["cache.sqlite", "cache.sqlite-wal", "cache.sqlite-shm"] {
            let item = directory.appendingPathComponent(name, isDirectory: false)
            try Data(name.utf8).write(to: item)
            #expect(try SensitiveDataBackupExclusion.isCoveredByExclusion(item))
        }
    }

    @Test("preparing an existing directory is idempotent")
    func preparingExistingDirectoryIsIdempotent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HealthLog/Standalone", isDirectory: true)

        try SensitiveDataBackupExclusion.prepareDirectory(at: directory)
        try SensitiveDataBackupExclusion.prepareDirectory(at: directory)

        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("directory preparation fails closed before a payload can be created")
    func invalidDirectoryFailsClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("sentinel".utf8).write(to: blockingFile)
        let sensitiveDirectory = blockingFile.appendingPathComponent("HealthLog/Outbox", isDirectory: true)

        #expect(throws: (any Error).self) {
            try SensitiveDataBackupExclusion.prepareDirectory(at: sensitiveDirectory)
        }
        #expect(!FileManager.default.fileExists(atPath: sensitiveDirectory.path))
    }

    @Test("real Outbox ModelContainer initializes only under an excluded App Group directory")
    func persistentOutboxInitializationUsesExcludedDirectory() throws {
        let appGroup = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appGroup) }

        let storeURL = try OutboxStore.persistentStoreURL(appGroupContainer: appGroup)
        let directory = storeURL.deletingLastPathComponent()
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        _ = try OutboxStore.makePersistent(storeURL: storeURL)
        #expect(try SensitiveDataBackupExclusion.isCoveredByExclusion(storeURL))
    }

    @Test("health-bearing App Group payload receives a direct exclusion attribute")
    func widgetPendingPayloadIsExcluded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("widget-pending-confirm.json")
        let store = WidgetPendingConfirmStore(url: file)

        try store.arm(
            medicationId: "med-1",
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_000),
            now: Date(timeIntervalSince1970: 1_799_999_999)
        )

        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}
