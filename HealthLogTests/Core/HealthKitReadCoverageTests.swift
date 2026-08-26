// W-HKREAD — read-coverage parity for the nine additive quantity signals +
// the seven categorical EVENT classes the server maps end-to-end. Calls
// HealthKit symbols, so it stays out of the SPM test build.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    @Suite("HealthKit read-coverage (W-HKREAD)")
    struct HealthKitReadCoverageTests {
        /// The nine additive quantity identifiers the server's
        /// APPLE_HEALTH_TYPE_MAP accepts (server v1.10.0 WX-A).
        static let newQuantityIdentifiers: [String] = [
            HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue,
            HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue,
            HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue,
            HKQuantityTypeIdentifier.appleSleepingBreathingDisturbances.rawValue,
            HKQuantityTypeIdentifier.leanBodyMass.rawValue,
            HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue,
            HKQuantityTypeIdentifier.stairAscentSpeed.rawValue,
            HKQuantityTypeIdentifier.stairDescentSpeed.rawValue,
            HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue
        ]

        // MARK: - Registry

        @Test("Registry knows every new additive quantity identifier")
        func registryContainsNewQuantityTypes() {
            for id in Self.newQuantityIdentifiers {
                #expect(HealthLogSampleTypeRegistry.contains(id), "missing \(id)")
            }
        }

        // MARK: - Read-auth set

        @Test("defaultReadTypes requests every new quantity + event type")
        func defaultReadTypesCoversNewTypes() {
            let identifiers = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            for id in Self.newQuantityIdentifiers {
                #expect(identifiers.contains(id), "read-auth missing \(id)")
            }
            for type in HealthKitService.eventReadTypes {
                #expect(identifiers.contains(type.identifier), "event read-auth missing \(type.identifier)")
            }
        }

        @Test("eventReadTypes are the seven categorical EVENT classes")
        func eventReadTypesShape() {
            let ids = Set(HealthKitService.eventReadTypes.map(\.identifier))
            #expect(ids.count == 7)
            #expect(ids.contains(HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue))
            #expect(ids.contains(HKCategoryTypeIdentifier.highHeartRateEvent.rawValue))
            #expect(ids.contains(HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue))
            #expect(ids.contains(HKCategoryTypeIdentifier.appleWalkingSteadinessEvent.rawValue))
            #expect(ids.contains(HKCategoryTypeIdentifier.sleepApneaEvent.rawValue))
            #expect(ids.contains(HKCategoryTypeIdentifier.environmentalAudioExposureEvent.rawValue))
            #expect(ids.contains(HKCategoryTypeIdentifier.headphoneAudioExposureEvent.rawValue))
        }

        // MARK: - Wire mapping (quantity)

        @Test("Walking heart-rate average maps raw bpm on count/min unit")
        func walkingHeartRateAverageMapping() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.walkingHeartRateAverage),
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 92),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].unit == "count/min")
            #expect(entries[0].value == 92)
            #expect(entries[0].categoryValue == nil)
        }

        @Test("Lean body mass maps raw kg identity")
        func leanBodyMassMapping() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.leanBodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 55.5),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].unit == "kg")
            #expect(entries[0].value == 55.5)
        }

        @Test("Stair ascent speed maps raw m/s identity")
        func stairAscentSpeedMapping() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.stairAscentSpeed),
                quantity: HKQuantity(unit: HKUnit.meter().unitDivided(by: .second()), doubleValue: 0.42),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].unit == "m/s")
            #expect(abs(entries[0].value - 0.42) < 0.0001)
        }

        @Test("Sleeping wrist temperature maps raw degC identity")
        func wristTemperatureMapping() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.appleSleepingWristTemperature),
                quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: 36.4),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].unit == "degC")
            #expect(abs(entries[0].value - 36.4) < 0.0001)
        }

        // MARK: - Event importer shape

        @Test("Event importer observes the seven EVENT category types")
        func eventImporterCategoryTypes() {
            let ids = Set(HeartHealthEventImporter.eventCategoryTypes().map(\.identifier))
            #expect(ids == Set(HealthKitService.eventReadTypes.map(\.identifier)))
        }

        // MARK: - DTO categoryValue round-trip

        @Test("Batch DTO carries categoryValue for event rows, nil otherwise")
        func dtoCategoryValueCodable() throws {
            let eventEntry = HealthKitBatchEntryDTO(
                hkIdentifier: HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue,
                value: 1,
                unit: "event",
                startDate: Date(timeIntervalSince1970: 1_715_673_600),
                endDate: Date(timeIntervalSince1970: 1_715_673_600),
                categoryValue: 0,
                externalId: "evt-1"
            )
            let data = try JSONEncoder().encode(eventEntry)
            let decoded = try JSONDecoder().decode(HealthKitBatchEntryDTO.self, from: data)
            #expect(decoded.categoryValue == 0)
            #expect(decoded.unit == "event")
            #expect(decoded.value == 1)

            // A continuous reading leaves categoryValue absent.
            let quantityEntry = HealthKitBatchEntryDTO(
                hkIdentifier: HKQuantityTypeIdentifier.leanBodyMass.rawValue,
                value: 55,
                unit: "kg",
                startDate: Date(timeIntervalSince1970: 1_715_673_600),
                endDate: Date(timeIntervalSince1970: 1_715_673_600),
                externalId: "q-1"
            )
            let qData = try JSONEncoder().encode(quantityEntry)
            let qDecoded = try JSONDecoder().decode(HealthKitBatchEntryDTO.self, from: qData)
            #expect(qDecoded.categoryValue == nil)
        }
    }

#endif
