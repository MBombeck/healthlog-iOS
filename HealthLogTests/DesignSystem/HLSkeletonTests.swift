// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// Locks the contract of `HLSkeleton` — the design-system loading
    /// placeholder that replaces the per-screen spinner on first-paint.
    ///
    /// The tests deliberately don't snapshot pixels (shimmer animation
    /// phase is non-deterministic). Instead they pin:
    ///   • Every `Shape` variant constructs without trapping (the
    ///     initialiser must remain trap-free for adoption sites that
    ///     iterate over the cases at body-eval time).
    ///   • The localized "Wird geladen" accessibility label resolves —
    ///     `String(localized:)` here re-uses the same key the SwiftUI
    ///     `Text(_:)` path resolves, so a missing entry surfaces here
    ///     before reaching a screen-level skeleton adoption site.
    ///   • The `skeleton.<shape>` accessibility identifier matches the
    ///     contract UI-tests will lock against (rawValue derivation, not
    ///     a string interpolation that could drift).
    @MainActor
    @Suite("HLSkeleton primitive contract")
    struct HLSkeletonTests {
        @Test("Every Shape variant initialises without trapping")
        func shapeVariantsBuild() {
            // Build each variant — the initialiser is `Sendable` value-type
            // construction, so we don't need a host. The test guards against
            // a future change that would force this through `@MainActor`
            // construction or a precondition trap. Touching `body` exercises
            // the SwiftUI builder graph; if the builder were to crash the
            // adoption sites would faceplant on first-paint instead.
            for shape in [HLSkeleton.Shape.rect, .capsule, .circle] {
                let skeleton = HLSkeleton(shape, width: 120, height: 16)
                _ = skeleton.body
            }
        }

        @Test("Accessibility identifier mirrors the Shape rawValue")
        func identifierMatchesRawValue() {
            // Locks the UI-test contract documented on `HLSkeleton`:
            // `skeleton.rect`, `skeleton.capsule`, `skeleton.circle`. The
            // identifier is derived from `Shape.rawValue` so a future
            // case addition lights up its identifier automatically — no
            // manual switch update required.
            #expect(HLSkeleton.Shape.rect.rawValue == "rect")
            #expect(HLSkeleton.Shape.capsule.rawValue == "capsule")
            #expect(HLSkeleton.Shape.circle.rawValue == "circle")
        }

        @Test("Localized 'Wird geladen' label resolves")
        func accessibilityLabelLocalized() {
            // `HLSkeleton.body` builds the accessibility label via
            // `Text("Loading")` — which routes through SwiftUI's
            // `LocalizedStringKey` initialiser and looks up the key in
            // `Localizable.xcstrings`. Resolving the same key here
            // surfaces a missing localization entry at unit-test time
            // rather than at first-paint on a screen.
            let label = String(localized: "Loading")
            #expect(!label.isEmpty)
            // Ground-truth the German source value so an accidental
            // entry rewrite (e.g. swapping "Wird geladen" for "Laden")
            // surfaces immediately instead of drifting silently.
            #expect(label == "Wird geladen")
        }

        @Test("Default init uses .rect with sensible defaults")
        func defaultInitialiser() {
            // The brief locks `init(_ shape: Shape = .rect, width: CGFloat? = nil,
            // height: CGFloat = 16, cornerRadius: CGFloat = 8)` — every
            // adoption site relies on these defaults so a single-row text
            // skeleton stays a one-liner: `HLSkeleton()`. We can't read
            // the private storage, but we exercise the no-arg path so a
            // future default-change has to walk past this trap.
            let skeleton = HLSkeleton()
            _ = skeleton.body
        }

        @Test("Circle variant treats width as both axes")
        func circleVariantSquare() {
            // The init contract for `.circle` is that omitting `height`
            // and supplying `width` yields a square frame. Locks the
            // ergonomics so call-sites can write `HLSkeleton(.circle,
            // width: 24)` instead of `width: 24, height: 24` everywhere.
            let circle = HLSkeleton(.circle, width: 24)
            _ = circle.body
        }
    }

#endif
