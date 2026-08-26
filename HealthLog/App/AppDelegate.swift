#if canImport(UIKit)
    import UIKit

    /// Bridge-Protokoll, über das die SwiftUI-Welt UIKit-Push-Callbacks empfängt.
    /// `AppContainer.notifications` (NotificationService) implementiert das und wird
    /// beim Composition-Root in `AppDelegate.bridge` injiziert.
    ///
    /// `userInfo` kommt als `[AnyHashable: Any]` von UIKit — wir wrappen das in
    /// `RemoteNotificationUserInfo`, damit der Sprung in einen `Task` Swift 6's
    /// Sendable-Check besteht. Innen extrahieren wir typisierte Werte über
    /// `APNsPayload.parse(...)`.
    protocol AppDelegateBridge: Sendable {
        func didRegister(deviceToken: Data) async
        func didFailToRegister(error: any Error) async
        func didReceiveSilentNotification(userInfo: RemoteNotificationUserInfo) async -> UIBackgroundFetchResult
    }

    /// Sendable-Wrapper um `[AnyHashable: Any]`. Wir tragen das Dictionary
    /// `nonisolated(unsafe)` durch — der Inhalt ist vom System gelieferte Plist-
    /// kompatible Werte (NSString/NSNumber/NSDictionary) und wird nur lesend
    /// konsumiert.
    struct RemoteNotificationUserInfo: @unchecked Sendable {
        let raw: [AnyHashable: Any]

        init(_ raw: [AnyHashable: Any]) {
            self.raw = raw
        }
    }

    /// Pure UIKit-Shim. `@UIApplicationDelegateAdaptor` in `HealthLogApp` instanziert
    /// diesen Delegate genau einmal — der `bridge`-Slot wird vom `AppContainer` im
    /// `init` gesetzt (und ist `nonisolated(unsafe)` weil UIKit-Callbacks vom
    /// Main-Thread kommen, aber Swift 6 die statische Mutable nicht erkennt).
    final class AppDelegate: NSObject, UIApplicationDelegate {
        nonisolated(unsafe) static var bridge: AppDelegateBridge?

        // MARK: - Home-Screen Quick Actions (v0.14.x Q)

        /// Register the three dynamic shortcut items as the app finishes
        /// launching. A cold launch *from* a shortcut also delivers the chosen
        /// item in `launchOptions` (UIKit then suppresses the `performAction`
        /// callback) — we forward it through the same marker hand-off so the
        /// `RootView` consume runs once the auth bootstrap completes.
        func application(
            _ application: UIApplication,
            // The optional dictionary is dictated by the UIApplicationDelegate
            // protocol shape — we cannot collapse it to a non-optional.
            // swiftlint:disable:next discouraged_optional_collection
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            HLQuickActions.register(on: application)
            if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
                HLQuickActions.handle(item)
            }
            return true
        }

        /// Warm-launch / foreground Quick-Action tap. Writes the one-shot
        /// capture marker; `RootView` consumes it on the resulting `.active`
        /// scenePhase tick. The `completionHandler` reports whether the
        /// shortcut was recognised.
        func application(
            _: UIApplication,
            performActionFor shortcutItem: UIApplicationShortcutItem,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(HLQuickActions.handle(shortcutItem))
        }

        func application(
            _: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            // Detach: UIKit-Callback läuft auf Main, async-Bridge-Hop darf
            // hier blocken. Wir kopieren `bridge` vor dem Task-Capture damit
            // `nonisolated(unsafe)` nicht innerhalb des Tasks gelesen wird.
            let bridge = Self.bridge
            Task { await bridge?.didRegister(deviceToken: deviceToken) }
        }

        func application(
            _: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: any Error
        ) {
            let bridge = Self.bridge
            Task { await bridge?.didFailToRegister(error: error) }
        }

        /// Background `content-available: 1` deliveries für silent sync (z.B.
        /// Withings → Server-Anchor → iOS-Pull). 30s Wallclock-Budget; wenn die
        /// Bridge nichts macht returnen wir `.noData`.
        func application(
            _: UIApplication,
            didReceiveRemoteNotification userInfo: [AnyHashable: Any],
            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
        ) {
            let bridge = Self.bridge
            let wrapped = RemoteNotificationUserInfo(userInfo)
            Task {
                let result = await bridge?.didReceiveSilentNotification(userInfo: wrapped) ?? .noData
                completionHandler(result)
            }
        }
    }
#endif
