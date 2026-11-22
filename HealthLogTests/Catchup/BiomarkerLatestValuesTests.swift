import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// #191 QoL — the newest readings under a marker's chart, and Delete one
/// menu away from the thumb.
@Suite("Biomarker latest values and overflow delete (#191 QoL)")
@MainActor
struct BiomarkerLatestValuesTests {
    private static func reading(_ id: String, day: Int) -> LabResultDTO {
        let taken = String(format: "2026-11-%02dT08:00:00Z", day)
        return LabResultDTO(
            id: id,
            biomarkerId: "m",
            panel: nil,
            analyte: "LDL",
            value: Double(day),
            unit: "mg/dL",
            referenceLow: nil,
            referenceHigh: nil,
            takenAt: taken,
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .inRange,
            createdAt: taken,
            updatedAt: taken
        )
    }

    private static let marker = BiomarkerDTO(
        id: "m", name: "LDL", unit: "mg/dL", lowerBound: nil, upperBound: 115, panel: nil, hasContext: false,
        context: nil, createdAt: "", updatedAt: ""
    )

    @Test("the card lists the five newest readings, newest first")
    func newestFive() {
        let rows = (1 ... 8).reversed().map { Self.reading("r\($0)", day: $0) }
        let shown = BiomarkerLatestValuesSection.latest(rows)
        #expect(shown.map(\.id) == ["r8", "r7", "r6", "r5", "r4"])
        #expect(BiomarkerLatestValuesSection.latest(Array(rows.prefix(2))).count == 2)
        #expect(BiomarkerLatestValuesSection.latest([]).isEmpty)
    }

    @Test("with a delete the marker's actions are the (i) and one more menu")
    func deleteBehindOverflow() {
        let actions = BiomarkerDetailScreen.markerActions(
            marker: Self.marker,
            analyte: "LDL",
            sheet: .constant(nil)
        ) { _ in }
        #expect(actions.map(\.role) == [.info, .more])
        #expect(actions.last?.systemImage == "ellipsis")
    }

    @Test("without a marker there is nothing to delete")
    func noMarkerNoDelete() {
        let actions = BiomarkerDetailScreen.markerActions(marker: nil, analyte: "LDL", sheet: .constant(nil)) { _ in }
        #expect(actions.map(\.role) == [.info])
    }
}
