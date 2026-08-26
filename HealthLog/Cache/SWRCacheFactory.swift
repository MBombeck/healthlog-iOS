import Foundation
import SwiftData

public extension SWRCache {
    /// Production entry point. Mirrors `OutboxQueue.makeWithRecovery()`.
    /// Tries the persistent store, wipes + retries on failure, falls back to
    /// in-memory so a corrupted cache file never crashes app launch.
    ///
    /// **Note (PA5 v0.5.x):** synchronous shape preserved for compat — the
    /// composition root now prefers `makeWithRecoveryTask()` so the
    /// SwiftData open runs off the launch tick. Tests + macOS targets still
    /// use the sync path because they don't pay for the cold-start budget.
    static func makeWithRecovery() -> SWRCache {
        do {
            return try SWRCache(modelContainer: SWRCache.makePersistent())
        } catch {
            HLLog.cache.error("Cache store unreadable, attempting rebuild: \(LogSanitizer.redact(String(describing: error)))")
            if let storeURL = try? SWRCache.persistentStoreURL() {
                let dir = storeURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
            do {
                return try SWRCache(modelContainer: SWRCache.makePersistent())
            } catch {
                HLLog.cache.error("Cache rebuild also failed, falling back to in-memory: \(LogSanitizer.redact(String(describing: error)))")
                // Non-trapping in-memory floor (audit M2): degrade to an inert
                // empty-schema store instead of `try!`-trapping on the path that
                // exists to avoid a hard launch failure.
                let container = ModelContainerRecovery.recoveredInMemoryContainer(
                    log: HLLog.cache,
                    subsystem: "Cache",
                    build: SWRCache.makeInMemory
                )
                return SWRCache(modelContainer: container)
            }
        }
    }

    /// Detached-Task variant of `makeWithRecovery()`. Schedules the
    /// `ModelContainer` open on a `.userInitiated` detached task so the
    /// 30-80 ms SwiftData open (cold-cache) no longer blocks the launch tick.
    ///
    /// Returned `Task` is consumed by `SWRCoordinator.init(cacheTask:)`,
    /// which lazily awaits the value on first observe. Unlike the Outbox
    /// open — which the BGTaskScheduler contract requires synchronously
    /// before `applicationDidFinishLaunchingWithOptions` returns — the SWR
    /// cache has no launch-tick coupling (PA5 Bottleneck #1).
    static func makeWithRecoveryTask() -> Task<SWRCache, Never> {
        Task.detached(priority: .userInitiated) {
            SWRCache.makeWithRecovery()
        }
    }
}
