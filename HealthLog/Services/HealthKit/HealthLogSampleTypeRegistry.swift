#if canImport(HealthKit)
    import Foundation
    import HealthKit

    /// The exact set of HealthKit sample types HealthLog collects for the server.
    ///
    /// **This is the definition of "every server-bound sample type", not a
    /// convenience list.** Since Phase 07 Wave 2 the app owns collection:
    /// `AppOwnedHealthCollectionCoordinator` walks exactly this set on every pull
    /// trigger, arms a change subscription for the subset
    /// `HealthKitBackgroundDeliveryPolicy` marks background-delivered, and
    /// `SpeziAnchorMigrator.migrateAccountCursors` establishes one owner-scoped
    /// cursor partition per member. An identifier that is missing here is not
    /// collected at all, and one that is present but unresolvable is refused by
    /// `HealthKitSampleTypeResolver` rather than silently widening a query.
    ///
    /// The cardinality is part of the contract, not an accident of editing:
    /// ``count`` is asserted by `HealthLogSampleTypeRegistryTests` and by
    /// `CompleteHealthSyncCompositionTests`, and PROJECT_GUIDE.md states the same
    /// number. Adding or removing a type means changing all three together.
    ///
    /// **1.2 / V4 — one OS-gated member.** HRV as RMSSD exists from iOS 27 on
    /// (see ``HeartRateVariabilityRMSSD``). It joins the set only where the
    /// running system resolves the type, so the contract is 35 on iOS 26 and
    /// older and 36 on iOS 27 and later; the fixed literal stays at 35.
    enum HealthLogSampleTypeRegistry {
        /// How many server-bound sample types the fixed literal below holds.
        ///
        /// Declared separately from the set so a duplicated or dropped line in the
        /// literal below fails a test instead of quietly changing what the app
        /// syncs.
        static let baseExpectedCount = 35

        /// Exactly how many server-bound sample types the app collects on the
        /// running system: the fixed literal plus the OS-gated types this
        /// system resolves.
        static var expectedCount: Int {
            baseExpectedCount + osGatedIdentifiers(rmssdAvailable: HeartRateVariabilityRMSSD.sampleType != nil).count
        }

        /// The OS-gated members for a system that does or does not resolve
        /// RMSSD. A function of its input so a test can pin the iOS 27 shape on
        /// an older simulator.
        static func osGatedIdentifiers(rmssdAvailable: Bool) -> Set<String> {
            rmssdAvailable ? [HeartRateVariabilityRMSSD.identifier] : []
        }

        /// Raw `HKObjectType.identifier` strings — the same values
        /// `HKQuantityType(.stepCount).identifier` returns and the same
        /// values `SpeziHealthKit.SampleType<HKQuantitySample>.id` resolves
        /// to (which is just `hkSampleType.identifier`).
        static let knownIdentifiers: Set<String> = baseIdentifiers.union(
            osGatedIdentifiers(rmssdAvailable: HeartRateVariabilityRMSSD.sampleType != nil)
        )

        /// The fixed literal: every type the app collects on every supported
        /// system.
        static let baseIdentifiers: Set<String> = {
            var identifiers: Set<String> = [
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
                HKQuantityTypeIdentifier.respiratoryRate.rawValue,
                HKQuantityTypeIdentifier.vo2Max.rawValue,
                HKQuantityTypeIdentifier.stepCount.rawValue,
                HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
                HKQuantityTypeIdentifier.flightsClimbed.rawValue,
                HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                HKQuantityTypeIdentifier.walkingSpeed.rawValue,
                HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue,
                HKQuantityTypeIdentifier.walkingStepLength.rawValue,
                HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue,
                // W28d — Apple walking-steadiness fall-risk classifier (0–100 %).
                HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue,
                HKQuantityTypeIdentifier.bodyMassIndex.rawValue,
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
                HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue,
                // W-HKREAD — nine additive HealthKit quantity signals the
                // server maps end-to-end (server v1.10.0). Collected via the
                // Spezi `CollectSamples` path; registered here so the anchor
                // migrator + the read-coverage tests recognise them.
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
            // Time in Daylight ships on iOS 17+; the raw string is stable
            // across SDK levels even when the symbol is unavailable so we
            // can list it directly without an availability guard.
            identifiers.insert("HKQuantityTypeIdentifierTimeInDaylight")
            return identifiers
        }()

        /// Returns `true` if `identifier` is one of the ``expectedCount``
        /// server-bound sample types in ``knownIdentifiers``.
        static func contains(_ identifier: String) -> Bool {
            knownIdentifiers.contains(identifier)
        }
    }
#endif
