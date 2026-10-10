import Foundation
import Testing

#if canImport(UIKit) && canImport(Spezi) && canImport(SpeziHealthKit) && canImport(SpeziScheduler)
    @testable import HealthLog
    import SpeziScheduler

    /// TestFlight 1.1.1 (292) trapped in `willFinishLaunching` when a
    /// background launch could not prepare the SpeziScheduler directory
    /// (protected data sealed before the first unlock). The launch plan keeps
    /// the guarantee (no PHI scheduler store without verified backup
    /// exclusion) and turns the refusal into a launch without the scheduler.
    @MainActor
    @Suite("SpeziScheduler launch plan (292 background-launch crash)", .serialized)
    struct SpeziSchedulerLaunchPlanTests {
        private struct Sandbox {
            let root: URL
            let documents: URL
            var schedulerDirectory: URL {
                documents.appendingPathComponent(SpeziSchedulerStorage.directoryName, isDirectory: true)
            }

            var database: URL {
                schedulerDirectory.appendingPathComponent(SpeziSchedulerStorage.databaseFilename, isDirectory: false)
            }
        }

        private func makeSandbox() throws -> Sandbox {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("spezi-launch-plan-\(UUID().uuidString)", isDirectory: true)
            let documents = root.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return Sandbox(root: root, documents: documents)
        }

        private func cleanUp(_ sandbox: Sandbox) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sandbox.database.path)
            try? FileManager.default.removeItem(at: sandbox.root)
        }

        /// A file where the directory belongs makes `prepareDirectory` throw,
        /// the same outcome the 292 crash log shows for the sealed container.
        private func blockDirectory(_ sandbox: Sandbox) throws {
            try Data("blocking-file".utf8).write(to: sandbox.schedulerDirectory)
        }

        private func moduleTypes(_ plan: SpeziSchedulerStorage.LaunchPlan) -> [String] {
            SpeziSchedulerStorage.modules(for: plan).map { String(describing: type(of: $0)) }
        }

        @Test("unlocked, fresh install: persistent store below the excluded directory")
        func unlockedFreshInstallIsPersistent() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: true, documentsDirectory: sandbox.documents)

            #expect(plan == .persistent(directory: sandbox.schedulerDirectory))
            let values = try sandbox.schedulerDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }

        @Test("locked after the first unlock: still persistent, the readable store is not gated on isProtectedDataAvailable")
        func lockedAfterFirstUnlockStaysPersistent() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            try FileManager.default.createDirectory(at: sandbox.schedulerDirectory, withIntermediateDirectories: true)
            try Data("sqlite bytes".utf8).write(to: sandbox.database)

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: false, documentsDirectory: sandbox.documents)

            #expect(plan == .persistent(directory: sandbox.schedulerDirectory))
        }

        @Test("empty but readable store file is not mistaken for a sealed one")
        func emptyReadableStoreIsPersistent() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            try FileManager.default.createDirectory(at: sandbox.schedulerDirectory, withIntermediateDirectories: true)
            try Data().write(to: sandbox.database)

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: true, documentsDirectory: sandbox.documents)

            #expect(plan == .persistent(directory: sandbox.schedulerDirectory))
        }

        @Test("protected data unavailable and directory cannot be prepared: no trap, no store, no scheduler modules")
        func sealedDirectoryDefersWithoutStore() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            try blockDirectory(sandbox)

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: false, documentsDirectory: sandbox.documents)

            #expect(plan == .unavailable(.protectedDataUnavailable))
            #expect(SpeziSchedulerStorage.modules(for: plan).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: sandbox.database.path))
        }

        @Test("unlocked but exclusion fails: refuses the PHI store without crashing the app")
        func exclusionFailureWhileUnlockedRefusesStore() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            try blockDirectory(sandbox)

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: true, documentsDirectory: sandbox.documents)

            #expect(plan == .unavailable(.backupExclusionUnverified))
            #expect(SpeziSchedulerStorage.modules(for: plan).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: sandbox.database.path))
        }

        @Test("existing store that cannot be read (sealed) never reaches Scheduler")
        func unreadableExistingStoreIsDeferred() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            try FileManager.default.createDirectory(at: sandbox.schedulerDirectory, withIntermediateDirectories: true)
            try Data("sqlite bytes".utf8).write(to: sandbox.database)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sandbox.database.path)

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: false, documentsDirectory: sandbox.documents)

            #expect(plan == .unavailable(.protectedDataUnavailable))
            #expect(SpeziSchedulerStorage.modules(for: plan).isEmpty)
        }

        @Test("unreadable store refuses even when the label says unlocked: the probe decides, not the flag")
        func unreadableStoreRefusesRegardlessOfFlag() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            try FileManager.default.createDirectory(at: sandbox.schedulerDirectory, withIntermediateDirectories: true)
            try Data("sqlite bytes".utf8).write(to: sandbox.database)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sandbox.database.path)

            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: true, documentsDirectory: sandbox.documents)

            #expect(plan == .unavailable(.protectedDataUnavailable))
            #expect(SpeziSchedulerStorage.modules(for: plan).isEmpty)
        }

        @Test("persistent plan registers Scheduler, SchedulerNotifications and the medication module")
        func persistentPlanRegistersSchedulerModules() throws {
            let sandbox = try makeSandbox()
            defer { cleanUp(sandbox) }
            let plan = SpeziSchedulerStorage.launchPlan(protectedDataAvailable: true, documentsDirectory: sandbox.documents)

            let types = moduleTypes(plan)

            #expect(types == ["Scheduler", "SchedulerNotifications", "MedicationsSchedulerModule"])
            let scheduler = try #require(SpeziSchedulerStorage.modules(for: plan).first as? Scheduler)
            withExtendedLifetime(scheduler) {}
            #expect(try SensitiveDataBackupExclusion.isCoveredByExclusion(sandbox.database))
        }
    }
#endif
