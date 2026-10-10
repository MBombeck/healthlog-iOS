// SpeziScheduler's on-disk PHI store and the per-launch decision whether this
// process may open it. Split out of `HealthLogSpeziDelegate.swift` in 1.2.
#if canImport(UIKit) && canImport(Spezi) && canImport(SpeziScheduler)
    import BackgroundTasks
    import Foundation
    @_spi(APISupport) import Spezi
    import SpeziScheduler

    /// Owns the at-rest policy for SpeziScheduler's medication `Task` and
    /// `Outcome` database. The directory must be excluded before creating
    /// `Scheduler`, because its initializer opens SwiftData immediately.
    enum SpeziSchedulerStorage {
        static let directoryName = "SpeziScheduler"
        static let databaseFilename = "edu.stanford.spezi.scheduler.storage.sqlite"
        /// SpeziScheduler's own notification top-up `BGAppRefreshTask`
        /// (`PermittedBackgroundTaskIdentifier` in SpeziScheduler 1.2.20).
        static let notificationRefreshTaskIdentifier = "edu.stanford.spezi.scheduler.notifications-scheduling"

        /// Why a launch runs without SpeziScheduler.
        enum Unavailability: Equatable {
            /// Data protection still seals the store: a background launch
            /// before the first unlock after a reboot. Transient; the next
            /// process opens the store normally.
            case protectedDataUnavailable
            /// The device is unlocked, yet the exclusion could not be applied
            /// and verified. The PHI database stays closed rather than being
            /// created or opened backup-eligible.
            case backupExclusionUnverified
        }

        /// What this process does with SpeziScheduler. Decided once, in
        /// `willFinishLaunching`, because Spezi builds its module graph there
        /// and `BGTaskScheduler` refuses handler registration after launch, so
        /// the scheduler cannot be added to the running graph later.
        enum LaunchPlan: Equatable {
            /// Open the on-disk store below this excluded, verified directory.
            case persistent(directory: URL)
            /// Run this process without SpeziScheduler. Pending reminders are
            /// left exactly as they are; nothing is planned, removed or
            /// re-armed until a process opens the persistent store again.
            case unavailable(Unavailability)
        }

        nonisolated static func prepareDirectory(
            documentsDirectory: URL = .documentsDirectory,
            fileManager: FileManager = .default
        ) throws -> URL {
            let directory = documentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
            try SensitiveDataBackupExclusion.prepareDirectory(at: directory, fileManager: fileManager)
            return directory
        }

        nonisolated static func makeScheduler(
            documentsDirectory: URL = .documentsDirectory,
            fileManager: FileManager = .default
        ) throws -> Scheduler {
            let directory = try prepareDirectory(
                documentsDirectory: documentsDirectory,
                fileManager: fileManager
            )
            return Scheduler(persistence: .onDisk(directory: directory))
        }

        /// Decide whether this launch may open the PHI scheduler store.
        ///
        /// TestFlight 1.1.1 (292) crashed here: a background launch before
        /// the first unlock could not prepare the directory and the old
        /// fail-closed path trapped the whole process. The guarantee is
        /// unchanged (no store without verified exclusion); the refusal now
        /// degrades this launch instead of killing it.
        ///
        /// `protectedDataAvailable` (`UIApplication.isProtectedDataAvailable`)
        /// only labels the reason. It reports the `.complete` class and is
        /// false whenever the device is locked, while these files use the
        /// default `completeUntilFirstUserAuthentication` class and stay
        /// readable on a locked device after the first unlock. Gating on it
        /// would switch reminders off in every locked background launch, so
        /// the decision is the actual exclusion and a read probe of the store.
        nonisolated static func launchPlan(
            protectedDataAvailable: Bool,
            documentsDirectory: URL = .documentsDirectory,
            fileManager: FileManager = .default
        ) -> LaunchPlan {
            let directory: URL
            do {
                directory = try prepareDirectory(documentsDirectory: documentsDirectory, fileManager: fileManager)
            } catch {
                return .unavailable(protectedDataAvailable ? .backupExclusionUnverified : .protectedDataUnavailable)
            }
            let database = directory.appendingPathComponent(databaseFilename, isDirectory: false)
            guard storeIsReadableOrAbsent(database, fileManager: fileManager) else {
                return .unavailable(.protectedDataUnavailable)
            }
            return .persistent(directory: directory)
        }

        /// A store sealed by data protection exists but cannot be read.
        /// SwiftData would fail to open it, and SpeziScheduler's notification
        /// pass removes every pending reminder before it reads the store, so a
        /// sealed store must never reach `Scheduler`.
        nonisolated static func storeIsReadableOrAbsent(_ database: URL, fileManager: FileManager) -> Bool {
            guard fileManager.fileExists(atPath: database.path) else { return true }
            guard let handle = try? FileHandle(forReadingFrom: database) else { return false }
            defer { try? handle.close() }
            // An empty but readable file returns nil without throwing; only a
            // throwing read means the bytes are sealed.
            do {
                _ = try handle.read(upToCount: 1)
                return true
            } catch {
                return false
            }
        }

        /// The scheduler modules this launch registers. Empty for an
        /// unavailable store: `MedicationsSchedulerModule` would otherwise
        /// pull in a default `Scheduler()` (on disk, without the exclusion
        /// check), and an in-memory scheduler would let SpeziScheduler's
        /// refresh wipe the pending reminders and re-arm none.
        @MainActor
        static func modules(for plan: LaunchPlan) -> [any Module] {
            guard case let .persistent(directory) = plan else { return [] }
            return [
                Scheduler(persistence: .onDisk(directory: directory)),
                // See the note at the call site in `configuration`.
                SchedulerNotifications(
                    notificationLimit: LocalNotificationBudget.speziNotificationLimit,
                    schedulingInterval: .seconds(8 * 7 * 24 * 60 * 60),
                    notificationPresentation: [.banner, .list, .sound],
                    automaticallyRequestProvisionalAuthorization: false
                ),
                MedicationsSchedulerModule()
            ]
        }

        /// Log why the scheduler is off for this process.
        static func logUnavailable(_ reason: Unavailability) {
            switch reason {
            case .protectedDataUnavailable:
                HLLog.notifications.info(
                    "SpeziScheduler deferred: store sealed by data protection; reminders unchanged until the next launch"
                )
            case .backupExclusionUnverified:
                HLLog.notifications.fault(
                    "SpeziScheduler disabled: backup exclusion could not be verified; medication reminders are not planned"
                )
            }
        }

        /// Without SpeziScheduler nobody registers its top-up task, but the
        /// system may still deliver one submitted by an earlier process.
        /// Answer it without touching the pending reminders.
        static func registerUnavailableRefreshHandler(bundle: Bundle = .main) {
            let permitted = bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
            guard permitted?.contains(notificationRefreshTaskIdentifier) == true else { return }
            _ = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: notificationRefreshTaskIdentifier,
                using: .main
            ) { task in
                task.setTaskCompleted(success: false)
            }
        }
    }
#endif
