#if canImport(UIKit)
    import SwiftUI
    import UIKit

    /// The privacy cover of one scene, in a window of its own above everything
    /// the scene presents: sheets, full screen covers, share and scanner
    /// sheets, alerts and confirmation dialogs. A cover in the SwiftUI tree
    /// lies under all of those, because each is presented above the window
    /// root.
    ///
    /// The window shows ``PrivacyCoverView``, an opaque, PHI-free surface. It
    /// never becomes key and takes no touches, so nothing under it loses its
    /// focus or its input. It appears at once, so a snapshot never catches it
    /// half faded in, and fades out.
    @MainActor
    final class HLPrivacyCoverWindow {
        private let window: UIWindow

        /// How long the cover takes to fade out when the scene is back.
        static let fadeOut: TimeInterval = 0.2

        /// Above alerts, so a system alert of the app is covered too.
        static let level = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)

        init(windowScene: UIWindowScene) {
            window = UIWindow(windowScene: windowScene)
            window.windowLevel = Self.level
            window.isUserInteractionEnabled = false
            window.rootViewController = UIHostingController(rootView: PrivacyCoverView())
            window.isHidden = true
        }

        var isShown: Bool {
            !window.isHidden && window.alpha > 0
        }

        func show(_ shown: Bool) {
            if shown {
                window.layer.removeAllAnimations()
                window.alpha = 1
                window.isHidden = false
                window.layoutIfNeeded()
            } else if !window.isHidden {
                UIView.animate(withDuration: Self.fadeOut) {
                    self.window.alpha = 0
                } completion: { _ in
                    if self.window.alpha == 0 { self.window.isHidden = true }
                }
            }
        }
    }
#endif
