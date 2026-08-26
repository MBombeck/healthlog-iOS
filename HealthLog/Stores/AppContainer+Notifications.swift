import Foundation

// MARK: - v0.7.3 notifications + badge wiring (cluster C9, UIKit-gated)

#if canImport(UserNotifications) && canImport(UIKit)
    extension AppContainer {
        /// Constructs the APNs `NotificationService`, registers it as the
        /// `AppDelegate` bridge so UIKit push callbacks land on it, and kicks
        /// the one-shot legacy-local-backup purge.
        ///
        /// `AppContainer.init` runs in the `HealthLogApp.init` path — before
        /// `application:didFinishLaunchingWithOptions:` — so setting
        /// `AppDelegate.bridge` here is in time for the first token callback.
        /// The purge is detached so the launch tick doesn't pay for the
        /// UN-center read (gated on a UserDefaults flag inside the helper).
        ///
        /// Factored out of `AppContainer.init` (v0.7.3) to keep the init body
        /// inside its lint budget. The `notifications` handle stays on
        /// `AppContainer`; construction args are VERBATIM from the prior
        /// inline block.
        static func makeNotificationService(
            api: APIClientProtocol,
            environment: AppEnvironment,
            keychain: KeychainStoring,
            deepLinks: DeepLinkRouter,
            backgroundSync: BackgroundSyncCoordinator,
            medicationsRepo: MedicationsRepository
        ) -> NotificationService {
            let notif = NotificationService(
                api: api,
                environment: environment,
                keychain: keychain,
                deepLinks: deepLinks,
                backgroundSync: backgroundSync,
                medicationsRepo: medicationsRepo
            )
            AppDelegate.bridge = notif
            // v0.6.0.7 Spezi Phase E — one-shot purge of any stale
            // `med-local-backup-*` pending requests left over from the legacy
            // `MedicationReminderScheduler` orchestrator path (never wired in
            // production, but defensive).
            Task.detached {
                await NotificationService.purgeLegacyLocalBackupsIfNeeded()
            }
            return notif
        }

        /// Wires the badge-recompute path between `MedicationsStore` and the
        /// `NotificationService`, coalesced through the single-slot
        /// `BadgeRefreshCoalescer`.
        ///
        /// **v0.6.1.3 Y4.1 + Y8.** The store fires `onIntakesDidChange` after
        /// every load + mark + synth mutation; the closure recomputes
        /// `dueOrMissedCount` and pushes the absolute number to the system
        /// icon. A single Genommen tap can fire 2-3 times (optimistic patch →
        /// server confirm → invalidate), so the coalescer cancels any pending
        /// task and replaces it — only the last winner runs; iOS still
        /// coalesces identical badge values internally so no drift risk. The
        /// `medicationsStoreAccessor` lets the willPresent delegate hook read
        /// the live store without an import cycle (foreground-banner badge
        /// recompute).
        ///
        /// All captures stay `[weak]` exactly as the prior inline block: a
        /// container disposal must not extend either reference's lifetime.
        /// The `coalescer` is captured by value (a reference type). Called at
        /// the same post-store-construction position as before, so the
        /// topological order is unchanged.
        static func wireBadgeRefresh(
            notifications: NotificationService,
            medicationsStore: MedicationsStore,
            coalescer: BadgeRefreshCoalescer
        ) {
            medicationsStore.onIntakesDidChange = { [weak notifications, weak medicationsStore] in
                guard let notifications, let medicationsStore else { return }
                coalescer.schedule { [weak notifications, weak medicationsStore] in
                    guard let notifications, let medicationsStore else { return }
                    await notifications.refreshBadge(from: medicationsStore)
                }
            }
            notifications.medicationsStoreAccessor = { [weak medicationsStore] in
                medicationsStore
            }
        }
    }
#endif
