// Diese Suite ruft HealthKit-Symbole — bleibt aus dem SPM-Test-Build raus.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    @Suite("HealthKitWireConverter")
    struct HealthKitWireConverterTests {
        // MARK: - Unit Conversion (×100)

        @Test("OxygenSaturation skaliert HK-Fraktion (0.97) auf Server-Prozent (97.0)")
        func spo2Scaling() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.oxygenSaturation),
                quantity: HKQuantity(unit: .percent(), doubleValue: 0.97),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            let entry = entries[0]
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.oxygenSaturation.rawValue)
            #expect(entry.unit == "%")
            // Toleranz für FP-Drift bei der Multiplikation.
            #expect(abs(entry.value - 97.0) < 0.001)
            #expect(entry.sleepStage == nil)
        }

        @Test("BodyFatPercentage skaliert HK-Fraktion (0.234) auf Server-Prozent (23.4)")
        func bodyFatScaling() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.bodyFatPercentage),
                quantity: HKQuantity(unit: .percent(), doubleValue: 0.234),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            let entry = entries[0]
            #expect(entry.unit == "%")
            #expect(abs(entry.value - 23.4) < 0.001)
        }

        @Test("BodyMass lässt Wert unverändert (kg-identity)")
        func bodyMassIdentity() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 78.2),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].value == 78.2)
            #expect(entries[0].unit == "kg")
        }

        @Test("HeartRate ist bpm-identity")
        func heartRateIdentity() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 72.0),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].value == 72.0)
            #expect(entries[0].unit == "bpm")
        }

        // MARK: - Sleep Stages

        @Test("Sleep-Sample emittiert eine Row mit sleepStage codepoint + duration in min")
        func sleepStageDecoder() {
            let start = Date(timeIntervalSince1970: 1_715_673_600)
            let end = start.addingTimeInterval(90 * 60) // 90 min
            let sample = HKCategorySample(
                type: HKCategoryType(.sleepAnalysis),
                value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                start: start,
                end: end
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            let entry = entries[0]
            #expect(entry.hkIdentifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
            #expect(entry.value == 90.0)
            #expect(entry.unit == "min")
            #expect(entry.sleepStage == HKCategoryValueSleepAnalysis.asleepREM.rawValue)
            #expect(entry.startDate == start)
            #expect(entry.endDate == end)
        }

        @Test(
            "Sleep stage codepoints decken HKCategoryValueSleepAnalysis ab",
            arguments: [
                HKCategoryValueSleepAnalysis.inBed.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.awake.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
        )
        func sleepStageRoundTrip(stage: Int) {
            let start = Date(timeIntervalSince1970: 1_715_673_600)
            let sample = HKCategorySample(
                type: HKCategoryType(.sleepAnalysis),
                value: stage,
                start: start,
                end: start.addingTimeInterval(1800)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries[0].sleepStage == stage)
            // Server-Range-Check (08-locked-contracts.md §2.1: int 0..20).
            #expect(stage >= 0 && stage <= 20)
        }

        // MARK: - Device-Type-Mapper

        @Test("nil HKDevice → unknown")
        func nilDevice() {
            #expect(HealthKitWireConverter.deviceType(for: nil) == .unknown)
        }

        @Test(
            "HKDevice.model heuristik mapped die haeufigsten Apple- und Drittanbieter-Geräte",
            arguments: [
                ("Apple Watch", HealthKitDeviceType.watch),
                ("apple watch series 9", HealthKitDeviceType.watch),
                ("iPhone", HealthKitDeviceType.phone),
                ("iPhone15,3", HealthKitDeviceType.phone),
                ("iPad Pro", HealthKitDeviceType.phone),
                ("Smart Scale Body+", HealthKitDeviceType.scale),
                ("Oura Ring Gen3", HealthKitDeviceType.ring),
                ("Whoop Band 4", HealthKitDeviceType.band)
            ]
        )
        func deviceMapping(model: String, expected: HealthKitDeviceType) {
            let device = HKDevice(
                name: nil,
                manufacturer: nil,
                model: model,
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: nil,
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
            #expect(HealthKitWireConverter.deviceType(for: device) == expected)
        }

        @Test("Fallback aus device.name wenn model fehlt")
        func deviceNameFallback() {
            let device = HKDevice(
                name: "Mein Apple Watch",
                manufacturer: "Apple",
                model: nil,
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: nil,
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
            #expect(HealthKitWireConverter.deviceType(for: device) == .watch)
        }

        // MARK: - Unit-Tabellen Drift-Check

        @Test(
            "Alle wire-supported HKQuantityTypeIdentifiers haben einen Wire-Unit-Eintrag",
            arguments: [
                HKQuantityTypeIdentifier.bodyMass.rawValue,
                HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
                HKQuantityTypeIdentifier.bodyTemperature.rawValue,
                HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
                HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue,
                HKQuantityTypeIdentifier.heartRate.rawValue,
                HKQuantityTypeIdentifier.restingHeartRate.rawValue,
                HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                HKQuantityTypeIdentifier.respiratoryRate.rawValue,
                HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                HKQuantityTypeIdentifier.bloodGlucose.rawValue,
                HKQuantityTypeIdentifier.stepCount.rawValue,
                HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
                HKQuantityTypeIdentifier.flightsClimbed.rawValue,
                HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                HKQuantityTypeIdentifier.vo2Max.rawValue,
                HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue,
                HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
                HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue,
                "HKQuantityTypeIdentifierTimeInDaylight"
            ]
        )
        func unitTableCoverage(identifier: String) {
            #expect(HealthKitWireConverter.preferredUnit(for: identifier) != nil)
        }

        // MARK: - v0.7.0 adopt-and-stream conversions

        @Test("RespiratoryRate ist br/min-identity (count/min → br/min)")
        func respiratoryRateIdentity() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.respiratoryRate),
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 16.0),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].hkIdentifier == HKQuantityTypeIdentifier.respiratoryRate.rawValue)
            #expect(entries[0].value == 16.0)
            #expect(entries[0].unit == "br/min")
        }

        @Test("WalkingDoubleSupport carries the RAW HK fraction (server scales ×100)")
        func walkingDoubleSupportRawFraction() {
            // W-SERVER-SYNC (server v1.5.5): the server now scales the gait
            // percentages ×100 server-side, so the wire must carry the raw
            // HealthKit fraction (0…1) — iOS no longer pre-multiplies.
            let sample = HKQuantitySample(
                type: HKQuantityType(.walkingDoubleSupportPercentage),
                quantity: HKQuantity(unit: .percent(), doubleValue: 0.29),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].unit == "%")
            #expect(abs(entries[0].value - 0.29) < 0.001)
        }

        @Test("WalkingAsymmetry carries the RAW HK fraction (server scales ×100)")
        func walkingAsymmetryRawFraction() {
            let sample = HKQuantitySample(
                type: HKQuantityType(.walkingAsymmetryPercentage),
                quantity: HKQuantity(unit: .percent(), doubleValue: 0.12),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_600)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].unit == "%")
            #expect(abs(entries[0].value - 0.12) < 0.001)
        }

        @Test("EnvironmentalAudioExposure ist dBA-identity")
        func environmentalAudioExposureIdentity() {
            // EnvironmentalAudioExposure is a duration sample — HealthKit
            // enforces a ≥0.001s minimum and throws _HKObjectValidationFailure
            // on a zero-length window, so give it a realistic 1-minute window.
            let sample = HKQuantitySample(
                type: HKQuantityType(.environmentalAudioExposure),
                quantity: HKQuantity(unit: .decibelAWeightedSoundPressureLevel(), doubleValue: 68.0),
                start: Date(timeIntervalSince1970: 1_715_673_600),
                end: Date(timeIntervalSince1970: 1_715_673_660)
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries[0].value == 68.0)
            #expect(entries[0].unit == "dBA")
        }

        @Test("Unbekannter Identifier liefert nil — converter dropped die Sample")
        func unknownIdentifier() {
            #expect(HealthKitWireConverter.preferredUnit(for: "HKQuantityTypeIdentifierMadeUp") == nil)
        }
    }

#endif
