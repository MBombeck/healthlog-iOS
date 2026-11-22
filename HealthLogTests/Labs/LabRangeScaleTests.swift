import Foundation
@testable import HealthLog
import Testing

/// Where a lab reading stands on its reference range: the pure rule behind
/// the range bar in the table row and on the marker page.
@Suite("Lab range scale")
struct LabRangeScaleTests {
    private func place(_ value: Double?, previous: [Double] = [], low: Double?, high: Double?) -> LabRangeScale.Placement? {
        LabRangeScale.placement(value: value, previous: previous, low: low, high: high)
    }

    @Test("a two-sided range takes the middle half of the scale")
    func twoSidedRangeIsTheMiddleHalf() throws {
        let placement = try #require(place(2, low: 1, high: 3))
        #expect(placement.bandStart == 0.25)
        #expect(placement.bandEnd == 0.75)
        #expect(placement.value == 0.5)
        #expect(placement.low == 1)
        #expect(placement.high == 3)
    }

    @Test("a value just outside the range stands visibly beside it, inside the scale")
    func valueJustOutside() throws {
        let placement = try #require(place(3.4, low: 1, high: 3))
        #expect(placement.value > placement.bandEnd)
        #expect(placement.value < 1)
    }

    @Test("a value far outside widens the scale so it still fits, with room at the edge")
    func farOutsideWidensTheScale() throws {
        let placement = try #require(place(30, low: 1, high: 3))
        #expect(placement.value < 1)
        #expect(placement.value > 0.9)
        #expect(placement.bandEnd < 0.2, "the range shrinks to make room")
        let below = try #require(place(-20, low: 1, high: 3))
        #expect(below.value > 0)
        #expect(below.value < 0.1)
    }

    @Test("an upper bound alone runs the range from zero to the bound")
    func atMost() throws {
        let placement = try #require(place(2.1, low: nil, high: 5))
        #expect(placement.bandStart == 0)
        #expect(placement.bandEnd > placement.value)
        #expect(placement.bandEnd < 1)
        #expect(placement.low == nil)
    }

    @Test("a lower bound alone runs the range from the bound to the open end")
    func atLeast() throws {
        let placement = try #require(place(70, low: 40, high: nil))
        #expect(placement.bandStart > 0)
        #expect(placement.bandEnd == 1)
        #expect(placement.value > placement.bandStart)
    }

    @Test("earlier readings are placed too, at most five, oldest first")
    func earlierReadings() throws {
        let placement = try #require(place(2, previous: [0.5, 1, 1.5, 2, 2.5, 2.9], low: 1, high: 3))
        #expect(placement.previous.count == LabRangeScale.previousLimit)
        #expect(placement.previous == placement.previous.sorted(), "the values rise, so the fractions do")
        #expect(placement.previous.allSatisfy { (0 ... 1).contains($0) })
    }

    @Test("an earlier reading outside the range widens the scale like the value")
    func earlierReadingWidens() throws {
        let placement = try #require(place(2, previous: [12], low: 1, high: 3))
        #expect(try #require(placement.previous.first) < 1)
        #expect(placement.bandEnd < 0.3)
    }

    @Test("no bound, no number or a broken number: no bar")
    func nothingToPlace() {
        #expect(place(2, low: nil, high: nil) == nil)
        #expect(place(nil, low: 1, high: 3) == nil)
        #expect(place(.nan, low: 1, high: 3) == nil)
        #expect(place(2, low: .infinity, high: nil) == nil)
    }

    @Test("a range of one point still gets a scale around it")
    func degenerateRange() throws {
        let placement = try #require(place(1, low: 1, high: 1))
        #expect(placement.bandStart == placement.bandEnd)
        #expect(placement.value == placement.bandStart)
        #expect((0 ... 1).contains(placement.value))
    }

    @Test("every fraction stays on the bar")
    func fractionsInRange() throws {
        for value in [-5.0, 0, 0.9, 1, 2, 3, 3.1, 100] {
            for (low, high) in [(Double?(1), Double?(3)), (nil, 3), (1, nil)] {
                let placement = try #require(place(value, previous: [value / 2, value * 2], low: low, high: high))
                let all = [placement.bandStart, placement.bandEnd, placement.value] + placement.previous
                #expect(all.allSatisfy { (0 ... 1).contains($0) }, "\(value) on \(String(describing: low)) to \(String(describing: high))")
            }
        }
    }

    @Test("the marker page passes the readings before the newest, oldest first")
    func markerPageEarlierValues() {
        func row(_ id: String, _ value: Double?) -> LabResultDTO {
            LabResultDTO(
                id: id, biomarkerId: nil, panel: nil, analyte: "INR", value: value, unit: "",
                referenceLow: nil, referenceHigh: nil, takenAt: "2026-10-21T08:00:00Z", source: "MANUAL",
                hasNote: false, rangeStatus: .inRange, createdAt: "", updatedAt: ""
            )
        }
        // Newest first, as the page holds them.
        let rows = [row("c", 3), row("b", nil), row("a", 1), row("z", 2)]
        #expect(BiomarkerDetailScreen.earlierValues(rows) == [2, 1])
        #expect(BiomarkerDetailScreen.earlierValues([row("c", 3)]) == [])
    }

    @Test("a course needs two numbers: one value has no period bar and no chart")
    func courseNeedsTwoNumbers() {
        func row(_ id: String, _ value: Double?) -> LabResultDTO {
            LabResultDTO(
                id: id, biomarkerId: nil, panel: nil, analyte: "INR", value: value, unit: "",
                referenceLow: nil, referenceHigh: nil, takenAt: "2026-10-21T08:00:00Z", source: "MANUAL",
                hasNote: false, rangeStatus: .inRange, createdAt: "", updatedAt: ""
            )
        }
        #expect(BiomarkerDetailScreen.hasCourse([row("a", 1)]) == false)
        #expect(BiomarkerDetailScreen.hasCourse([row("a", 1), row("b", nil)]) == false)
        #expect(BiomarkerDetailScreen.hasCourse([row("a", 1), row("b", 2)]))
    }

    private func reading(
        _ value: Double?,
        text: String? = nil,
        low: Double? = nil,
        high: Double? = nil,
        biomarker: String? = nil
    ) -> LabResultDTO {
        LabResultDTO(
            id: UUID().uuidString, biomarkerId: biomarker, panel: nil, analyte: "INR", value: value, valueText: text, unit: "",
            referenceLow: low, referenceHigh: high, takenAt: "2026-10-21T08:00:00Z", source: "MANUAL",
            hasNote: false, rangeStatus: .inRange, createdAt: "", updatedAt: ""
        )
    }

    @Test("a single value the bar can place leaves the course card out; anything else keeps it with its note")
    func courseCardForSingleValues() {
        // A number on a range: the bar in the card above says it all.
        #expect(BiomarkerDetailScreen.showsCourseCard([reading(1.0)], low: 0.85, high: 1.15) == false)
        // A qualitative result has no place on the bar: the card and its note stay.
        #expect(BiomarkerDetailScreen.showsCourseCard([reading(nil, text: "positiv")], low: 0.85, high: 1.15))
        // No range: the card and its note stay.
        #expect(BiomarkerDetailScreen.showsCourseCard([reading(1.0)], low: nil, high: nil))
        // A course: the chart.
        #expect(BiomarkerDetailScreen.showsCourseCard([reading(1.0), reading(1.1)], low: 0.85, high: 1.15))
    }

    @Test("the catalogue range wins over the printed one, and row and page place the value alike")
    func oneSourceForTheBounds() throws {
        let marker = BiomarkerDTO(
            id: "m", name: "INR", unit: "", lowerBound: 2, upperBound: 3, panel: nil, hasContext: false,
            context: nil, createdAt: "", updatedAt: ""
        )
        let latest = reading(2.5, low: 0.85, high: 1.15, biomarker: "m")
        let bounds = LabRangeScale.bounds(marker: marker, latest: latest)
        #expect(bounds.low == 2)
        #expect(bounds.high == 3)
        // The table row and the marker page both place through `bounds`.
        let row = try #require(LabRangeScale.placement(value: latest.value, previous: [], low: bounds.low, high: bounds.high))
        let page = LabRangeScale.bounds(marker: marker, latest: latest)
        let card = try #require(LabRangeScale.placement(value: latest.value, previous: [], low: page.low, high: page.high))
        #expect(row == card)
        #expect(row.value == 0.5, "2.5 is the middle of 2 to 3")
        // Without a marker the printed bounds count.
        let printed = LabRangeScale.bounds(marker: nil, latest: latest)
        #expect(printed.low == 0.85)
        #expect(printed.high == 1.15)
    }
}
