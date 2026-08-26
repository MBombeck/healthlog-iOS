import Foundation
@testable import HealthLog
import Testing

@Suite("Apple Health medication record semantics")
struct AppleHealthMedicationRecordTests {
    @Test("An as-needed dose without scheduledDate uses the HealthKit sample start")
    func asNeededDoseUsesSampleStart() {
        let sampleStart = Date(timeIntervalSince1970: 1_783_000_000)

        #expect(
            AppleHealthDoseRecord.occurrenceDate(
                scheduledDate: nil,
                sampleStart: sampleStart
            ) == sampleStart
        )
    }

    @Test("Dose quantity and unit use a stable wire representation")
    func doseTextIsStable() {
        #expect(AppleHealthDoseRecord.doseText(quantity: 2, unit: "tablet") == "2 tablet")
        #expect(AppleHealthDoseRecord.doseText(quantity: 0.5, unit: "mL") == "0.5 mL")
        #expect(AppleHealthDoseRecord.doseText(quantity: nil, unit: "tablet") == nil)
    }
}
