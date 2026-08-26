import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

@Suite("MeasurementsChronoEditFlowTests")
struct MeasurementsChronoEditFlowTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func measurement(
        id: String,
        value: Double,
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Measurement {
        Measurement(
            id: id,
            kind: .weight,
            recordedAt: recordedAt,
            value: .scalar(value),
            source: .manual
        )
    }

    @Test("Successful canonical edit replaces the matching recent row immediately")
    func successfulEditReplacesRecentRow() {
        let untouched = measurement(id: "other", value: 70)
        let original = measurement(id: "target", value: 80)
        let updated = measurement(
            id: "target",
            value: 81,
            recordedAt: original.recordedAt.addingTimeInterval(60)
        )

        let result = MeasurementChronoModel.replacing(
            updated,
            matching: original.id,
            in: [original, untouched]
        )

        #expect(result.first?.id == "target")
        #expect(result.first?.value == .scalar(81))
        #expect(result.last == untouched)
    }

    @Test("Chronological feed binds host state and reuses the canonical editor and swipe actions")
    func feedUsesCanonicalEditSeams() throws {
        let feed = try Self.source("HealthLog/Screens/Measurements/MeasurementsChronoFeed.swift")
        let rows = try Self.source("HealthLog/Screens/Measurements/MeasurementListRows.swift")
        let picker = try Self.source("HealthLog/Screens/Measurements/MeasurementsPickerScreen.swift")

        #expect(feed.contains("@Binding var measurements: [Measurement]"))
        #expect(feed.contains("MeasurementSwipeActions("))
        #expect(feed.contains("EditMeasurementSheet(measurement:"))
        #expect(feed.contains("onDelete: (Measurement) async -> Bool"))
        #expect(rows.contains("struct MeasurementSwipeActions"))
        #expect(picker.contains("MeasurementsChronoFeed(measurements: $recentAll"))
    }

    @Test("Collapsed rows remain navigation-only while eligible singles expose actions")
    func collapsedRowsRemainNavigationOnly() throws {
        let feed = try Self.source("HealthLog/Screens/Measurements/MeasurementsChronoFeed.swift")

        #expect(feed.contains("case .collapsed:"))
        #expect(feed.contains("case let .single(measurement):"))
        #expect(feed.contains("if entry.editableMeasurement != nil"))
    }
}
