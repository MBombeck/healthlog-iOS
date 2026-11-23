import CoreGraphics
@testable import HealthLog
import Testing

/// The pull-to-refresh distance reads 0 everywhere but a pull at the top, so
/// an ordinary scroll writes no state on every frame.
@Suite("Pull distance")
struct HLPullDistanceTests {
    @Test("0 at rest and while scrolled into the page")
    func zeroWhileScrolled() {
        #expect(HLPullToRefreshModifier.pullDistance(contentOffsetY: -40, topInset: 40) == 0)
        for offset in [CGFloat(0), 1, 120, 2400] {
            #expect(HLPullToRefreshModifier.pullDistance(contentOffsetY: offset, topInset: 40) == 0)
        }
    }

    @Test("the overscroll at the top while pulling")
    func positiveWhilePulling() {
        #expect(HLPullToRefreshModifier.pullDistance(contentOffsetY: -100, topInset: 40) == 60)
    }
}
