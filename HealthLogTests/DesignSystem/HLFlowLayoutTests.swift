import CoreGraphics
@testable import HealthLog
import Testing

/// Where the flow layout puts its children. The placement is a pure function
/// of the children's sizes and the width, so it is checked without a view.
@Suite("Flow layout placement")
struct HLFlowLayoutTests {
    private func size(_ width: CGFloat, _ height: CGFloat = 20) -> CGSize {
        CGSize(width: width, height: height)
    }

    @Test("children stand side by side and move to the next line when the width runs out")
    func wraps() {
        let frames = HLFlowLayout.frames(for: [size(50), size(50), size(50)], in: 120, spacing: 8)
        #expect(frames.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 58, y: 0), CGPoint(x: 0, y: 28)])
        #expect(frames.allSatisfy { $0.size == size(50) })
    }

    @Test("a line that fits exactly is not broken")
    func exactFit() {
        let frames = HLFlowLayout.frames(for: [size(56), size(56)], in: 120, spacing: 8)
        #expect(frames.map(\.minY) == [0, 0])
        #expect(frames.last?.maxX == 120)
    }

    @Test("a child wider than the line gets the line's width and no more")
    func clampsToLineWidth() {
        let frames = HLFlowLayout.frames(for: [size(40), size(300), size(40)], in: 120, spacing: 8)
        #expect(frames[1].width == 120)
        #expect(frames[1].minX == 0)
        #expect(frames.map(\.minY) == [0, 28, 56], "the wide child takes a line of its own")
    }

    @Test("children of unequal height are centred on their line")
    func centresOnLine() {
        let frames = HLFlowLayout.frames(for: [size(40, 20), size(40, 40), size(40, 20)], in: 200, spacing: 8)
        #expect(frames.map(\.minY) == [10, 0, 10])
        #expect(frames.map(\.midY) == [20, 20, 20])
    }

    @Test("the gap between lines is the gap between children unless one is named")
    func lineSpacing() {
        let sizes = [size(100), size(100)]
        #expect(HLFlowLayout.frames(for: sizes, in: 120, spacing: 8)[1].minY == 28)
        #expect(HLFlowLayout.frames(for: sizes, in: 120, spacing: 8, lineSpacing: 0)[1].minY == 20)
    }

    @Test("the default gap is the small spacing step")
    func defaultSpacing() {
        let frames = HLFlowLayout.frames(for: [size(50), size(50)], in: 200)
        #expect(frames[1].minX == 50 + HLSpace.sm)
    }

    @Test("nothing to lay out gives nothing")
    func empty() {
        #expect(HLFlowLayout.frames(for: [], in: 120).isEmpty)
    }
}
