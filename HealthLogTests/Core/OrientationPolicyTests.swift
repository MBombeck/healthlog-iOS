// Drives the App-target scene delegate, which the SPM library build has no part of.
#if !SWIFT_PACKAGE && canImport(UIKit)

    @testable import HealthLog
    import Testing
    import UIKit

    /// The iPad turns freely; the phone stays upright and turns only while the
    /// full-screen chart allows it.
    @MainActor
    @Suite("Orientation policy", .serialized)
    struct OrientationPolicyTests {
        @Test("the iPad allows every orientation, with or without the chart")
        func pad() {
            #expect(OrientationPolicy.mask(isPad: true, allowsLandscape: false) == .all)
            #expect(OrientationPolicy.mask(isPad: true, allowsLandscape: true) == .all)
        }

        @Test("the phone stays upright")
        func phone() {
            #expect(OrientationPolicy.mask(isPad: false, allowsLandscape: false) == .portrait)
        }

        @Test("under the full-screen chart the phone turns, never upside down")
        func phoneChart() {
            let mask = OrientationPolicy.mask(isPad: false, allowsLandscape: true)
            #expect(mask == .allButUpsideDown)
            #expect(!mask.contains(.portraitUpsideDown))
        }

        @Test("the chart sets the switch and takes it back")
        func switchRoundTrip() {
            #expect(!OrientationPolicy.allowsLandscape)
            OrientationPolicy.allowLandscape(true)
            #expect(OrientationPolicy.allowsLandscape)
            OrientationPolicy.allowLandscape(false)
            #expect(!OrientationPolicy.allowsLandscape)
        }

        @Test("the scene delegate answers with the policy on iOS 27")
        func sceneDelegate() throws {
            guard #available(iOS 27.0, *) else { return }
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let delegate = HLSceneDelegate()
            let expected = OrientationPolicy.mask(
                isPad: scene.traitCollection.userInterfaceIdiom == .pad,
                allowsLandscape: false
            )
            #expect(delegate.supportedInterfaceOrientations(for: scene) == expected)
        }
    }

#endif
