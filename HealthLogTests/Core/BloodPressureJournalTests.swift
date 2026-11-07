// HealthKit symbols: kept out of the SPM test build.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// SYNC-HR (1.5) item 8 — #151: blood pressure entered in the iOS 26
    /// blood-pressure journal was not seen on the server.
    ///
    /// The journal saves what the Health app has always saved for a manual
    /// reading: an `HKCorrelation` of type `bloodPressure` with a systolic and
    /// a diastolic member, marked `HKMetadataKeyWasUserEntered`, source Health.
    /// The app never reads the correlation type; it reads the two member
    /// types, which HealthKit returns on their own. These tests pin that the
    /// app's own path takes such a reading: both members are in the collected
    /// set, neither the user-entered mark nor the missing external id drops
    /// them, and they map to one systolic and one diastolic row in mmHg.
    @Suite("SYNC-HR — blood pressure from the iOS 26 journal (#151)", .timeLimit(.minutes(1)))
    struct BloodPressureJournalTests {
        private static let taken = Date(timeIntervalSince1970: 1_793_000_000)

        private static func journalReading() -> HKCorrelation {
            let metadata: [String: Any] = [HKMetadataKeyWasUserEntered: true]
            let mmHg = HKUnit.millimeterOfMercury()
            let systolic = HKQuantitySample(
                type: HKQuantityType(.bloodPressureSystolic),
                quantity: HKQuantity(unit: mmHg, doubleValue: 128),
                start: taken, end: taken, metadata: metadata
            )
            let diastolic = HKQuantitySample(
                type: HKQuantityType(.bloodPressureDiastolic),
                quantity: HKQuantity(unit: mmHg, doubleValue: 82),
                start: taken, end: taken, metadata: metadata
            )
            return HKCorrelation(
                type: HKCorrelationType(.bloodPressure),
                start: taken, end: taken,
                objects: [systolic, diastolic],
                metadata: metadata
            )
        }

        @Test("both member types are collected, the correlation type is not needed")
        func memberTypesAreCollected() {
            let collected = HealthLogSampleTypeRegistry.knownIdentifiers
            #expect(collected.contains(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue))
            #expect(collected.contains(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue))
        }

        @Test("a journal reading maps to one systolic and one diastolic row")
        func journalReadingMaps() throws {
            let members = Array(Self.journalReading().objects)
            #expect(members.count == 2)
            let gate = HealthSampleWireGate(dailyStatsEnabled: true, hrBucketGate: { _ in true })
            let result = gate.map(members)
            #expect(result.readCount == 2, "the user-entered mark or the source dropped a member")
            let byType = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.hkIdentifier, $0) })
            let systolic = try #require(byType[HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue])
            let diastolic = try #require(byType[HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue])
            #expect(systolic.value == 128 && systolic.unit == "mmHg")
            #expect(diastolic.value == 82 && diastolic.unit == "mmHg")
            #expect(systolic.endDate == Self.taken && diastolic.endDate == Self.taken)
        }

        @Test("the correlation object itself carries no row: only its members are sent")
        func correlationItselfIsNotARow() {
            #expect(HealthKitWireConverter.entries(from: Self.journalReading()).isEmpty)
        }
    }
#endif
