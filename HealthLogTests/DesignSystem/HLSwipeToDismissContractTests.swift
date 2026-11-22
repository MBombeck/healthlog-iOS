import CoreGraphics
@testable import HealthLog
import Testing

/// The rules of `hlSwipeToDismiss`: the drag locks sideways only when it is
/// clearly sideways (the page keeps scrolling), letting go past half of the
/// width or after a flick puts the card away, short of that it stays.
@Suite("HLSwipeToDismiss contract")
struct HLSwipeToDismissContractTests {
    private let width: CGFloat = 360

    @Test("A short movement decides nothing yet")
    func undecidedWhileShort() {
        #expect(HLSwipeToDismiss.axis(for: CGSize(width: 12, height: 2)) == nil)
    }

    @Test("Only a clearly sideways drag locks horizontally; a diagonal one belongs to scrolling")
    func axisLock() {
        #expect(HLSwipeToDismiss.axis(for: CGSize(width: 30, height: 4)) == .horizontal)
        #expect(HLSwipeToDismiss.axis(for: CGSize(width: -30, height: 10)) == .horizontal)
        #expect(HLSwipeToDismiss.axis(for: CGSize(width: 20, height: 15)) == .vertical)
        #expect(HLSwipeToDismiss.axis(for: CGSize(width: 2, height: -40)) == .vertical)
    }

    @Test("Past half the width either way, letting go puts the card away")
    func thresholdBothSides() {
        #expect(HLSwipeToDismiss.threshold == 0.5)
        #expect(HLSwipeToDismiss.dismisses(offset: 190, predictedEnd: 190, width: width))
        #expect(HLSwipeToDismiss.dismisses(offset: -190, predictedEnd: -190, width: width))
        #expect(!HLSwipeToDismiss.dismisses(offset: 150, predictedEnd: 170, width: width))
    }

    @Test("A firm flick puts it away early, but not one back toward the start")
    func flick() {
        #expect(HLSwipeToDismiss.dismisses(offset: 100, predictedEnd: 600, width: width))
        #expect(!HLSwipeToDismiss.dismisses(offset: 100, predictedEnd: -600, width: width))
        #expect(!HLSwipeToDismiss.dismisses(offset: 0, predictedEnd: 600, width: width))
    }

    @Test("A small nudge with a quick finger springs back")
    func nudgeStays() {
        #expect(!HLSwipeToDismiss.dismisses(offset: 40, predictedEnd: 700, width: width))
        #expect(!HLSwipeToDismiss.dismisses(offset: 60, predictedEnd: 420, width: width))
    }

    @Test("The card follows the finger with weight")
    func resistance() {
        #expect(HLSwipeToDismiss.resistedOffset(100) == 85)
        #expect(HLSwipeToDismiss.resistedOffset(-100) == -85)
    }

    @Test("The haptic and the full symbol come at the threshold")
    func thresholdMoment() {
        #expect(!HLSwipeToDismiss.isPastThreshold(179, width: width))
        #expect(HLSwipeToDismiss.isPastThreshold(180, width: width))
        #expect(HLSwipeToDismiss.symbolOpacity(90, width: width) == 0.5)
        #expect(HLSwipeToDismiss.symbolOpacity(-300, width: width) == 1)
        #expect(HLSwipeToDismiss.symbolOpacity(10, width: 0) == 0)
    }
}
