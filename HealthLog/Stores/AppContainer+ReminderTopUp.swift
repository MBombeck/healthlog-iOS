import Foundation

extension AppContainer {
    /// **R5** — wire the cache-only reminder top-up into every background wake
    /// the app gets without being opened: both BGTasks, every silent push and
    /// every action on a medication reminder (the last two reach it through
    /// `NotificationService.backgroundSync`). The store is `@MainActor`, so the
    /// `@Sendable` hook hops there and awaits the reconcile inline, before the
    /// BGTask or the push completion is reported. The weak capture makes a
    /// torn-down container a no-op.
    static func wireReminderTopUpHook(
        backgroundSync: BackgroundSyncCoordinator,
        medicationsStore: MedicationsStore
    ) {
        backgroundSync.attachReminderTopUpHook { [weak medicationsStore] in
            _ = await medicationsStore?.topUpRemindersFromCache()
        }
    }
}
