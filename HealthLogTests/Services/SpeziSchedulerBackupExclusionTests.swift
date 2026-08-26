import Foundation
import Testing

#if canImport(SpeziScheduler)
    @testable import HealthLog
    import SpeziScheduler

    @MainActor
    @Suite("SpeziScheduler PHI backup exclusion", .serialized)
    struct SpeziSchedulerBackupExclusionTests {
        private func makeTemporaryDocumentsDirectory() throws -> (root: URL, documents: URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("spezi-scheduler-backup-\(UUID().uuidString)", isDirectory: true)
            let documents = root.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return (root, documents)
        }

        @Test("Documents/SpeziScheduler is excluded and covers its SQLite sidecars")
        func exactDirectoryAndSidecarsAreCovered() throws {
            let temporary = try makeTemporaryDocumentsDirectory()
            defer { try? FileManager.default.removeItem(at: temporary.root) }

            let directory = try SpeziSchedulerStorage.prepareDirectory(
                documentsDirectory: temporary.documents
            )

            #expect(directory == temporary.documents.appendingPathComponent("SpeziScheduler", isDirectory: true))
            #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

            for filename in [
                "edu.stanford.spezi.scheduler.storage.sqlite",
                "edu.stanford.spezi.scheduler.storage.sqlite-wal",
                "edu.stanford.spezi.scheduler.storage.sqlite-shm"
            ] {
                let file = directory.appendingPathComponent(filename, isDirectory: false)
                try Data(filename.utf8).write(to: file)
                #expect(try SensitiveDataBackupExclusion.isCoveredByExclusion(file))
            }
        }

        @Test("real Scheduler opens its database only below the excluded directory")
        func realSchedulerUsesExcludedDirectory() throws {
            let temporary = try makeTemporaryDocumentsDirectory()
            defer { try? FileManager.default.removeItem(at: temporary.root) }

            let scheduler = try SpeziSchedulerStorage.makeScheduler(
                documentsDirectory: temporary.documents
            )
            withExtendedLifetime(scheduler) {}

            let database = temporary.documents
                .appendingPathComponent("SpeziScheduler", isDirectory: true)
                .appendingPathComponent("edu.stanford.spezi.scheduler.storage.sqlite", isDirectory: false)
            #expect(FileManager.default.fileExists(atPath: database.path))
            #expect(try SensitiveDataBackupExclusion.isCoveredByExclusion(database))
        }

        @Test("blocked SpeziScheduler directory fails before a database can be created")
        func blockedDirectoryFailsClosed() throws {
            let temporary = try makeTemporaryDocumentsDirectory()
            defer { try? FileManager.default.removeItem(at: temporary.root) }
            let directory = temporary.documents.appendingPathComponent("SpeziScheduler", isDirectory: true)
            try Data("blocking-file".utf8).write(to: directory)

            #expect(throws: (any Error).self) {
                _ = try SpeziSchedulerStorage.makeScheduler(documentsDirectory: temporary.documents)
            }

            let database = directory.appendingPathComponent(
                "edu.stanford.spezi.scheduler.storage.sqlite",
                isDirectory: false
            )
            #expect(!FileManager.default.fileExists(atPath: database.path))
        }
    }
#endif
