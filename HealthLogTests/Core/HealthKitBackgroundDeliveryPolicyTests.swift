// W2 — background-delivery (energy) policy. R3 — aggressive-cadence promotion.
// Pins the per-type `continueInBackground` + `startsAutomatically` decisions
// the `HealthLogSpeziDelegate` collectors are driven by. SpeziHealthKit exposes
// only the boolean (delivery frequency is hardcoded `.immediate`), so the
// invariant we test is: vital-signs AND the R3 aggressive-cadence promotions
// (heartRate / stepCount / sleepAnalysis) wake the app in the background;
// cumulative / low-urgency types do not — none wakes the app to upload nothing.
//
// The assertions key on the EXACT `SampleType.<type>.id` strings the delegate
// passes, so an Apple identifier-string drift (e.g. bloodOxygen ↔
// oxygenSaturation) would fail this test rather than silently flip a vital
// sign off background delivery.
#if !SWIFT_PACKAGE && canImport(HealthKit) && canImport(SpeziHealthKit)

    @testable import HealthLog
    import SpeziHealthKit
    import Testing

    @Suite("HealthKitBackgroundDeliveryPolicy — per-type background wakeups")
    struct HealthKitBackgroundDeliveryPolicyTests {
        @Test("Vital-signs keep continueInBackground = true (immediate delivery)")
        func vitalSignsStayOnBackground() {
            // Use the real SampleType.id the delegate passes — catches any
            // identifier-string drift between Apple's case alias and rawValue.
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.heartRateVariabilitySDNN.id))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.restingHeartRate.id))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bloodOxygen.id))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bodyTemperature.id))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bloodPressureSystolic.id))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bloodPressureDiastolic.id))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bloodGlucose.id))
        }

        @Test("R3 aggressive-cadence types are on real background delivery + automatic start")
        func aggressiveCadenceTypesAreBackgroundAndAutomatic() {
            // R3 operator decision (reception over battery): heartRate,
            // stepCount, and sleepAnalysis are lifted onto the SAME
            // start:.automatic + continueInBackground:true mechanic as the
            // vital-signs. This REPLACES the v0.14 audit-#1 demotion that pinned
            // heartRate (and the batch-natured stepCount/sleep) to the
            // foreground/BGTask sweep — the old test asserted the OPPOSITE here.
            for id in [SampleType.heartRate.id, SampleType.stepCount.id, SampleType.sleepAnalysis.id] {
                #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: id))
                #expect(HealthKitBackgroundDeliveryPolicy.startsAutomatically(for: id))
            }
        }

        @Test("Cumulative + low-urgency types do NOT wake the app in the background")
        func lowUrgencyTypesAreNotBackground() {
            // R3: heartRate / stepCount / sleepAnalysis are NO LONGER asserted
            // here — they moved to the aggressive-cadence background set (see
            // aggressiveCadenceTypesAreBackgroundAndAutomatic).
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.activeEnergyBurned.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.flightsClimbed.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.distanceWalkingRunning.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bodyMass.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bodyFatPercentage.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.vo2Max.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.environmentalAudioExposure.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.headphoneAudioExposure.id))
            // Low-urgency types also stay start: .manual (no automatic observer).
            #expect(!HealthKitBackgroundDeliveryPolicy.startsAutomatically(for: SampleType.bodyMass.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.startsAutomatically(for: SampleType.activeEnergyBurned.id))
        }

        @Test("Low-urgency gait + mobility types are never background-delivered")
        func deferredTypesAreNotBackground() {
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.respiratoryRate.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.walkingSpeed.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.walkingAsymmetryPercentage.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.walkingStepLength.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.walkingDoubleSupportPercentage.id))
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: SampleType.bodyMassIndex.id))
        }

        @Test("The identifier sets are pairwise disjoint")
        func setsAreDisjoint() {
            // vital, aggressive-cadence, and low-urgency must never overlap —
            // an identifier in two buckets would make its delivery mode
            // ambiguous (background lever set from one, start lever from another).
            #expect(HealthKitBackgroundDeliveryPolicy.vitalSignIdentifiers
                .isDisjoint(with: HealthKitBackgroundDeliveryPolicy.lowUrgencyIdentifiers))
            #expect(HealthKitBackgroundDeliveryPolicy.aggressiveCadenceIdentifiers
                .isDisjoint(with: HealthKitBackgroundDeliveryPolicy.lowUrgencyIdentifiers))
            #expect(HealthKitBackgroundDeliveryPolicy.aggressiveCadenceIdentifiers
                .isDisjoint(with: HealthKitBackgroundDeliveryPolicy.vitalSignIdentifiers))
        }

        @Test("continueInBackground and startsAutomatically agree on every classified type")
        func backgroundAndAutomaticLeversNeverDrift() {
            // The two levers are flipped together by design (an armed background
            // observer implies an automatically-started query). Assert the
            // predicates stay in lockstep across the whole classified set.
            let all = HealthKitBackgroundDeliveryPolicy.automaticBackgroundIdentifiers
                .union(HealthKitBackgroundDeliveryPolicy.lowUrgencyIdentifiers)
            for id in all {
                #expect(
                    HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: id)
                        == HealthKitBackgroundDeliveryPolicy.startsAutomatically(for: id)
                )
            }
        }
    }

#endif
