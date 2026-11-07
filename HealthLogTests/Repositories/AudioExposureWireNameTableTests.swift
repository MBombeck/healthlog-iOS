import Foundation
@testable import HealthLog
import Testing

/// **POLISH-B B6** — one table for the server's names, read by the importer
/// (`HealthKitServer144Types.wireNames`) and by the replay paths
/// (`HealthKitBatchEntryDTO.serverWireNames`).
@Suite("POLISH-B B6 — one table of server names")
struct AudioExposureWireNameTableTests {
    @Test("the importer's table is the replay's table")
    func oneTable() {
        #expect(HealthKitServer144Types.wireNames == HealthKitBatchEntryDTO.serverWireNames)
        #expect(
            HealthKitServer144Types.wireIdentifier(forRegistry: HealthKitServer144Types.stateOfMindRuntimeIdentifier)
                == HealthKitServer144Types.stateOfMindWireIdentifier
        )
        #expect(
            HealthKitServer144Types.wireIdentifier(forRegistry: "HKCategoryTypeIdentifierAudioExposureEvent")
                == "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent"
        )
    }

    @Test("a row is translated field for field; a mapped name passes through")
    func translation() {
        let old = HealthKitBatchEntryDTO(
            hkIdentifier: "HKCategoryTypeIdentifierAudioExposureEvent",
            value: 1,
            valueMin: 0.5,
            valueMax: 2,
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1),
            endDate: Date(timeIntervalSince1970: 2),
            sleepStage: nil,
            categoryValue: 1,
            externalId: "hk:x",
            externalSourceVersion: "18.1",
            deviceType: nil
        )
        let wire = old.withServerWireName()
        #expect(wire.hkIdentifier == "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent")
        #expect(wire.externalId == old.externalId)
        #expect(wire.valueMin == old.valueMin && wire.valueMax == old.valueMax)
        #expect(wire.externalSourceVersion == old.externalSourceVersion)
        #expect(wire.categoryValue == old.categoryValue)
        #expect(wire.withServerWireName() == wire)
    }
}
