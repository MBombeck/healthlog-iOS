// Renders app-target screen symbols that the SPM library does not contain;
// the SPM test build skips the file (repo convention, as in
// `Phase8AccessibilityPolicyTests`).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **08-11 — what the Insights tile grid claims at an accessibility size.**
    ///
    /// `Phase8AccessibilityPolicyTests.insightsUseOneColumnAtAccessibilitySizes`
    /// states the contract as source policy: a grid pinned to two columns must
    /// consult the type size. That clause says the code *asks the right
    /// question*; this suite says the answer is right — the resolved column
    /// count, and the height it actually produces.
    ///
    /// A new suite rather than more cases in 08-02's file: that struct sits at
    /// 349 lines of a 350-line `type_body_length` budget, and 08-04 set the
    /// precedent of giving a plan's own claims their own sibling suite so a
    /// screen fails on its adoption and not on the shared policy.
    @MainActor
    @Suite("Phase 08 Insights grid width")
    struct Phase8InsightsGridTests {
        /// One column at an accessibility size, the caller's own grid otherwise.
        /// The empty case is stated because the policy takes the caller's first
        /// column rather than building one — it must never invent a grid, which
        /// is what keeps each screen's own gutter token authoritative.
        @Test("the Insights tile grid falls back to one column at accessibility sizes")
        func insightsGridFallsBackToOneColumn() {
            #expect(InsightsTileGrid.columns(standard: Self.twoUp, isAccessibilitySize: true).count == 1)
            #expect(InsightsTileGrid.columns(standard: Self.twoUp, isAccessibilitySize: false).count == 2)
            #expect(InsightsTileGrid.columns(standard: [], isAccessibilitySize: true).isEmpty)
            #expect(InsightsTileGrid.columnCount(standard: 3, isAccessibilitySize: true) == 1)
            #expect(InsightsTileGrid.columnCount(standard: 3, isAccessibilitySize: false) == 3)
            #expect(InsightsTileGrid.columnCount(standard: 0, isAccessibilitySize: true) == 0)
        }

        /// The rendered consequence, measured differentially rather than
        /// pixel-compared: the same four tiles at the same width occupy more
        /// height when the policy hands the grid one column than when it hands
        /// it two. A policy that returned the two-up grid in both cases — the
        /// state before this plan — measures identical heights.
        @Test("one column is a taller grid for the same tiles")
        func oneColumnGridIsTallerThanTwoColumns() throws {
            let accessible = try Self.gridHeight(isAccessibilitySize: true)
            let standard = try Self.gridHeight(isAccessibilitySize: false)
            #expect(accessible > standard, "four tiles in one column must be taller than four in two")
            #expect(standard > 0, "the two-up grid must still render")
        }

        // MARK: - Fixtures

        private static let twoUp = [
            GridItem(.flexible(), spacing: HLSpace.md),
            GridItem(.flexible(), spacing: HLSpace.md)
        ]

        /// Four equal tiles laid out through the policy, measured at one fixed
        /// width — the repo's measure-don't-pixel line.
        private static func gridHeight(isAccessibilitySize: Bool) throws -> CGFloat {
            let grid = LazyVGrid(
                columns: InsightsTileGrid.columns(standard: twoUp, isAccessibilitySize: isAccessibilitySize),
                spacing: HLSpace.md
            ) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    Color.gray.frame(height: 60)
                }
            }
            let renderer = ImageRenderer(
                content: grid
                    .frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
            )
            renderer.scale = 1
            guard let image = renderer.uiImage else { throw Phase8GridFailure.renderFailed }
            return image.size.height
        }
    }

    private enum Phase8GridFailure: Error {
        case renderFailed
    }
#endif
