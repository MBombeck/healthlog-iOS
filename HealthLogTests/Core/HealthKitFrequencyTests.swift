// Diese Suite ruft HealthKit-Symbole — bleibt aus dem SPM-Test-Build raus.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    @Suite("HealthKitService default-types + wire converter")
    struct HealthKitFrequencyTests {
        @Test("defaultReadTypes enthaelt mindestens 23 Server-supported Identifiers")
        func defaultReadTypesCount() {
            // v0.5.2 F2: 18 + 4 mobility/body-composition (walkingSpeed,
            // walkingAsymmetryPercentage, walkingStepLength, bodyMassIndex)
            // + 1 Category + TimeInDaylight (iOS 17+) → ≥ 23 on iOS 18.
            #expect(HealthKitService.defaultReadTypes.count >= 23)
        }

        @Test("defaultReadTypes registers v0.5.2 F2 mobility + BMI HK identifiers")
        func defaultReadTypesIncludesF2Additions() {
            let ids = Set(HealthKitService.defaultReadTypes.compactMap { ($0 as? HKQuantityType)?.identifier })
            #expect(ids.contains(HKQuantityTypeIdentifier.walkingSpeed.rawValue))
            #expect(ids.contains(HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue))
            #expect(ids.contains(HKQuantityTypeIdentifier.walkingStepLength.rawValue))
            #expect(ids.contains(HKQuantityTypeIdentifier.bodyMassIndex.rawValue))
            // The three server-backed F2 types were already in the set
            // before F2, but re-pin them here so a future trim is caught.
            #expect(ids.contains(HKQuantityTypeIdentifier.restingHeartRate.rawValue))
            #expect(ids.contains(HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue))
            #expect(ids.contains(HKQuantityTypeIdentifier.vo2Max.rawValue))
        }

        @Test("preferredUnit registers F2 mobility + BMI wire mapping", arguments: [
            (HKQuantityTypeIdentifier.walkingSpeed.rawValue, "m/s"),
            (HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue, "%"),
            (HKQuantityTypeIdentifier.walkingStepLength.rawValue, "m"),
            (HKQuantityTypeIdentifier.bodyMassIndex.rawValue, "kg/m^2")
        ])
        func wireConverterMapsF2(args: (identifier: String, expectedSymbol: String)) {
            let unit = HealthKitWireConverter.preferredUnit(for: args.identifier)
            #expect(unit != nil, "Missing wire unit for \(args.identifier)")
            #expect(unit?.wireSymbol == args.expectedSymbol, "Wrong wire symbol for \(args.identifier)")
        }
    }

#endif
