// Drives the App-target avatar store, which the SPM library build has no part of.
#if !SWIFT_PACKAGE && canImport(UIKit)

    @testable import HealthLog
    import Testing
    import UIKit

    /// The avatar bitmap carries the scale of the scene it shows in.
    @MainActor
    @Suite("Avatar display scale")
    struct AvatarDisplayScaleTests {
        @Test("a resolved scene scale is taken as it is")
        func sceneScale() {
            #expect(AvatarStore.displayScale(3) == 3)
            #expect(AvatarStore.displayScale(2) == 2)
        }

        @Test("no scene or an unresolved scale falls back to the current traits, at least 1")
        func fallback() {
            let fallback = max(1, UITraitCollection.current.displayScale)
            #expect(AvatarStore.displayScale(nil) == fallback)
            #expect(AvatarStore.displayScale(0) == fallback)
            #expect(AvatarStore.displayScale(nil) >= 1)
        }
    }

#endif
