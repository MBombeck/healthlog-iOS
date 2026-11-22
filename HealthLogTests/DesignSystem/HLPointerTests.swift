@testable import HealthLog
import SwiftUI
import Testing

/// The pointer on the iPad: what lifts, and where the chart scrubber reads
/// the date under the pointer.
@MainActor
@Suite("Pointer: hover and chart scrubbing")
struct HLPointerTests {
    private static let start = Date(timeIntervalSince1970: 0)

    /// One day per point of plot width.
    private func dateAtX(_ x: CGFloat) -> Date? {
        Self.start.addingTimeInterval(Double(x) * 86400)
    }

    @Test("no pointer, no date")
    func noPointer() {
        let date = HLChartScrubber.hoverDate(at: nil, plotFrame: CGRect(x: 0, y: 0, width: 300, height: 200), dateAtX: dateAtX)
        #expect(date == nil)
    }

    @Test("no plot frame, no date")
    func noPlot() {
        #expect(HLChartScrubber.hoverDate(at: CGPoint(x: 10, y: 10), plotFrame: nil, dateAtX: dateAtX) == nil)
    }

    @Test("a pointer outside the plot reads no date", arguments: [
        CGPoint(x: 20, y: 50), CGPoint(x: 400, y: 50), CGPoint(x: 100, y: 5), CGPoint(x: 100, y: 300)
    ])
    func outside(point: CGPoint) {
        let plot = CGRect(x: 40, y: 10, width: 300, height: 200)
        #expect(HLChartScrubber.hoverDate(at: point, plotFrame: plot, dateAtX: dateAtX) == nil)
    }

    @Test("inside an offset plot the date is read at the x inside the plot")
    func insideOffsetPlot() {
        let plot = CGRect(x: 40, y: 10, width: 300, height: 200)
        let date = HLChartScrubber.hoverDate(at: CGPoint(x: 140, y: 100), plotFrame: plot, dateAtX: dateAtX)
        #expect(date == Self.start.addingTimeInterval(100 * 86400))
    }

    @Test("controls and rows are highlighted, only cards lift")
    func hoverDefaults() {
        #expect(HLPressableButtonStyle().hover == .highlight)
        #expect(HLPressableButtonStyle.hlRow.hover == .highlight)
        #expect(HLPressableButtonStyle(hover: .lift).hover == .lift)
    }
}
