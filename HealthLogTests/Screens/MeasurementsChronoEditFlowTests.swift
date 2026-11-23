import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

@Suite("MeasurementsChronoEditFlowTests")
struct MeasurementsChronoEditFlowTests {
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
}
