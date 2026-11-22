import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The period a marker page opens on: the standard when it holds two values,
/// else the next wider one that does, else every reading. The list says
/// "2 values"; the chart beside it must draw them.
@Suite("Biomarker opening range")
struct BiomarkerOpeningRangeTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!

    private func reading(_ daysAgo: Int, value: Double? = 1.2) -> LabResultDTO {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Self.now)!
        let stamp = ISO8601DateFormatter().string(from: date)
        return LabResultDTO(
            id: "r\(daysAgo)", biomarkerId: nil, panel: nil, analyte: "INR",
            value: value, valueText: value == nil ? "positiv" : nil, unit: "",
            referenceLow: 0.85, referenceHigh: 1.15, takenAt: stamp, source: "MANUAL",
            hasNote: false, rangeStatus: .above, createdAt: stamp, updatedAt: stamp
        )
    }

    @Test("two values inside a month open on the standard")
    func standardWhenItHoldsTwo() {
        let rows = [reading(3), reading(20)]
        #expect(BiomarkerSeries.openingRange(for: rows, now: Self.now) == .standard)
    }

    @Test("a second value further back widens to the smallest period that holds it")
    func widensToTheSmallestPeriodWithTwo() {
        #expect(BiomarkerSeries.openingRange(for: [reading(27), reading(60)], now: Self.now) == .sixMonths)
        #expect(BiomarkerSeries.openingRange(for: [reading(27), reading(300)], now: Self.now) == .year)
    }

    @Test("values further apart than a year, or a single value, open on all")
    func allOtherwise() {
        #expect(BiomarkerSeries.openingRange(for: [reading(27), reading(500)], now: Self.now) == .all)
        #expect(BiomarkerSeries.openingRange(for: [reading(2)], now: Self.now) == .all)
        #expect(BiomarkerSeries.openingRange(for: [], now: Self.now) == .all)
    }

    @Test("a qualitative reading is no value to draw")
    func qualitativeDoesNotCount() {
        let rows = [reading(2), reading(5, value: nil), reading(90)]
        #expect(BiomarkerSeries.openingRange(for: rows, now: Self.now) == .sixMonths)
    }

    @Test("the opening period never narrows below the standard")
    func neverNarrowerThanStandard() {
        let rows = [reading(0), reading(1), reading(2)]
        #expect(BiomarkerSeries.openingRange(for: rows, now: Self.now) == .standard)
    }
}
