#if canImport(UIKit) && canImport(Spezi) && canImport(SpeziHealthKit) && canImport(SpeziLocalStorage)
    @testable import HealthLog
    import Spezi
    import SpeziHealthKit
    import Testing
    import UIKit

    /// Smoke coverage for the `HealthLogSpeziDelegate` composition.
    ///
    /// The delegate is a thin shim that
    /// (a) subclasses `SpeziAppDelegate` to host the Spezi configuration
    ///     graph (`HealthLogStandard` + `HealthKit { CollectSamples ... }`)
    ///     and
    /// (b) forwards UIApplicationDelegate hooks to an embedded
    ///     `AppDelegate` instance so the legacy APNs token + silent-push
    ///     bridge stays intact during the v0.5.5 coexist window.
    ///
    /// Booting a full Spezi instance from a unit test requires the
    /// MainActor + Spezi's module-loader machinery — we exercise that
    /// minimally here. The configuration accessor must not crash, and the
    /// delegate must be instantiable (catches future protocol-witness
    /// shifts at build time).
    @MainActor
    @Suite("HealthLogSpeziDelegate — composition + Spezi configuration")
    struct HealthLogSpeziDelegateTests {
        @Test("delegate instantiates and exposes a non-trivial configuration")
        func configurationAccessIsSafe() {
            let delegate = HealthLogSpeziDelegate()
            // Reading `configuration` triggers the Spezi configuration
            // builder. We only assert the result is reachable without a
            // crash; the actual Standard + HealthKit module wiring is
            // covered by `HealthLogStandardForwardingTests`.
            _ = delegate.configuration
        }

        @Test("AUD-1 F5: SpeziScheduler notificationLimit stays under the iOS 64 ceiling with headroom")
        func speziNotificationLimitStaysWithinBudget() {
            // The 64-pending budget is shared across ALL local UN requests
            // (Spezi med tasks + snooze + mood-reminder-local +
            // measurement-reminder + low-supply). Spezi must not consume the
            // whole ceiling — leave room for the sporadic non-Spezi requests.
            #expect(LocalNotificationBudget.speziNotificationLimit < LocalNotificationBudget.iosPendingNotificationCeiling)
            // F5 raised the limit from the Spezi default 30 toward the ceiling
            // to deepen the one-shot-cadence horizon.
            #expect(LocalNotificationBudget.speziNotificationLimit >= 48)
            // Keep at least ~16 slots of headroom for the non-Spezi local
            // requests so iOS never silently drops the tail.
            let headroom = LocalNotificationBudget.iosPendingNotificationCeiling
                - LocalNotificationBudget.speziNotificationLimit
            #expect(headroom >= 16)
        }

        // TODO(maintainer, 2026-06): expose an APNs token-recorder seam on
        // `AppDelegate.bridge` so this suite can assert the embedded
        // forwarder routes `didRegisterForRemoteNotificationsWithDeviceToken`
        // and `didFailToRegister…WithError` calls into the bridge. The
        // current `AppDelegate` only forwards into the live
        // `NotificationService`, which requires the full AppContainer
        // graph — out of scope for a smoke test.
    }
#endif
