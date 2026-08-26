import Foundation
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog

// Architectural contract tests for the `HealthKitService` write-back
// surface. Built for v0.5.4 BF-5 ("Apple Health lokale Daten werden nicht
// dargestellt"): the operator-reported failure mode was that
// `defaultWriteTypes` lagged the kinds the Capture sheet accepts —
// `MeasureSheetView` invited the user to enter BodyFat, BodyTemp, SpO2,
// RHR, HRV, VO2max, BMI, but the system permission sheet only asked for
// the original 4 (bodyMass + BP-sys + BP-dia + bloodGlucose). Manual
// entries for the missing kinds then fell through the `writeMeasurement`
// default branch, never round-tripping into Apple Health.
//
// These tests lock the contract from the outside so any future regression
// (dropping a write-type, adding a Capture kind without the matching HK
// type) breaks at CI rather than on the operator's device.
#if canImport(HealthKit)

    @Suite("HealthKit write-types contract (BF-5)")
    struct HealthKitWriteCoverageTests {
        // MARK: - defaultWriteTypes membership

        /// Every kind that has an iOS-side write-counterpart MUST appear in
        /// `defaultWriteTypes`. The system permission sheet uses exactly this
        /// set; missing entries silently turn into `HKErrorAuthorizationDenied`
        /// at save time (the operator-visible failure was the silence — no
        /// pulse-back into Apple Health, no error toast on the iOS side).
        @Test("defaultWriteTypes covers every kind that has a HK write-counterpart")
        func defaultWriteTypesCoverage() {
            let identifiers = Set(HealthKitService.defaultWriteTypes.map(\.identifier))
            let expected: Set<String> = [
                HKQuantityTypeIdentifier.bodyMass.rawValue,
                HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
                HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue,
                HKQuantityTypeIdentifier.bloodGlucose.rawValue,
                HKQuantityTypeIdentifier.heartRate.rawValue,
                HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
                HKQuantityTypeIdentifier.bodyTemperature.rawValue,
                HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                HKQuantityTypeIdentifier.restingHeartRate.rawValue,
                HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                HKQuantityTypeIdentifier.vo2Max.rawValue,
                HKQuantityTypeIdentifier.bodyMassIndex.rawValue
            ]
            let missing = expected.subtracting(identifiers)
            #expect(
                missing.isEmpty,
                "defaultWriteTypes is missing: \(missing.sorted()). Did you forget to add a new manual-entry kind?"
            )
        }

        /// **Amended by 16-03, deliberately and by name (decision E2).**
        ///
        /// The count is a census, not a ceiling: its job is to make an addition
        /// to the write set a thing someone has to state out loud, and this is
        /// that statement. The twelfth-to-thirteenth member is
        /// `HKObjectType.stateOfMindType()`, which joined because the operator
        /// moved EKG and Stimmung into the first HealthKit sheet on 2026-08-22 —
        /// mood is read AND write, since the app mirrors recorded moods back
        /// into Apple Health.
        ///
        /// The ECG type did NOT join: the app never writes a waveform back, and
        /// keeping it out of this set is what leaves `HKReadinessStore`'s
        /// write-derived connection state untouched by the read-side half of E2.
        @Test("defaultWriteTypes count matches the BF-5 surface plus E2's State-of-Mind write")
        func defaultWriteTypesExpansion() {
            // 4 originals + 7 v0.5.4 BF-5 additions + 1 heartRate that was
            // already used for `.pulse` writes but only got formal write-auth
            // with that change = 12, + 1 State of Mind (16-03 / E2) = 13.
            #expect(HealthKitService.defaultWriteTypes.count == 13)
            #expect(
                HealthKitService.defaultWriteTypes.map(\.identifier).contains(HKObjectType.stateOfMindType().identifier),
                "the thirteenth member is E2's State-of-Mind write, not an unexplained addition"
            )
            #expect(
                !HealthKitService.defaultWriteTypes.map(\.identifier)
                    .contains(HKObjectType.electrocardiogramType().identifier),
                "the ECG type is read-only — putting it here would move the write-derived connection state"
            )
        }

        // MARK: - defaultReadTypes still covers everything

        /// The read-types set must continue to span the 18 MetricKinds plus
        /// the cumulative auxiliaries (activeEnergy / flights / distance /
        /// audio-exposure / time-in-daylight) — write-types expansion must
        /// not have accidentally shrunk reads via copy-paste error.
        @Test("defaultReadTypes still covers all 18 kinds + cumulative auxiliaries")
        func readTypesUnchangedCount() {
            let identifiers = Set(HealthKitService.defaultReadTypes.compactMap { ($0 as? HKSampleType)?.identifier })
            // All 16 quantity types touched by MeasureSheetView + sleep
            // category + activeEnergy + flightsClimbed + distance + audio
            // (env + headphone). Time-in-daylight is iOS-17+ optional.
            let mustHave: Set<String> = [
                HKQuantityTypeIdentifier.bodyMass.rawValue,
                HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
                HKQuantityTypeIdentifier.bodyTemperature.rawValue,
                HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
                HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue,
                HKQuantityTypeIdentifier.bloodGlucose.rawValue,
                HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                HKQuantityTypeIdentifier.heartRate.rawValue,
                HKQuantityTypeIdentifier.restingHeartRate.rawValue,
                HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                HKQuantityTypeIdentifier.vo2Max.rawValue,
                HKQuantityTypeIdentifier.stepCount.rawValue,
                HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
                HKQuantityTypeIdentifier.flightsClimbed.rawValue,
                HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                HKQuantityTypeIdentifier.walkingSpeed.rawValue,
                HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue,
                HKQuantityTypeIdentifier.walkingStepLength.rawValue,
                HKQuantityTypeIdentifier.bodyMassIndex.rawValue,
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
                HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue
            ]
            let missing = mustHave.subtracting(identifiers)
            #expect(missing.isEmpty, "defaultReadTypes is missing: \(missing.sorted())")
        }
    }

    // MARK: - Server-origin mirror policy (W-HKMIRROR)

    /// Bidirectional HealthKit: measurements that arrive FROM the server
    /// (entered on web / another device / imported) are mirrored back into
    /// Apple Health so this iPhone's Health app isn't missing rows the user
    /// didn't type here. These tests lock the source/kind policy + the
    /// anti-dup metadata contract. The live `HKHealthStore` save + idempotency
    /// probe can't run in CI (no Health DB), so we assert the pure decision
    /// surface (`shouldMirrorFromServer`) and the sample builder
    /// (`quantitySamples`) that feed it.
    @Suite("HealthKit server-origin mirror policy (W-HKMIRROR)")
    struct HealthKitServerMirrorTests {
        private func makeMeasurement(
            id: String = "srv-1",
            kind: MetricKind = .weight,
            value: MeasurementValue = .scalar(72.4),
            source: MeasurementSource
        ) -> HealthLog.Measurement {
            HealthLog.Measurement(id: id, kind: kind, recordedAt: .now, value: value, source: source)
        }

        @Test("server-origin withings + import_ rows with an HK write-type are mirrored")
        func mirrorsUserAuthoredElsewhere() {
            #expect(HealthKitService.shouldMirrorFromServer(makeMeasurement(source: .withings)))
            #expect(HealthKitService.shouldMirrorFromServer(makeMeasurement(source: .import_)))
        }

        @Test("manual + appleHealth + wearable sources are NOT mirrored")
        func excludesNonAuthoringSources() {
            // .manual already round-trips at create-time.
            #expect(!HealthKitService.shouldMirrorFromServer(makeMeasurement(source: .manual)))
            // .appleHealth originated in HealthKit — writing back = duplicate.
            #expect(!HealthKitService.shouldMirrorFromServer(makeMeasurement(source: .appleHealth)))
            // wearable read-only sources belong to their provider.
            #expect(!HealthKitService.shouldMirrorFromServer(makeMeasurement(source: .whoop)))
            #expect(!HealthKitService.shouldMirrorFromServer(makeMeasurement(source: .fitbit)))
        }

        @Test("a read-only-source kind (steps) is NOT written back even from a mirrored source")
        func excludesReadOnlyKind() {
            // steps has no HK write-counterpart in `quantitySamples`; even a
            // withings-sourced steps row must not be mirrored.
            let steps = makeMeasurement(kind: .steps, value: .scalar(8000), source: .withings)
            #expect(!HealthKitService.shouldMirrorFromServer(steps))
            #expect(HealthKitService.quantitySamples(for: steps, metadata: [:]).isEmpty)
        }

        @Test("mirrored sample carries externalUUID == measurement.id (anti-dup / read-filter skip)")
        func sampleCarriesExternalUUID() {
            let m = makeMeasurement(id: "srv-abc", kind: .glucose, value: .scalar(95), source: .import_)
            let metadata: [String: Any] = [HKMetadataKeyExternalUUID: m.id]
            let samples = HealthKitService.quantitySamples(for: m, metadata: metadata)
            #expect(samples.count == 1)
            #expect(samples.first?.metadata?[HKMetadataKeyExternalUUID] as? String == "srv-abc")
        }

        @Test("blood-pressure mirrors to two samples both stamped with the same externalUUID")
        func bloodPressureMirrorsBothSamples() {
            let m = makeMeasurement(
                id: "srv-bp",
                kind: .bloodPressure,
                value: .bloodPressure(systolic: 120, diastolic: 80),
                source: .withings
            )
            let metadata: [String: Any] = [HKMetadataKeyExternalUUID: m.id]
            let samples = HealthKitService.quantitySamples(for: m, metadata: metadata)
            #expect(samples.count == 2)
            #expect(samples.allSatisfy { $0.metadata?[HKMetadataKeyExternalUUID] as? String == "srv-bp" })
        }

        // MARK: - W-HKBACKFILL — platform-free policy stays aligned

        /// A representative value per kind so `quantitySamples` produces its real
        /// branch output (a `.scalar`/`.bloodPressure` mismatch would yield `[]`
        /// and falsely look unwritable).
        private func representativeValue(for kind: MetricKind) -> MeasurementValue {
            kind == .bloodPressure ? .bloodPressure(systolic: 120, diastolic: 80) : .scalar(1)
        }

        @Test("MetricKind.serverMirrorWritableKinds matches exactly what quantitySamples writes")
        func writableKindsSetMatchesSampleBuilder() {
            // The platform-free set the backfill driver iterates MUST equal the
            // set of kinds the authoritative `quantitySamples` switch can build a
            // sample for — otherwise the backfill would either skip a writable
            // kind or pointlessly page a kind the mirror always drops.
            let actuallyWritable = Set(MetricKind.allCases.filter { kind in
                !HealthKitService.quantitySamples(
                    for: makeMeasurement(kind: kind, value: representativeValue(for: kind), source: .withings),
                    metadata: [:]
                ).isEmpty
            })
            #expect(MetricKind.serverMirrorWritableKinds == actuallyWritable)
        }

        @Test("isServerMirrorEligible matches the mirror's source half for every source")
        func sourceEligibilityMatchesMirror() {
            for source in [MeasurementSource.manual, .appleHealth, .withings, .whoop, .fitbit, .import_] {
                // A weight row is always kind-writable, so `shouldMirrorFromServer`
                // reduces to the source predicate for this probe.
                let m = makeMeasurement(kind: .weight, value: .scalar(72), source: source)
                #expect(source.isServerMirrorEligible == HealthKitService.shouldMirrorFromServer(m))
            }
            #expect(MeasurementSource.serverMirrorEligible == [.withings, .import_])
        }
    }

#endif
