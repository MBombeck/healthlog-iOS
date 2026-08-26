// Renders app-target design-system symbols that the SPM library does not
// contain; the SPM test build skips the file (repo convention).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **Phase 08 Plan 04 — the shared primitives, measured on their own terms.**
    ///
    /// `Phase8AccessibilityPolicyTests` (08-02) states what the *screens* must
    /// end up doing and is left byte-identical here; this suite states what the
    /// foundation those screens will spend actually guarantees. The two are
    /// separate on purpose: a screen sweep that adopts a primitive should fail
    /// on its own adoption, not on the primitive, and vice versa.
    ///
    /// Same doctrines as 08-02: layout claims are differential measurements
    /// rather than bitmaps, and every source clause reads comment-stripped text
    /// bounded to one declaration.
    @MainActor
    @Suite("Phase 08 accessibility foundations")
    struct Phase8AccessibilityFoundationTests {
        // MARK: - The 44-point interaction region

        /// The region grows; the glyph does not. Both halves are asserted,
        /// because a modifier that met the number by scaling the icon would
        /// satisfy a naive size check and wreck the visual language.
        @Test("the minimum hit target grows the region without growing the glyph")
        func minimumHitTargetGrowsRegionNotGlyph() throws {
            let glyph = Image(systemName: "chevron.left").font(.hlTitle3)
            let bare = try Self.size(of: glyph)
            let targeted = try Self.size(of: glyph.hlMinimumHitTarget())

            #expect(
                bare.width < HLHitTarget.minimum || bare.height < HLHitTarget.minimum,
                "the sample glyph must actually be too small, or this proves nothing"
            )
            #expect(targeted.width >= HLHitTarget.minimum, "region width \(targeted.width) is under the minimum")
            #expect(targeted.height >= HLHitTarget.minimum, "region height \(targeted.height) is under the minimum")
        }

        /// A `minWidth`/`minHeight` frame is not padding: it grows only what was
        /// too small, so applying it twice must change nothing, and a control
        /// already larger than the minimum must keep its own size.
        @Test("the minimum hit target is idempotent and never inflates a large control")
        func minimumHitTargetDoesNotAccumulate() throws {
            let glyph = Image(systemName: "chevron.left").font(.hlTitle3)
            let once = try Self.size(of: glyph.hlMinimumHitTarget())
            let twice = try Self.size(of: glyph.hlMinimumHitTarget().hlMinimumHitTarget())
            #expect(abs(once.width - twice.width) < 1, "a second application widened the region")
            #expect(abs(once.height - twice.height) < 1, "a second application heightened the region")

            let large = Color.clear.frame(width: 120, height: 96)
            let untouched = try Self.size(of: large.hlMinimumHitTarget())
            #expect(abs(untouched.width - 120) < 1, "an already-large control was resized to \(untouched.width)")
            #expect(abs(untouched.height - 96) < 1, "an already-large control was resized to \(untouched.height)")
        }

        /// The frame alone would leave the grown area inert — the region has to
        /// be hit-testable, and it must not quietly acquire semantics it was not
        /// asked for. Read from the modifier's own declaration, comment-stripped
        /// and bounded to that declaration.
        @Test("the minimum hit target hit-tests its whole region and adds no semantics")
        func minimumHitTargetHitTestsWholeRegion() throws {
            let source = try Phase8SourceScan.stripped("HealthLog/DesignSystem/AccessibilityModifiers.swift")
            let declaration = try #require(
                Phase8SourceScan.member(named: "func hlMinimumHitTarget() -> some View {", in: source),
                "hlMinimumHitTarget no longer exists — restate this contract"
            )

            #expect(declaration.contains("contentShape("), "the grown region is not hit-testable")
            #expect(declaration.contains("HLHitTarget.minimum"), "the modifier spends a literal instead of the token")
            for forbidden in [".padding(", ".scaleEffect(", ".imageScale(", "accessibilityElement", "accessibilityLabel"] {
                #expect(!declaration.contains(forbidden), "the hit-target modifier also does \(forbidden)")
            }
        }

        /// The token is what downstream screens share; pinning the number here
        /// means a drift shows up once rather than at every adoption site.
        @Test("the layout tokens name the minimum interaction region")
        func layoutTokensNameTheMinimumRegion() {
            #expect(HLHitTarget.minimum == 44)
            #expect(HLHitTarget.minimum > HLSpace.xxxxl, "the region must stay above the largest spacing step")
        }

        // MARK: - Rendering

        /// The laid-out size of a view at its ideal geometry — a measurement,
        /// not a bitmap.
        private static func size(of view: some View) throws -> CGSize {
            let renderer = ImageRenderer(content: view.fixedSize())
            renderer.scale = 1
            let image = try #require(renderer.uiImage, "view failed to render")
            return image.size
        }
    }
#endif
