import Foundation
@testable import HealthLog
import Testing

/// **GH #47 — source-exclusive policy gate.** An Apple-Health-mirrored med is
/// source-exclusive: the client must NOT offer manual dose logging on it
/// (prevents double-counting; compliance is never recomputed client-side).
@Suite("Medication — Apple Health source-exclusive gate")
struct MedicationAppleHealthGateTests {
    private func med(externalSource: String?, externalId: String? = nil) -> Medication {
        Medication(
            id: "m1",
            name: "Lisinopril",
            dose: "5mg",
            schedule: MedicationSchedule(times: []),
            externalSource: externalSource,
            externalId: externalId
        )
    }

    @Test("An app-managed med allows manual dose logging + is not mirrored")
    func appManagedAllowsLogging() {
        let m = med(externalSource: nil)
        #expect(!m.isAppleHealthMirrored)
        #expect(m.allowsManualDoseLogging)
    }

    @Test("An APPLE_HEALTH-mirrored med is mirrored + blocks manual logging")
    func mirroredBlocksLogging() {
        let m = med(externalSource: "APPLE_HEALTH", externalId: "concept-123")
        #expect(m.isAppleHealthMirrored)
        #expect(!m.allowsManualDoseLogging)
    }

    @Test("An unrelated external source is NOT treated as Apple-mirrored")
    func otherSourceNotMirrored() {
        let m = med(externalSource: "WITHINGS")
        #expect(!m.isAppleHealthMirrored)
        #expect(m.allowsManualDoseLogging)
    }

    @Test("withAppleHealthProvenance stamps an app-managed med as mirrored")
    func stampProvenance() {
        let stamped = med(externalSource: nil).withAppleHealthProvenance(externalId: "concept-9")
        #expect(stamped.isAppleHealthMirrored)
        #expect(!stamped.allowsManualDoseLogging)
        #expect(stamped.externalId == "concept-9")
        // Identity + core fields preserved.
        #expect(stamped.id == "m1")
        #expect(stamped.name == "Lisinopril")
    }

    @Test("The wire DTO carries provenance through toDomain()")
    func wireDTOPropagatesProvenance() {
        let wire = MedicationWireDTO(
            id: "m2",
            name: "Trulicity",
            dose: "7.5mg",
            externalSource: "APPLE_HEALTH",
            externalId: "concept-mj"
        )
        let domain = wire.toDomain()
        #expect(domain.isAppleHealthMirrored)
        #expect(!domain.allowsManualDoseLogging)
        #expect(domain.externalId == "concept-mj")
    }
}
