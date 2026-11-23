import CoreGraphics
@testable import HealthLog
import SwiftUI
import Testing

/// Names on a lane row stand whole or not at all; the medication's name
/// stands on its first piece; a mark near the end ends at its dot. Measured
/// with a fixed 6 pt per character so the cases read plainly.
@Suite("Timeline lane names")
struct TimelineRowLabelTests {
    static func measure(_ text: String) -> CGFloat {
        CGFloat(text.count) * 6
    }

    typealias Candidate = TimelineRowLabels.Candidate

    @Test("the medication's name runs over its short dose pieces, whose doses give way")
    func nameFirst() {
        let labels = TimelineRowLabels.place([
            Candidate(id: "a", anchor: 10, text: "Trulicity 5 mg", short: "Trulicity", isRowName: true),
            Candidate(id: "b", anchor: 40, text: "7,5 mg"),
            Candidate(id: "c", anchor: 140, text: "5 mg")
        ], width: 300, measure: Self.measure)
        #expect(labels.map(\.text) == ["Trulicity 5 mg", "5 mg"])
    }

    @Test("a name that does not fit whole shortens to the medication's name")
    func shortensToName() {
        let labels = TimelineRowLabels.place([
            Candidate(id: "a", anchor: 0, text: "Trulicity 5 mg", short: "Trulicity", isRowName: true)
        ], width: 60, measure: Self.measure)
        #expect(labels.map(\.text) == ["Trulicity"])
    }

    @Test("nothing but a row's name is ever cut, and that not below the minimum")
    func noStumps() {
        let crowded = TimelineRowLabels.place([
            Candidate(id: "m1", anchor: 0, text: "Magen-Darm-Infekt", isMark: true, endAnchor: 6),
            Candidate(id: "m2", anchor: 20, text: "Erkältung", isMark: true, endAnchor: 26)
        ], width: 200, measure: Self.measure)
        #expect(crowded.allSatisfy { Self.measure($0.text) <= $0.width })
        let tooNarrow = TimelineRowLabels.place([
            Candidate(id: "a", anchor: 0, text: "Omega 3 2 Kapseln", short: "Omega 3", isRowName: true)
        ], width: 30, measure: Self.measure)
        #expect(tooNarrow.isEmpty)
    }

    @Test("a mark at the end of the row ends at its dot instead of being cut")
    func markBeforeDot() {
        let labels = TimelineRowLabels.place([
            Candidate(id: "m", anchor: 270, text: "Influenza", isMark: true, endAnchor: 276)
        ], width: 280, measure: Self.measure)
        #expect(labels.first?.x == 276 - Self.measure("Influenza"))
        #expect(labels.first.map { $0.x + $0.width } == 276)
    }

    @Test("no two names overlap and none passes the row's edges", arguments: [CGFloat(120), 300, 600])
    func noOverlap(width: CGFloat) {
        let candidates = (0 ..< 12).map { index in
            Candidate(
                id: "\(index)",
                anchor: CGFloat(index) * width / 12,
                text: "Hausarzt \(index)",
                isMark: true,
                endAnchor: CGFloat(index) * width / 12 + 6
            )
        }
        let labels = TimelineRowLabels.place(candidates, width: width, leadingInset: 4, measure: Self.measure)
        for label in labels {
            #expect(label.x >= 4 && label.x + label.width <= width)
        }
        for (left, right) in zip(labels, labels.dropFirst()) {
            #expect(left.x + left.width + TimelineRowLabels.gap <= right.x)
        }
    }
}
