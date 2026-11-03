#if canImport(UIKit)
    import UIKit

    /// **1.4 — the scene delegate that receives Home-Screen quick actions.**
    ///
    /// A scene-based app gets a quick action tapped while it runs through
    /// `windowScene(_:performActionFor:completionHandler:)` on its scene
    /// delegate; `application(_:performActionFor:)` is not called for it (the
    /// iOS 26 SDK marks that path deprecated in favour of the scene one). Up to
    /// 1.3 HealthLog only implemented the app-delegate path, so a long-press
    /// shortcut most likely just opened the app.
    ///
    /// **It wraps the delegate it replaces.** The app delegate's scene
    /// configuration already names a delegate class: Spezi's, which hands the
    /// scene lifecycle to Spezi modules. AccessGuards depends on it, it times
    /// its re-lock from `sceneDidEnterBackground`. This type keeps one instance
    /// of that class and forwards every callback it does not handle itself
    /// through the Objective-C runtime (`responds(to:)` and
    /// `forwardingTarget(for:)`), so the module lifecycle keeps running
    /// unchanged and nothing is listed twice.
    final class HLSceneDelegate: NSObject, UIWindowSceneDelegate {
        /// The class the app delegate would have installed. Recorded by
        /// ``configure(_:)`` before UIKit creates the first instance; written
        /// and read on the main thread only.
        nonisolated(unsafe) static var wrappedDelegateClass: AnyClass?

        /// Spezi's own scene delegate, by its runtime name. The fallback when
        /// this process did not configure the scene: UIKit keeps a scene session
        /// across launches and reconnects it with the configuration it stored,
        /// without asking the app delegate again, so ``configure(_:)`` may not
        /// have run. Pinned by `HLSceneDelegateTests`.
        nonisolated static let speziSceneDelegateClassName = "Spezi.SpeziSceneDelegate"

        /// One instance of the wrapped class, the target of every forwarded
        /// callback. Set once in `init`.
        private nonisolated(unsafe) let wrapped: NSObject?

        override nonisolated init() {
            let wrappedClass: AnyClass? = Self.wrappedDelegateClass ?? NSClassFromString(Self.speziSceneDelegateClassName)
            wrapped = (wrappedClass as? NSObject.Type)?.init()
            super.init()
        }

        /// Installs this delegate in `configuration` and remembers the class it
        /// replaces, so the replaced one keeps receiving its callbacks.
        static func configure(_ configuration: UISceneConfiguration) -> UISceneConfiguration {
            if let current = configuration.delegateClass, current != HLSceneDelegate.self {
                wrappedDelegateClass = current
            }
            configuration.delegateClass = HLSceneDelegate.self
            return configuration
        }

        // MARK: - Quick actions

        /// Cold launch into a stored scene session: UIKit hands the shortcut to
        /// the scene here and does not call the app delegate's configuration
        /// method again. A new session gets it in both places; the marker is
        /// one-shot, so writing it twice opens the capture surface once.
        func scene(
            _ scene: UIScene,
            willConnectTo session: UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            HLLog.ui.info("Scene verbunden: Kurzbefehle über HLSceneDelegate")
            if let item = connectionOptions.shortcutItem {
                HLQuickActions.handle(item)
            }
            (wrapped as? UISceneDelegate)?.scene?(scene, willConnectTo: session, options: connectionOptions)
        }

        /// Warm launch: a shortcut tapped while the app runs.
        func windowScene(
            _: UIWindowScene,
            performActionFor shortcutItem: UIApplicationShortcutItem,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(HLQuickActions.handle(shortcutItem))
        }

        // MARK: - Forwarding to the wrapped delegate

        override nonisolated func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || wrapped?.responds(to: aSelector) == true
        }

        override nonisolated func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let wrapped, wrapped.responds(to: aSelector) {
                return wrapped
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
#endif
