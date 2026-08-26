import Foundation
import Testing
#if !SWIFT_PACKAGE
    @testable import HealthLog
    import SwiftUI
    import UIKit
#endif

#if !SWIFT_PACKAGE

    /// Regression tests for the W1j / UX-H9 audit finding: when the device cannot
    /// satisfy the biometric gate (Face ID disabled, no enrolled biometric, no
    /// passcode) the LockOverlay must still expose an *always-visible* escape
    /// hatch — the "Abmelden" button — so the user is never trapped.
    ///
    /// SwiftUI's accessibility tree is too lazy to introspect reliably from a unit
    /// test (no real window, no compositor pass), so these tests assert the
    /// *contract surface* instead: the view stores both wiring closures, the
    /// stable accessibility identifiers exist for future XCUITest targeting, and
    /// invoking the sign-out closure routes the call through.
    @MainActor
    @Suite("LockOverlay")
    struct LockOverlayTests {
        @Test("Stores both onUnlock and onSignOut closures so the escape hatch is wired")
        func storesBothClosures() {
            let overlay = LockOverlay(onUnlock: {}, onSignOut: {})

            let mirror = Mirror(reflecting: overlay)
            let storedLabels = Set(mirror.children.compactMap(\.label))

            #expect(
                storedLabels.contains("onUnlock"),
                "LockOverlay must store onUnlock — without it the primary action is dead"
            )
            #expect(
                storedLabels.contains("onSignOut"),
                "LockOverlay must store onSignOut — without it the escape hatch is dead (UX H9)"
            )
        }

        @Test("Sign-out closure is invoked exactly once per call (no double-fire)")
        func signOutClosureRoutesThrough() throws {
            var signOutInvocations = 0
            let overlay = LockOverlay(
                onUnlock: {},
                onSignOut: { signOutInvocations += 1 }
            )

            // Pull the stored closure back out via Mirror and invoke it directly.
            // This validates the closure was kept by-reference and not dropped /
            // wrapped into a no-op by an over-eager future refactor.
            let mirror = Mirror(reflecting: overlay)
            let onSignOut = try #require(
                mirror.children.first(where: { $0.label == "onSignOut" })?.value as? () -> Void,
                "onSignOut must be a stored () -> Void"
            )

            onSignOut()
            onSignOut()
            #expect(signOutInvocations == 2)
        }

        @Test("Accessibility identifiers are stable for downstream UI tests")
        func accessibilityIdentifiersAreStable() {
            // Locked into the public surface so XCUITest / future automation can
            // reliably target the escape hatch. If someone renames the constant the
            // test breaks — that's the canary.
            #expect(LockOverlay.unlockButtonIdentifier == "lockOverlay.unlockButton")
            #expect(LockOverlay.signOutButtonIdentifier == "lockOverlay.signOutButton")
        }

        @Test("Renders without crashing when hosted in a window")
        func rendersWithoutCrashing() {
            // Smoke test: even if we cannot inspect the SwiftUI a11y tree, the
            // view must at least construct, host, and lay out without throwing —
            // catches future modifier misuse (e.g., infinite ForEach, missing env).
            let overlay = LockOverlay(onUnlock: {}, onSignOut: {})
            let host = UIHostingController(rootView: overlay)
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.layoutIfNeeded()

            #expect(host.view.bounds.width == 390)
            #expect(host.view.bounds.height == 844)
        }
    }

#endif
