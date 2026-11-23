import Foundation
#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

// MARK: - Wakes at process start, without moving a waiting one

extension BackgroundSyncCoordinator {
    /// The wakes a launch still has to ask for.
    ///
    /// A submit for an identifier that already waits replaces the waiting
    /// request and moves its earliest begin date. HealthKit can start the
    /// process many times an hour, so a launch that submitted every time
    /// would keep pushing the refresh wake (outbox, reminders, medication
    /// reconciliation) into the future. A launch therefore submits only what
    /// is not waiting; the run of a wake submits its successor as before.
    static func wakesToSubmit(pending: Set<String>, registersHealthKitTask: Bool) -> [String] {
        let wanted = registersHealthKitTask
            ? [bgTaskIdentifier, bgRefreshTaskIdentifier]
            : [bgRefreshTaskIdentifier]
        return wanted.filter { !pending.contains($0) }
    }

    /// Asks for each wake that is not waiting yet. For the launch; the view
    /// and the wakes themselves keep using ``scheduleBackgroundWakes()``.
    func scheduleMissingBackgroundWakes() async {
        #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
            let missing = await Self.wakesToSubmit(
                pending: Self.pendingWakeIdentifiers(),
                registersHealthKitTask: registersHealthKitTask
            )
            for identifier in missing {
                if identifier == Self.bgTaskIdentifier {
                    scheduleNextBGSync()
                } else {
                    scheduleNextBGRefresh()
                }
            }
        #endif
    }

    #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
        /// Only the identifiers leave this function: the requests themselves
        /// are not `Sendable`.
        @concurrent
        private nonisolated static func pendingWakeIdentifiers() async -> Set<String> {
            await Set(BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier))
        }
    #endif
}
