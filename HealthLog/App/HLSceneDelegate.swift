#if canImport(UIKit)
    import UIKit

    /// Which orientations a scene allows. Device logic, not layout: the idiom
    /// only tells the iPad, which turns freely, from the phone, which stays
    /// upright except under the full-screen chart and the timeline's full
    /// screen. The plist lets the phone turn at all, because the system cuts
    /// this mask with it; this policy is what keeps every other screen
    /// upright. On the open Duo the system ignores the mask anyway.
    @MainActor
    enum OrientationPolicy {
        /// Set while the full-screen chart is up, through ``allowLandscape(_:)``.
        private(set) static var allowsLandscape = false

        /// The mask for a scene. Pure, so the rule is testable without a scene.
        nonisolated static func mask(isPad: Bool, allowsLandscape: Bool) -> UIInterfaceOrientationMask {
            if isPad { return .all }
            return allowsLandscape ? .allButUpsideDown : .portrait
        }

        /// Whether a screen that needs the width opens across: a phone in
        /// compact width. The open Duo (regular width) and the iPad keep their
        /// page. Pure, so the rule is testable without a scene.
        nonisolated static func opensAcross(isPad: Bool, isCompactWidth: Bool) -> Bool {
            !isPad && isCompactWidth
        }

        /// Whether this device is an iPad. Device logic for the shell, which
        /// injects ``opensAcross(isPad:isCompactWidth:)`` into the screens.
        static var deviceIsPad: Bool {
            UIDevice.current.userInterfaceIdiom == .pad
        }

        /// A turn asked for with a retry, kept until the scene next reads its
        /// mask (``maskAnswered(_:)``): set before the request, so a refusal
        /// that arrives late cannot miss that read. Never a timer.
        private(set) static var retry = OrientationRetry()

        /// Asks every window scene to turn to `mask` (the timeline turns
        /// itself across when it opens and upright when it closes).
        static func requestRotation(
            to mask: UIInterfaceOrientationMask,
            retryWhenAllowed: Bool = false,
            in application: UIApplication = .shared
        ) {
            retry.pending = retryWhenAllowed ? mask : nil
            refreshSupportedOrientations(in: application)
            for scene in application.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                windowScene.requestGeometryUpdate(
                    .iOS(interfaceOrientations: mask),
                    errorHandler: geometryErrorHandler(retry: retryWhenAllowed)
                )
            }
        }

        /// The handler UIKit calls when it refuses a turn, built outside the
        /// main actor: UIKit may call it on any thread, and a closure written
        /// in this main-actor type would trap there under Swift 6. It logs and
        /// hops to the main actor, where a refused turn with a retry makes the
        /// scene read its mask again (and so ask once more).
        nonisolated static func geometryErrorHandler(retry: Bool) -> @Sendable (any Error) -> Void {
            { error in
                // The reason UIKit gives is a fixed system sentence, no record data.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.ui.error("Drehung abgelehnt: \(error.localizedDescription, privacy: .public)")
                guard retry else { return }
                Task { @MainActor in refreshSupportedOrientations() }
            }
        }

        /// The scene read its mask: a refused turn the mask now allows is
        /// asked for once more, then forgotten.
        static func maskAnswered(_ mask: UIInterfaceOrientationMask) {
            guard let turn = retry.answered(mask) else { return }
            Task { @MainActor in requestRotation(to: turn) }
        }

        /// Every window's topmost controller (a presented cover included)
        /// reads its supported orientations again.
        static func refreshSupportedOrientations(in application: UIApplication = .shared) {
            for scene in application.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    var top = window.rootViewController
                    top?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    while let presented = top?.presentedViewController {
                        top = presented
                        presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                    }
                }
            }
        }

        /// Lets the phone turn (`true`) or brings it back upright (`false`)
        /// and asks every window scene to read its mask again. The
        /// full-screen chart calls this in `onAppear` and `onDisappear`.
        static func allowLandscape(_ allowed: Bool, in application: UIApplication = .shared) {
            guard allowsLandscape != allowed else { return }
            allowsLandscape = allowed
            if !allowed { retry.pending = nil }
            refreshSupportedOrientations(in: application)
        }
    }

    /// A turn UIKit refused, asked for once more as soon as the scene's mask
    /// allows it, then forgotten. Pure, so "exactly once" is testable.
    struct OrientationRetry: Equatable {
        var pending: UIInterfaceOrientationMask?

        /// The scene read `mask`: the turn to ask again, if the mask now
        /// allows the pending one. A mask that does not yet allows it keeps
        /// the turn waiting.
        mutating func answered(_ mask: UIInterfaceOrientationMask) -> UIInterfaceOrientationMask? {
            guard let turn = pending, mask.intersection(turn) == turn else { return nil }
            pending = nil
            return turn
        }
    }

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

        /// The privacy cover of this delegate's scene, made when it connects.
        private var privacyCover: PrivacyCoverController?

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
            if let windowScene = scene as? UIWindowScene {
                privacyCover = PrivacyCoverController(scene: windowScene)
            }
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

        // MARK: - Orientation

        /// The orientations of this scene. Replaces the plist value for it:
        /// the iPad turns freely, the phone stays upright unless the
        /// full-screen chart or the timeline's full screen is up. On iOS 26
        /// this is never asked; the app delegate answers the same policy.
        @available(iOS 27.0, *)
        func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
            let mask = OrientationPolicy.mask(
                isPad: windowScene.traitCollection.userInterfaceIdiom == .pad,
                allowsLandscape: OrientationPolicy.allowsLandscape
            )
            // The scene reads its new mask: a turn refused before this may go now.
            OrientationPolicy.maskAnswered(mask)
            return mask
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

    /// Shows and hides a scene's cover window by ``PrivacyCoverPolicy``. It
    /// listens to the lifecycle notifications of every scene, because whether
    /// an iPad scene covers depends on the other scenes of the app too. The
    /// lifecycle callbacks of the scene delegate stay forwarded to the wrapped
    /// delegate untouched.
    @MainActor
    final class PrivacyCoverController: NSObject {
        private weak var scene: UIWindowScene?
        private let window: HLPrivacyCoverWindow

        init(scene: UIWindowScene) {
            self.scene = scene
            window = HLPrivacyCoverWindow(windowScene: scene)
            super.init()
            let center = NotificationCenter.default
            for name in [
                UIScene.willDeactivateNotification,
                UIScene.didActivateNotification,
                UIScene.didEnterBackgroundNotification,
                UIScene.willEnterForegroundNotification
            ] {
                center.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
            }
        }

        var isCovering: Bool {
            window.isShown
        }

        /// The phase a scene is in once `name` has been delivered. A scene's
        /// activation state still shows the old phase while the notification
        /// that announces the change is posted.
        nonisolated static func phase(after name: Notification.Name) -> PrivacyCoverPolicy.Phase? {
            switch name {
            case UIScene.willDeactivateNotification, UIScene.willEnterForegroundNotification: .inactive
            case UIScene.didActivateNotification: .active
            case UIScene.didEnterBackgroundNotification: .background
            default: nil
            }
        }

        nonisolated static func phase(of state: UIScene.ActivationState) -> PrivacyCoverPolicy.Phase {
            switch state {
            case .foregroundActive: .active
            case .foregroundInactive: .inactive
            default: .background
            }
        }

        /// Whether an inactive iPad scene is still a window on screen. A scene
        /// smaller than its screen is a window in Stage Manager or a pane of
        /// Split View: it goes inactive when another window takes the focus
        /// and stays in view, so it keeps its content. A scene that fills the
        /// screen has nothing beside it; inactive, it is on its way into the
        /// app switcher, under the Control Centre or the notifications, and
        /// covers. A point of slack absorbs rounding of the two geometries.
        nonisolated static func staysOnScreen(phase: PrivacyCoverPolicy.Phase, sceneSize: CGSize, screenSize: CGSize) -> Bool {
            guard phase != .background else { return false }
            let fills = sceneSize.width >= screenSize.width - 1 && sceneSize.height >= screenSize.height - 1
            return !fills
        }

        @objc private func sceneChanged(_ notification: Notification) {
            guard let scene else { return }
            let own = (notification.object as? UIScene) === scene
            let phase = (own ? Self.phase(after: notification.name) : nil) ?? Self.phase(of: scene.activationState)
            let anotherSceneActive = UIApplication.shared.connectedScenes.contains { other in
                other !== scene && other is UIWindowScene && other.activationState == .foregroundActive
            }
            window.show(PrivacyCoverPolicy.covers(
                idiom: scene.traitCollection.userInterfaceIdiom == .pad ? .pad : .phone,
                phase: phase,
                anotherSceneActive: anotherSceneActive,
                visibleInForeground: Self.staysOnScreen(
                    phase: phase,
                    sceneSize: scene.effectiveGeometry.coordinateSpace.bounds.size,
                    screenSize: scene.screen.bounds.size
                )
            ))
        }
    }
#endif
