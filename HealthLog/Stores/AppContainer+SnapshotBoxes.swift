import Foundation

/// v0.5.5.6 RECONCILE-CELEBRATE — late-bound snapshot pointer.
///
/// `MeasurementsStore` is built before `PersonalRecordsStore` exists in
/// `AppContainer.init`, so we can't capture the store directly at
/// construction time. The box gives us a stable reference the closure
/// holds; the actual `read` accessor is wired post-construction once
/// `serverStatsStores` lands. Calls before the late-bind safely return
/// `[]` (no celebration), which is the right semantic for the boot
/// window before any commit can fire.
@MainActor
final class PersonalRecordsSnapshotBox {
    var read: () -> [PersonalRecord] = { [] }

    var records: [PersonalRecord] {
        read()
    }
}

#if canImport(UserNotifications) && canImport(UIKit)
    /// Y8 — single-slot Task coalescer for the badge refresh dispatch.
    /// A single Genommen tap can fire `onIntakesDidChange` 2-3 times
    /// (optimistic patch → server confirm → invalidate); spawning a
    /// fresh unstructured Task per call hammered
    /// UNUserNotificationCenter.setBadgeCount with identical values.
    /// The coalescer cancels any pending Task and replaces it so only
    /// the last winner runs; iOS still coalesces identical badge
    /// values internally, so behaviour-correctness is preserved.
    /// `@MainActor` so the slot mutation matches the dispatch site's
    /// isolation without any hops.
    @MainActor
    final class BadgeRefreshCoalescer {
        private var pending: Task<Void, Never>?

        func schedule(_ work: @escaping @Sendable () async -> Void) {
            pending?.cancel()
            pending = Task { @MainActor in
                await work()
            }
        }
    }
#endif
