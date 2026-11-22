// Drives the App-target privacy shield policy, which the SPM library build has no part of.
#if !SWIFT_PACKAGE && canImport(UIKit)

    import CoreGraphics
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// The window root keeps its tree through every scene phase; only the
    /// biometric lock unmounts it. The scene's cover window hides the app from
    /// the switcher: on the phone at `.inactive`, on the iPad at `.background`.
    @MainActor
    @Suite("Privacy shield by scene phase", .serialized)
    struct PrivacyShieldPhaseTests {
        // MARK: Window root

        @Test("inactive covers and keeps the tree")
        func inactiveCoversAndKeepsTree() {
            #expect(RootPrivacyShieldPolicy.resolve(sceneIsActive: false, biometricLocked: false) == .unprotected)
            #expect(PrivacyCoverPolicy.covers(
                idiom: .phone, phase: .inactive, anotherSceneActive: false, visibleInForeground: true
            ))
        }

        @Test("the biometric lock unmounts the tree")
        func biometricLockUnmounts() {
            #expect(RootPrivacyShieldPolicy.resolve(sceneIsActive: true, biometricLocked: true) == .protected(.biometricLocked))
        }

        @Test("a locked scene that goes inactive stays unmounted and shows the brand face")
        func lockedAndInactive() {
            #expect(RootPrivacyShieldPolicy.resolve(sceneIsActive: false, biometricLocked: true) == .protected(.inactive))
        }

        @Test("an active, unlocked scene shows its content")
        func activeUnlocked() {
            #expect(RootPrivacyShieldPolicy.resolve(sceneIsActive: true, biometricLocked: false) == .unprotected)
        }

        // MARK: Cover window

        @Test("the phone and the Duo cover from inactive on, for the switcher and the Control Centre")
        func phoneCovers() {
            for another in [false, true] {
                for visible in [false, true] {
                    #expect(!PrivacyCoverPolicy.covers(
                        idiom: .phone, phase: .active, anotherSceneActive: another, visibleInForeground: visible
                    ))
                    #expect(PrivacyCoverPolicy.covers(
                        idiom: .phone, phase: .inactive, anotherSceneActive: another, visibleInForeground: visible
                    ))
                    #expect(PrivacyCoverPolicy.covers(
                        idiom: .phone, phase: .background, anotherSceneActive: another, visibleInForeground: visible
                    ))
                }
            }
        }

        @Test("an iPad window that only lost focus in Stage Manager stays uncovered")
        func padUnfocusedStaysVisible() {
            #expect(!PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .inactive, anotherSceneActive: false, visibleInForeground: true
            ))
            #expect(!PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .inactive, anotherSceneActive: true, visibleInForeground: false
            ))
            #expect(!PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .active, anotherSceneActive: false, visibleInForeground: true
            ))
        }

        @Test("an iPad scene covers in the background and when it leaves the foreground alone")
        func padCovers() {
            #expect(PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .background, anotherSceneActive: true, visibleInForeground: false
            ))
            #expect(PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .inactive, anotherSceneActive: false, visibleInForeground: false
            ))
        }

        @Test("an inactive full-screen iPad scene covers for the switcher; a Stage Manager window or a Split View pane does not")
        func padSwitcherCovers() {
            let screen = CGSize(width: 1032, height: 1376)
            let fullScreen = PrivacyCoverController.staysOnScreen(phase: .inactive, sceneSize: screen, screenSize: screen)
            #expect(!fullScreen)
            #expect(PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .inactive, anotherSceneActive: false, visibleInForeground: fullScreen
            ), "the app switcher on a single full-screen window")
            let window = PrivacyCoverController.staysOnScreen(
                phase: .inactive, sceneSize: CGSize(width: 744, height: 900), screenSize: screen
            )
            #expect(window)
            #expect(!PrivacyCoverPolicy.covers(
                idiom: .pad, phase: .inactive, anotherSceneActive: false, visibleInForeground: window
            ), "a Stage Manager window that lost the focus stays readable")
            let pane = PrivacyCoverController.staysOnScreen(
                phase: .inactive, sceneSize: CGSize(width: 507, height: 1376), screenSize: screen
            )
            #expect(pane, "a Split View pane")
            #expect(!PrivacyCoverController.staysOnScreen(
                phase: .background, sceneSize: CGSize(width: 744, height: 900), screenSize: screen
            ))
            #expect(!PrivacyCoverController.staysOnScreen(
                phase: .inactive, sceneSize: CGSize(width: 1031.5, height: 1376), screenSize: screen
            ), "rounding is not a window")
        }

        @Test("each scene notification maps to the phase the scene is in after it")
        func notificationPhases() {
            #expect(PrivacyCoverController.phase(after: UIScene.willDeactivateNotification) == .inactive)
            #expect(PrivacyCoverController.phase(after: UIScene.willEnterForegroundNotification) == .inactive)
            #expect(PrivacyCoverController.phase(after: UIScene.didActivateNotification) == .active)
            #expect(PrivacyCoverController.phase(after: UIScene.didEnterBackgroundNotification) == .background)
            #expect(PrivacyCoverController.phase(after: UIScene.didDisconnectNotification) == nil)
            #expect(PrivacyCoverController.phase(of: .foregroundActive) == .active)
            #expect(PrivacyCoverController.phase(of: .foregroundInactive) == .inactive)
            #expect(PrivacyCoverController.phase(of: .background) == .background)
            #expect(PrivacyCoverController.phase(of: .unattached) == .background)
        }

        @Test("the cover window sits above alerts")
        func coverAboveAlerts() {
            #expect(HLPrivacyCoverWindow.level.rawValue > UIWindow.Level.alert.rawValue)
        }

        // MARK: Behaviour

        @Test("state in the content survives inactive and back; the lock unmounts it")
        func contentStateSurvivesPhases() async throws {
            let log = MountLog()
            let host = UIHostingController(rootView: composition(sceneIsActive: true, locked: false, log: log))
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await settle(host)

            host.rootView = composition(sceneIsActive: false, locked: false, log: log)
            try await settle(host)
            host.rootView = composition(sceneIsActive: true, locked: false, log: log)
            try await settle(host)

            #expect(log.appeared == 1)
            #expect(log.disappeared == 0)
            #expect(log.tokens.count >= 3)
            #expect(Set(log.tokens).count == 1, "the content's state was rebuilt: \(log.tokens)")

            host.rootView = composition(sceneIsActive: true, locked: true, log: log)
            try await settle(host)
            #expect(log.disappeared == 1)
        }

        @Test("the cover is opaque and lets no pixel of the content through", arguments: [ColorScheme.light, .dark])
        func coverIsOpaque(scheme: ColorScheme) throws {
            let view = ZStack {
                Color(red: 1, green: 0, blue: 1)
                PrivacyCoverView()
            }
            .frame(width: 240, height: 320)
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true }

            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.uiImage?.cgImage, "the cover did not render")
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var sentinel = 0
            var minimumAlpha = UInt8.max
            for index in stride(from: 0, to: pixels.count, by: 4) {
                minimumAlpha = min(minimumAlpha, pixels[index + 3])
                if pixels[index] > 220, pixels[index + 1] < 40, pixels[index + 2] > 220 { sentinel += 1 }
            }
            #expect(sentinel == 0)
            #expect(minimumAlpha == 255)
        }

        // MARK: Helpers

        private func composition(
            sceneIsActive: Bool,
            locked: Bool,
            log: MountLog
        ) -> RootPrivacyComposition<Text, ContentProbe> {
            RootPrivacyComposition(
                resolution: RootPrivacyShieldPolicy.resolve(sceneIsActive: sceneIsActive, biometricLocked: locked),
                shield: { _ in Text(verbatim: "locked") },
                content: { ContentProbe(sceneIsActive: sceneIsActive, log: log) }
            )
        }

        private func settle(_ host: UIViewController) async throws {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private final class MountLog {
        var appeared = 0
        var disappeared = 0
        var tokens: [UUID] = []
    }

    /// Content with state of its own. A rebuilt view would draw a new token.
    private struct ContentProbe: View {
        let sceneIsActive: Bool
        let log: MountLog
        @State private var token = UUID()

        var body: some View {
            Text(verbatim: sceneIsActive ? "active" : "inactive")
                .onAppear {
                    log.appeared += 1
                    log.tokens.append(token)
                }
                .onDisappear { log.disappeared += 1 }
                .onChange(of: sceneIsActive) { log.tokens.append(token) }
        }
    }

#endif
