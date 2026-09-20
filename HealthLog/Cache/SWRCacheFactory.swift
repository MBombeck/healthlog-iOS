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
        #if DEBUG
            // 1.0.3 (App Review 1.4.1) — the citation-evidence capture must read
            // its OWN fixtures. SWR is cache-first, and the gate simulator is
            // reused across runs: a row written when a route still answered `{}`
            // would otherwise paint an evidence screenshot that no longer matches
            // the fixtures behind it. Determinism hygiene for the capture, added
            // while diagnosing a missing citation whose actual cause turned out
            // to be the AI-consent gate — kept because a screenshot bound for
            // Apple should be a function of the build, not of what an earlier run
            // left on that simulator. In-memory for THAT run only; every other
            // test keeps the disk cache and its coverage of it.
            // The literal, not `CitationFixtures.isActive`: this file compiles
            // into targets that do not build `HealthLog/App/`.
            if ProcessInfo.processInfo.arguments.contains("-uitest-citations"),
               let container = try? SWRCache.makeInMemory()
            {
                return SWRCache(modelContainer: container)
            }
        #endif
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
