// Phase 07 Wave 2 removed the blanket file-length suppression that used to head
// this file. It was there because the Spezi config DSL enumerated one
// `CollectSamples` per HealthKit type and the collector list alone ran ~200
// lines. Those declarations are gone, the file is well inside the budget, and a
// suppression nobody needs is a gate nobody checks.
#if canImport(UIKit) && canImport(Spezi) && canImport(SpeziHealthKit)
    import HealthKit
    @_spi(APISupport) import Spezi
    import SpeziHealthKit
    import UIKit
    #if canImport(SpeziBluetooth) && canImport(SpeziDevices)
        import SpeziBluetooth
        import SpeziBluetoothServices
        import SpeziDevices
    #endif
    #if canImport(SpeziOmron)
        import SpeziOmron
    #endif
    #if canImport(SpeziAccessGuard)
        import SpeziAccessGuard
    #endif
    #if canImport(SpeziLLM)
        import SpeziLLM
    #endif
    #if canImport(SpeziLLMLocal)
        import SpeziLLMLocal
    #endif
    #if canImport(SpeziScheduler)
        // v0.6.0.7 — module-qualified import. `SpeziScheduler.Task` is a
        // `@Model` class that name-collides with Swift's `_Concurrency.Task`.
        // The unqualified `import SpeziScheduler` would force every Spezi-
        // scheduling site to spell out `_Concurrency.Task` for the
        // structured-concurrency Task, which is much more invasive than
        // qualifying the small set of references to the scheduler's Task.
        // Other consumers of `Task` in this file keep referring to the
        // standard-library Task without ambiguity.
        import SpeziScheduler
    #endif

    #if canImport(SpeziScheduler)
        /// Owns the at-rest policy for SpeziScheduler's medication `Task` and
        /// `Outcome` database. The directory must be excluded before creating
        /// `Scheduler`, because its initializer opens SwiftData immediately.
        enum SpeziSchedulerStorage {
            static let directoryName = "SpeziScheduler"
            static let databaseFilename = "edu.stanford.spezi.scheduler.storage.sqlite"

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

            /// The Spezi configuration builder cannot throw. Refuse to create
            /// the PHI database if its enclosing directory cannot be excluded
            /// and verified, matching SpeziScheduler's own fail-fast handling
            /// for persistent-directory creation and migration failures.
            nonisolated static func makeDefaultSchedulerOrFailClosed() -> Scheduler {
                do {
                    return try makeScheduler()
                } catch {
                    preconditionFailure("Refusing to open SpeziScheduler without verified backup exclusion: \(error)")
                }
            }
        }
    #endif

    /// **v0.15.5 AUD-1 F5 — shared local-notification budget accounting.**
    ///
    /// iOS pends at most 64 *local* notification requests per app, and every
    /// local scheduler the app runs draws from this single budget:
    /// SpeziScheduler med tasks (``speziNotificationLimit``) + snooze
    /// (`NotificationService+Handler`/`+MoodActions`) + the
    /// `mood-reminder-local` evening nudge + measurement-reminder + low-supply.
    /// SpeziScheduler is capped below the ceiling so those sporadic, mostly
    /// single-instance non-Spezi requests always have room and iOS never
    /// silently drops the tail.
    enum LocalNotificationBudget {
        /// The hard iOS per-app pending-local-notification ceiling.
        static let iosPendingNotificationCeiling = 64

        /// The pre-scheduled-notification horizon SpeziScheduler materializes.
        /// Raised 30 → 48 (AUD-1 F5) to deepen the one-shot-cadence horizon
        /// while leaving `iosPendingNotificationCeiling − speziNotificationLimit`
        /// (= 16) slots of headroom for the non-Spezi local requests above.
        static let speziNotificationLimit = 48
    }

    /// `SpeziAppDelegate` subclass that boots SpeziHealthKit alongside the
    /// legacy `AppDelegate`-based APNs bridge.
    ///
    /// **Composition rather than replacement:**
    /// SwiftUI's `@UIApplicationDelegateAdaptor` allows exactly one delegate
    /// class. To both (a) host Spezi's configuration graph and (b) preserve
    /// the existing APNs token + silent-push bridge that powers HP5
    /// MOOD_REMINDER and the silent-sync push path, we subclass
    /// `SpeziAppDelegate` and explicitly forward UIKit callbacks to an
    /// embedded `AppDelegate` instance.
    ///
    /// **Why not pull the APNs forwarders into Spezi's notification system?**
    /// Spezi's `NotificationHandler` protocol is a clean module-side surface,
    /// but adopting it would require refactoring `NotificationService` to
    /// register as a Spezi module. That refactor lives in a later phase
    /// (Spezi adoption for Notifications is not on the v0.5.5 plan — see
    /// `docs/spezi-migration-plan.md`). Until then, composition keeps the
    /// existing path bit-for-bit identical while Spezi owns authorization.
    ///
    /// **Lifecycle order on cold launch:**
    /// 1. SwiftUI instantiates the delegate.
    /// 2. UIKit calls `application(_:willFinishLaunchingWithOptions:)` →
    ///    super boots Spezi → loads `HealthLogStandard` and the `HealthKit`
    ///    module. Since Phase 07 Wave 2 that module registers no
    ///    `CollectSamples`: it provides authorization and readiness, and the
    ///    app-owned ``AnchoredHealthSampleCollector`` performs collection.
    /// 3. UIKit calls `application(_:didFinishLaunchingWithOptions:)` →
    ///    SwiftUI builds the scene → `HealthLogApp.init` constructs
    ///    `AppContainer`, which sets `AppDelegate.bridge` on the static and
    ///    installs the app-owned sample collection.
    /// 4. APNs token callback eventually fires and lands in our forwarder
    ///    below, which routes to `apnsDelegate` which reads the static.
    ///
    /// Nothing in this delegate migrates a cursor any more. The Phase-07
    /// migration is per account, not per launch: it needs an authenticated owner
    /// and a bearer, so it runs from
    /// ``AppOwnedHealthCollectionCoordinator`` on the first trigger of a session
    /// (see ``SpeziAnchorMigrator/migrateAccountCursors(types:store:requiring:)``).
    final class HealthLogSpeziDelegate: SpeziAppDelegate {
        /// Embedded legacy delegate. UIKit hands us the lifecycle callbacks
        /// directly (via the overrides below), but we keep the `AppDelegate`
        /// instance around so any future call-sites that read
        /// `appDelegate.bridge` from the SwiftUI adaptor continue to work.
        /// The actual APNs bridge is on `AppDelegate.bridge` (static), which
        /// `AppContainer.init` populates at composition time.
        private let apnsDelegate = AppDelegate()

        /// Spezi configuration: `HealthLogStandard` plus the Spezi modules the app
        /// genuinely uses — authorization and the HealthKit module itself,
        /// AccessGuard, Scheduler, Devices/Bluetooth, and the LLM runner.
        ///
        /// **Phase 07 Wave 2 — the server-bound `CollectSamples` registrations are
        /// gone.** All thirty-five of them were removed in one commit, and nothing
        /// replaced them inside this DSL. The reason is a property of
        /// SpeziHealthKit 1.4.2 (`a86db5c`) rather than a preference: its collector
        /// reads the stored anchor, runs the query, awaits `handleNewSamples`, and
        /// then persists the query's new anchor *unconditionally*. The app cannot
        /// veto that write, and it cannot recover from it either — the page was
        /// produced by a query that already ran. Every durability rule Phase 07
        /// owes (commit only on exact terminal acceptance or a durable retry, hold
        /// across cancellation and a lost lease, resume per account rather than per
        /// installation) is therefore unenforceable from inside the callback.
        ///
        /// ``AnchoredHealthSampleCollector`` now issues those queries, under the
        /// authenticated account's own `{owner, source, type}` partitions and the
        /// 7/30/90/365-day cutoff that account chose. It reuses this Standard's
        /// mapping through ``HealthSamplePageConsuming``, so what goes on the wire
        /// is unchanged; only who owns the cursor has moved.
        ///
        /// The `HealthKit` module stays registered. It is what asks the user for
        /// authorization, what `HKReadinessStore` reads to decide readiness, and
        /// what the `SpeziHealthKitUI` surfaces bind to. It simply no longer
        /// collects.
        ///
        /// `HealthLogStandard` also stays: it is the `Standard` the Spezi graph is
        /// built around, it still owns `handleDeletedObjects` (Apple-Health
        /// deletions mirrored to the server), it still rewrites SpeziScheduler's
        /// medication banners, and it is still the single implementation of the
        /// sample mapping the app-owned collector calls.
        override var configuration: Configuration {
            Configuration(standard: HealthLogStandard()) {
                // Authorization + module value only. Phase 07 Wave 2 removed every
                // server-bound `CollectSamples`; see the note above.
                HealthKit()
                #if canImport(SpeziAccessGuard)
                    // GH issue #8 Path 2 — register the SpeziAccessGuard
                    // module for **per-feature** sensitive surfaces only.
                    // The app-root lock stays on the custom `BiometricGate`
                    // in `RootView` (W1j logout escape hatch, unified
                    // biometric+device-passcode via
                    // `.deviceOwnerAuthentication`); issue blockers B1-B4
                    // apply to that root surface and are untouched here.
                    //
                    // `BiometricAccessGuard` evaluates
                    // `.deviceOwnerAuthenticationWithBiometrics`; on
                    // devices without enrolled biometrics SpeziAccessGuard
                    // falls back to an app-level passcode (numeric 6,
                    // one-time setup flow) — acceptable for these opt-in
                    // deep surfaces, NOT for the root (B3). The 5-minute
                    // timeout matches SpeziAccessGuard's default and means
                    // one Face ID prompt covers a whole export/share
                    // session instead of re-prompting per screen.
                    AccessGuards {
                        BiometricAccessGuard(
                            .sensitiveScreens,
                            timeout: .minutes(5),
                            fallback: .regular(format: .numeric(6))
                        )
                    }
                #endif
                #if canImport(SpeziScheduler)
                    // v0.6.0.7 Spezi Phase E — register the SpeziScheduler
                    // module as the local-reminder engine for medication
                    // doses. The default `Scheduler()` persists `Task` +
                    // `Outcome` records under
                    // `~/Documents/SpeziScheduler/edu.stanford.spezi.scheduler.storage.sqlite`,
                    // survives launches, and does **not** sync via
                    // CloudKit (we're server-first; the server owns the
                    // medication schedule of record).
                    //
                    // `SchedulerNotifications` is autoconfigured by
                    // `Scheduler` unless we register an override. We
                    // register the override here to disable
                    // `automaticallyRequestProvisionalAuthorization` —
                    // `NotificationService.requestAuthorization(allow-
                    // CriticalAlerts:)` is our single source of truth
                    // for UN authorization (operator gates it from
                    // Settings + onboarding). Letting Spezi also request
                    // provisional auth would race the user's explicit
                    // choice + bypass the consent UI.
                    //
                    // v0.15.5 AUD-1 F5 / v0.14.1 notifications-bug H3 —
                    // `notificationLimit: 48` + `schedulingInterval: 8 weeks`.
                    // Raised from the Spezi default 30 toward the iOS 64-pending
                    // ceiling so a deeper horizon of future med occurrences is
                    // materialized ahead, shrinking the window in which a
                    // non-repeating cadence (everyNWeeks>1 / everyNMonths>1 /
                    // rolling / cyclic / day-29–31 monthly) can drain dry before
                    // the next background top-up. The window was widened 4 → 8
                    // weeks to MATCH `MedicationsSchedulerModule.preArmHorizon`,
                    // so the H3 pre-armed `.once` runway (up to
                    // `maxPreArmedOccurrences` future occurrences per slot) all
                    // falls inside the window SpeziScheduler turns into pending
                    // `UNNotificationRequest`s. Daily / weekly / monthly / yearly
                    // stay single OS-repeating triggers regardless of the window
                    // (1 slot each), so the widening only adds individual
                    // triggers for the genuinely non-repeating cadences — exactly
                    // the intended background runway. The 64-pending budget is
                    // SHARED across every local UN request the app schedules:
                    // Spezi med tasks (this limit) + snooze
                    // (`NotificationService+Handler`/`+MoodActions`) + the
                    // `mood-reminder-local` evening nudge + measurement-reminder
                    // + low-supply. 48 leaves ~16 slots of headroom for those
                    // sporadic, mostly single-instance local requests; bumping
                    // higher risks Spezi crowding the shared ceiling and iOS
                    // silently dropping the tail. `[.banner, .list, .sound]`
                    // matches what `NotificationService.userNotification-
                    // Center(_:willPresent:)` returns for foreground
                    // deliveries, so the foreground-presentation contract
                    // stays consistent.
                    SpeziSchedulerStorage.makeDefaultSchedulerOrFailClosed()
                    // v0.6.1.3 Y4.1 — drop `.badge` from the presentation
                    // set so a foreground-arriving Spezi-scheduled banner
                    // doesn't trigger the system's auto-badge bump. The
                    // App-Badge is now driven centrally from
                    // `MedicationsStore.dueOrMissedCount` via
                    // `NotificationService.refreshBadge(from:)` so it
                    // stays a single authoritative number rather than
                    // incrementing per delivered notification.
                    SchedulerNotifications(
                        notificationLimit: LocalNotificationBudget.speziNotificationLimit,
                        schedulingInterval: .seconds(8 * 7 * 24 * 60 * 60),
                        notificationPresentation: [.banner, .list, .sound],
                        automaticallyRequestProvisionalAuthorization: false
                    )
                    // `MedicationsSchedulerModule` reads
                    // `MedicationsStore.medications` after every load and
                    // reconciles the active set onto Spezi `Task` records.
                    // The store reference is injected from
                    // `AppContainer+MedicationsScheduler.swift` once
                    // `MedicationsStore` exists; until then the module
                    // sits idle (no `Task`s are created).
                    MedicationsSchedulerModule()
                #endif
                #if canImport(SpeziBluetooth) && canImport(SpeziDevices)
                    // v0.6.0.5 F.2 — declare the discovery profile for the
                    // Omron blood-pressure cuff. SpeziBluetooth still
                    // lazily allocates `CBCentralManager` only when a
                    // `scanNearbyDevices` / `powerOn()` mounts (e.g. the
                    // `AccessorySetupSheet` does so via `.scanNearbyDevices(with:)`),
                    // so registering this profile alone does not fire the
                    // BLE permission prompt — the prompt fires the first
                    // time the operator opens Settings → Geräte and taps
                    // "Gerät hinzufügen". Once paired, `HealthMeasurements`
                    // observes `BloodPressureService.bloodPressureMeasurement`
                    // changes (wired in `OmronBloodPressureCuff.configure()`
                    // upstream) and prepends each reading to its
                    // `pendingMeasurements` queue, which the F.2 forwarder
                    // drains into the same `MeasurementBatchUploader` /
                    // `HealthKitWireConverter` pipeline the rest of the app
                    // already uses.
                    //
                    // `PairedDevices()` + `HealthMeasurements()` were
                    // registered as part of F.1 scaffolding and keep their
                    // zero-arg shape (`required init()` upstream).
                    #if canImport(SpeziOmron)
                        Bluetooth {
                            Discover(
                                OmronBloodPressureCuff.self,
                                by: .advertisedService(BloodPressureService.self)
                            )
                        }
                    #else
                        Bluetooth {}
                    #endif
                    PairedDevices()
                    HealthMeasurements()
                #endif
                #if canImport(SpeziLLM) && canImport(SpeziLLMLocal) && !targetEnvironment(simulator)
                    // v0.5.7 G.1 — register the SpeziLLM `LLMRunner`
                    // with the `LLMLocalPlatform()` adapter. On iOS 26+
                    // (Apple-Intelligence-eligible hardware with the
                    // model downloaded) the platform routes through
                    // Apple FoundationModels' `SystemLanguageModel`.
                    // On iOS 18 / 25 / non-eligible devices the
                    // platform stays registered but the
                    // `LLMLocalSession` API surfaces `.unavailable` so
                    // the AskCoach kill-card renders the "Coming Soon"
                    // panel instead of attempting a request.
                    //
                    // **Why `!targetEnvironment(simulator)`?**
                    // SpeziLLM 0.13.x's `LLMLocalPlatform` is the
                    // MLX-Swift-backed adapter (Foundation-Models bridge
                    // landing in a future Spezi minor). MLX on iOS
                    // simulator self-disables and logs:
                    // `"SpeziLLMLocal is only supported on physical
                    // devices. A mock session will be used instead."`
                    // — but the surrounding module boot path then
                    // crashes during Spezi's `configure()` /
                    // `LLMInferenceQueue.runQueue()` hop because the
                    // mock fallback never lands. Gating the
                    // registration on physical-device builds keeps the
                    // Spezi delegate test suite green + lets the
                    // simulator continue to drive the rest of the app
                    // (HealthKit, Devices) untouched. The kill-card
                    // surface in `LocalLLMService` independently
                    // probes `SystemLanguageModel.default.availability`
                    // so the AskCoach hero still renders the correct
                    // "device-not-eligible" branch on the simulator
                    // without needing the LLMRunner to be registered.
                    //
                    // The `if #available(iOS 26.0, *)` guard keeps the
                    // module out of the Spezi graph on pre-26 runtimes
                    // entirely — pre-26 has no FoundationModels symbol
                    // table so loading `LLMLocalPlatform` would dynamic-
                    // link a missing framework. The compile-time
                    // `canImport(SpeziLLM)` outer fence keeps the
                    // dependency optional for build configurations
                    // (Mac Catalyst, future targets) that may want to
                    // exclude the SpeziLLM product.
                    //
                    // G.3 will wire `LLMLocalSession` into
                    // `AskCoachStore`; G.1 only proves the registration
                    // path compiles + the SPM graph resolves.
                    if #available(iOS 26.0, *) {
                        LLMRunner {
                            LLMLocalPlatform()
                        }
                    }
                #endif
            }
        }

        // MARK: - Lifecycle

        /// SpeziAppDelegate's `application(_:willFinishLaunchingWithOptions:)`
        /// is deprecation-annotated upstream as part of a "propagate
        /// deprecation" pattern, but it is the canonical seam Spezi uses to
        /// initialize its module graph (Sources/Spezi/Spezi/SpeziAppDelegate.swift
        /// line 105). Suppressing the deprecation warning is intentional —
        /// there is no alternative entry-point until Spezi removes the
        /// deprecation, at which point we will follow the upstream rename.
        @available(*, deprecated)
        override func application(
            _ application: UIApplication,
            // The optional dictionary is dictated by the UIApplicationDelegate
            // protocol shape — we cannot collapse it to a non-optional.
            // swiftlint:disable:next discouraged_optional_collection
            willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            // Super initializes Spezi + loads modules.
            let result = super.application(application, willFinishLaunchingWithOptions: launchOptions)
            // v0.14.x Q — register Home-Screen Quick Actions + handle a
            // cold-launch-from-shortcut. UIKit delivers the chosen shortcut in
            // `launchOptions` on a cold launch (and then suppresses the
            // `performAction` callback), so we forward it through the same
            // marker hand-off; `RootView`'s consume runs once auth bootstraps.
            HLQuickActions.register(on: application)
            if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
                HLQuickActions.handle(item)
            }
            return result
        }

        // MARK: - Home-Screen Quick Actions (v0.14.x Q)

        /// Warm-launch / foreground Quick-Action tap. Writes the one-shot
        /// `CaptureRequestStore` marker; `RootView` consumes it on the resulting
        /// `.active` scenePhase tick and routes via `AppRouter`. Single capture
        /// hand-off path shared with the central CapturePicker + the Erfassen
        /// control. The `completionHandler` reports whether the shortcut was
        /// recognised (UIKit's contract).
        ///
        /// Not an `override` — `SpeziAppDelegate` does not declare this optional
        /// `UIApplicationDelegate` method, so we provide a fresh implementation
        /// that UIKit dispatches via the Obj-C runtime. `@objc` makes it visible
        /// to that dispatch.
        @objc
        func application(
            _: UIApplication,
            performActionFor shortcutItem: UIApplicationShortcutItem,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(HLQuickActions.handle(shortcutItem))
        }

        // MARK: - Remote Notifications (APNs preservation)

        override func application(
            _ application: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            // Spezi forwards the token to its own `NotificationTokenHandler`
            // pipeline. We also need to wake our existing bridge so the
            // legacy NotificationService (still authoritative for token
            // upload to the HealthLog server) sees the same token.
            super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
            apnsDelegate.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
        }

        override func application(
            _ application: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: any Error
        ) {
            super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
            apnsDelegate.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
        }

        /// Silent `content-available` deliveries for server-driven sync
        /// (e.g. Withings -> Server -> iOS pull). SpeziAppDelegate exposes
        /// only the async form of this hook (UIKit runtime de-duplicates
        /// the completion-handler + async selectors as the same Obj-C
        /// `application:didReceiveRemoteNotification:fetchCompletionHandler:`)
        /// — so we override the async form, then route to the legacy
        /// `AppDelegate`'s completion-handler implementation via a
        /// continuation. The legacy path drives `NotificationService` which
        /// is still authoritative for HP5 MOOD_REMINDER + silent-sync
        /// delivery during the v0.5.5 coexist window. Spezi's own
        /// `notificationHandler` chain is intentionally bypassed here —
        /// no Spezi module currently registers as a handler.
        override func application(
            _ application: UIApplication,
            didReceiveRemoteNotification userInfo: [AnyHashable: Any]
        ) async -> UIBackgroundFetchResult {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIBackgroundFetchResult, Never>) in
                apnsDelegate.application(
                    application,
                    didReceiveRemoteNotification: userInfo,
                    fetchCompletionHandler: { result in
                        continuation.resume(returning: result)
                    }
                )
            }
        }
    }
#endif
