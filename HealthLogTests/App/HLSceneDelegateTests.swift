#if canImport(UIKit)
    import Foundation
    @testable import HealthLog
    import Testing
    import UIKit

    /// **1.4 — Home-Screen quick actions through the scene.**
    ///
    /// A scene-based app receives a quick action through its scene, never
    /// through `application(_:performActionFor:)`. These pin the routing that
    /// can run without a device: the scene configuration installs
    /// ``HLSceneDelegate`` and keeps the delegate it replaces (Spezi's, which
    /// AccessGuards relies on) receiving its callbacks, the delegate answers the
    /// warm-launch selector, and a shortcut becomes the capture marker
    /// `RootView` consumes. A real long-press stays on the device checklist.
    @MainActor
    @Suite("HLSceneDelegate — quick actions through the scene", .serialized)
    struct HLSceneDelegateTests {
        /// Restores the process-wide wrapped class after each test.
        private func withWrappedClass(_ body: () throws -> Void) rethrows {
            let previous: AnyClass? = HLSceneDelegate.wrappedDelegateClass
            defer { HLSceneDelegate.wrappedDelegateClass = previous }
            try body()
        }

        @Test("the scene configuration installs HLSceneDelegate and remembers the class it replaces")
        func configurationWrapsTheBaseDelegate() {
            withWrappedClass {
                let base = UISceneConfiguration(name: nil, sessionRole: .windowApplication)
                base.delegateClass = RecordingSceneDelegate.self

                let configured = HLSceneDelegate.configure(base)

                #expect(configured.delegateClass == HLSceneDelegate.self)
                #expect(HLSceneDelegate.wrappedDelegateClass == RecordingSceneDelegate.self)
                // Configuring an already configured scene keeps the original.
                _ = HLSceneDelegate.configure(configured)
                #expect(HLSceneDelegate.wrappedDelegateClass == RecordingSceneDelegate.self)
            }
        }

        @Test("lifecycle callbacks reach the wrapped delegate")
        func lifecycleIsForwarded() {
            withWrappedClass {
                HLSceneDelegate.wrappedDelegateClass = RecordingSceneDelegate.self
                RecordingSceneDelegate.reset()
                let delegate = HLSceneDelegate()
                let background = #selector(UISceneDelegate.sceneDidEnterBackground(_:))
                let foreground = #selector(UISceneDelegate.sceneWillEnterForeground(_:))

                #expect(delegate.responds(to: background))
                _ = delegate.perform(background, with: nil)
                _ = delegate.perform(foreground, with: nil)

                #expect(RecordingSceneDelegate.calls == ["background", "foreground"])
                // What neither implements is not claimed.
                #expect(!delegate.responds(to: #selector(UISceneDelegate.sceneDidDisconnect(_:))))
            }
        }

        @Test("without a configuration in this process the delegate wraps Spezi's scene delegate")
        func fallbackWrapsSpezisDelegate() throws {
            try withWrappedClass {
                HLSceneDelegate.wrappedDelegateClass = nil
                // The class Spezi installs, by the name the fallback uses. A
                // renamed class fails here instead of silently dropping the
                // scene lifecycle AccessGuards re-locks from.
                let spezi: AnyClass = try #require(NSClassFromString(HLSceneDelegate.speziSceneDelegateClassName))
                let background = #selector(UISceneDelegate.sceneDidEnterBackground(_:))
                #expect(class_respondsToSelector(spezi, background))
                #expect(HLSceneDelegate().responds(to: background))
            }
        }

        @Test("the delegate answers the warm-launch quick-action selector")
        func warmLaunchSelectorIsImplemented() {
            let delegate = HLSceneDelegate()
            #expect(delegate.responds(
                to: #selector(UIWindowSceneDelegate.windowScene(_:performActionFor:completionHandler:))
            ))
            #expect(delegate.responds(to: #selector(UISceneDelegate.scene(_:willConnectTo:options:))))
        }

        @Test("each quick action leaves the marker for its capture surface", arguments: HLQuickAction.allCases)
        func quickActionWritesItsMarker(action: HLQuickAction) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("a3-quickaction-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = CaptureRequestStore(url: url)

            #expect(HLQuickActions.handle(action.shortcutItem, store: store))

            #expect(store.consume()?.surface == action.captureSurface)
        }

        @Test("an unknown shortcut leaves no marker")
        func unknownShortcutLeavesNothing() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("a3-quickaction-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = CaptureRequestStore(url: url)
            let unknown = UIApplicationShortcutItem(type: "dev.healthlog.app.quickaction.bogus", localizedTitle: "x")

            #expect(!HLQuickActions.handle(unknown, store: store))
            #expect(store.consume() == nil)
        }
    }

    /// Stands in for the delegate class Spezi installs: it implements two
    /// lifecycle callbacks and records them.
    final class RecordingSceneDelegate: NSObject {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var recorded: [String] = []

        static var calls: [String] {
            lock.withLock { recorded }
        }

        static func reset() {
            lock.withLock { recorded = [] }
        }

        @objc func sceneDidEnterBackground(_: Any?) {
            Self.lock.withLock { Self.recorded.append("background") }
        }

        @objc func sceneWillEnterForeground(_: Any?) {
            Self.lock.withLock { Self.recorded.append("foreground") }
        }
    }
#endif
