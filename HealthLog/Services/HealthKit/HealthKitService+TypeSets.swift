import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// Default Read/Write/Event type-sets + the protocol-seam instance
    /// accessors. Extracted from `HealthKitService.swift` (file_length
    /// discipline — pure move, no behaviour change). The sets are static
    /// computed values with no actor-state read, so the instance accessors
    /// stay `nonisolated`.
    public extension HealthKitService {
        // MARK: - Default Type-Sets

        static var defaultReadTypes: Set<HKObjectType> {
            var set = Set<HKObjectType>()
            // Vitals (point metrics, latest semantics)
            set.insert(HKQuantityType(.bodyMass))
            set.insert(HKQuantityType(.bodyFatPercentage))
            set.insert(HKQuantityType(.bodyTemperature))
            set.insert(HKQuantityType(.bloodPressureSystolic))
            set.insert(HKQuantityType(.bloodPressureDiastolic))
            set.insert(HKQuantityType(.bloodGlucose))
            set.insert(HKQuantityType(.oxygenSaturation))
            // v0.7.0 — respiratory rate (breaths/min). Apple Watch + supported
            // sensors write it overnight; closes the stale v0.5.6-deferred note.
            set.insert(HKQuantityType(.respiratoryRate))
            // Cardio (point + cumulative)
            set.insert(HKQuantityType(.heartRate))
            set.insert(HKQuantityType(.restingHeartRate))
            set.insert(HKQuantityType(.heartRateVariabilitySDNN))
            set.insert(HKQuantityType(.vo2Max))
            // Activity (cumulative, sum semantics)
            set.insert(HKQuantityType(.stepCount))
            set.insert(HKQuantityType(.activeEnergyBurned))
            set.insert(HKQuantityType(.flightsClimbed))
            set.insert(HKQuantityType(.distanceWalkingRunning))
            // v0.5.2 F2 — mobility + body-composition additions. iPhone reports
            // walkingSpeed / walkingAsymmetry / walkingStepLength automatically
            // when carried during walks; BMI is written by Apple's Health-App
            // whenever weight + height are present, plus by most smart scales.
            set.insert(HKQuantityType(.walkingSpeed))
            set.insert(HKQuantityType(.walkingAsymmetryPercentage))
            set.insert(HKQuantityType(.walkingStepLength))
            // v0.7.0 — sibling of walking asymmetry. Apple Health surfaces
            // the four-metric mobility cluster (speed / asymmetry / step
            // length / double-support); we now cover all four.
            set.insert(HKQuantityType(.walkingDoubleSupportPercentage))
            // W28d — Apple walking-steadiness fall-risk classifier.
            set.insert(HKQuantityType(.appleWalkingSteadiness))
            set.insert(HKQuantityType(.bodyMassIndex))
            // W-HKREAD — nine additive quantity signals the server maps
            // end-to-end (server v1.10.0). Collected via the Spezi
            // `CollectSamples` path; their read auth must join the always-on
            // sheet so the collectors don't trip `HKErrorAuthorizationDenied`.
            set.insert(HKQuantityType(.walkingHeartRateAverage))
            set.insert(HKQuantityType(.heartRateRecoveryOneMinute))
            set.insert(HKQuantityType(.appleSleepingWristTemperature))
            set.insert(HKQuantityType(.appleSleepingBreathingDisturbances))
            set.insert(HKQuantityType(.leanBodyMass))
            set.insert(HKQuantityType(.sixMinuteWalkTestDistance))
            set.insert(HKQuantityType(.stairAscentSpeed))
            set.insert(HKQuantityType(.stairDescentSpeed))
            set.insert(HKQuantityType(.numberOfTimesFallen))
            // W-HKREAD — six categorical EVENT classes collected by the
            // dedicated `HeartHealthEventImporter` (not expressible in the
            // Spezi `CollectSamples` DSL the same way the importer needs).
            // Their read auth must also join the always-on sheet.
            set.formUnion(Self.eventReadTypes)
            // Sleep (per-stage rows server-side)
            set.insert(HKCategoryType(.sleepAnalysis))
            // Audio exposure
            set.insert(HKQuantityType(.environmentalAudioExposure))
            set.insert(HKQuantityType(.headphoneAudioExposure))
            // Time in Daylight (iOS 17+) — referenziert via raw identifier so the
            // build doesn't require the symbol on older SDKs. The HK runtime just
            // ignores unknown identifiers if the device's iOS version doesn't
            // support it.
            if #available(iOS 17.0, *),
               let timeInDaylight = HKObjectType
               .quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifierTimeInDaylight"))
            {
                set.insert(timeInDaylight)
            }
            // v1.15 W-WORKOUT — workout sessions. Collected via the dedicated
            // `WorkoutHealthKitImporter` (HKWorkout is not expressible in the
            // SpeziHealthKit `CollectSamples` DSL), uploaded to
            // `POST /api/workouts/batch`, surfaced in the existing Workouts UI.
            // Read-only — we never write HKWorkout back, so it stays out of
            // `defaultWriteTypes`.
            set.insert(HKObjectType.workoutType())
            // **16-03 / decision E2 (operator, 2026-08-22): "EKG und Stimmung
            // wandern in das erste HealthKit-Sheet."**
            //
            // Both were deliberate exclusions, and both reasons expired. The
            // ECG's was that until server v1.35.3 there was nowhere to send a
            // waveform, so asking for it in onboarding would have been an empty
            // promise; the route exists now. The mood sync's was that it is a
            // device-local concern the server knows nothing about — still true,
            // and still not a reason to bury it under Einstellungen → Apple
            // Health → Weitere Synchronisierungen, which is the drawer the
            // operator called unauffindbar (J1) and the reason he did not find
            // either type in the first sheet's list (K11).
            //
            // Apple always asks: "in the first sheet" means the types are in
            // this set, not that anything is granted silently. The
            // corresponding device-local sync stores turn on when the
            // onboarding grant completes — see `FirstSheetSyncAdoption`.
            //
            // **Medications are NOT here, and this is the fence.** The operator's
            // own E2 wording named EKG and Stimmung and excluded medications:
            // `HKUserAnnotatedMedicationType` is iOS-26-only and accepts ONLY
            // `requestPerObjectReadAuthorization`. Handing it to
            // `requestAuthorization(toShare:read:)` — which is exactly what this
            // set is handed to — is an invalid argument that raises an
            // uncatchable ObjC NSException and SIGABRTs the process (documented
            // in `AppleHealthMedicationReader.requestAuthorization()`).
            // `FirstSheetTypeSetTests.medicationTypeIsFencedOutOfEveryDefaultSet`
            // pins that permanently.
            //
            // iOS 18.0 is the deployment target (`project.yml`), so neither
            // needs a runtime OS gate: State of Mind is iOS 18+, the ECG type is
            // far older.
            set.insert(HKObjectType.electrocardiogramType())
            set.insert(HKObjectType.stateOfMindType())
            return set
        }

        /// W-HKREAD — the categorical EVENT-class category types the
        /// ``HeartHealthEventImporter`` reads. Each is a discrete on-device
        /// notification (the device's own certified verdict), NOT a continuous
        /// reading; the server ingests the classification result and never
        /// re-classifies. Read-only — these are never written back, so they
        /// stay out of ``defaultWriteTypes``. `sleepApneaEvent` and
        /// `appleWalkingSteadinessEvent` are iOS 18+; the rest are older, but
        /// the whole app targets iOS 18 so no per-symbol availability guard is
        /// required — the HK runtime simply ignores an unknown identifier.
        static var eventReadTypes: Set<HKObjectType> {
            var set = Set<HKObjectType>()
            set.insert(HKCategoryType(.irregularHeartRhythmEvent))
            set.insert(HKCategoryType(.highHeartRateEvent))
            set.insert(HKCategoryType(.lowHeartRateEvent))
            set.insert(HKCategoryType(.appleWalkingSteadinessEvent))
            set.insert(HKCategoryType(.sleepApneaEvent))
            set.insert(HKCategoryType(.environmentalAudioExposureEvent))
            set.insert(HKCategoryType(.headphoneAudioExposureEvent))
            return set
        }

        /// v0.5.4 BF-5: write-types-set spans every kind that can be entered
        /// manually via `MeasureSheetView`. Before this expansion, only weight,
        /// BP, glucose, pulse made it back into HK on manual entry — every
        /// other kind (BodyFat, BodyTemp, SpO2, BodyWater, BoneMass, RHR, HRV,
        /// VO2 max, BMI) silently bypassed the round-trip. Operator perception:
        /// "ich erfasse hier was, aber Apple Health sieht es nicht."
        ///
        /// The set lines up 1:1 with the `writeMeasurement` switch below — if
        /// you add a new manual-entry kind, you MUST extend BOTH or the system
        /// sheet won't ask for the new permission and saves will throw at
        /// runtime with `HKErrorAuthorizationDenied`.
        static var defaultWriteTypes: Set<HKSampleType> {
            var set = Set<HKSampleType>()
            // Original four (v0.4.x baseline).
            set.insert(HKQuantityType(.bodyMass))
            set.insert(HKQuantityType(.bloodPressureSystolic))
            set.insert(HKQuantityType(.bloodPressureDiastolic))
            set.insert(HKQuantityType(.bloodGlucose))
            // v0.5.4 BF-5 expansion — every manual-entry kind round-trips into HK.
            set.insert(HKQuantityType(.heartRate))
            set.insert(HKQuantityType(.bodyFatPercentage))
            set.insert(HKQuantityType(.bodyTemperature))
            set.insert(HKQuantityType(.oxygenSaturation))
            set.insert(HKQuantityType(.restingHeartRate))
            set.insert(HKQuantityType(.heartRateVariabilitySDNN))
            set.insert(HKQuantityType(.vo2Max))
            set.insert(HKQuantityType(.bodyMassIndex))
            // 16-03 / E2 — the mood sync is read AND write: moods the user
            // records in HealthLog are mirrored into Apple Health's State of
            // Mind (`MoodStore.writeMood`), so a read-only membership would
            // ship a sync whose writes silently no-op with
            // `HKErrorAuthorizationDenied`. The ECG type is deliberately NOT
            // here — the app never writes a waveform back, and keeping it out
            // is also what stops an added read type from moving
            // `HKReadinessStore`'s connection state, which is derived from
            // write types alone.
            //
            // **This one addition is visible to installations already in the
            // field**, and that is the decided route rather than an oversight:
            // a device that granted the old write set now reads
            // `.partiallyGranted(missing: [State of Mind])` and Settings offers
            // the reconnect row again. The DASHBOARD banner stays down —
            // `isConnected` beats the write-auth proxy for anyone who has been
            // through the sheet — because re-raising "Apple Health nicht
            // verbunden" on every existing device would undo K10 with this
            // phase's own other half. Both halves are pinned in
            // `FirstSheetTypeSetTests`.
            set.insert(HKObjectType.stateOfMindType())
            return set
        }

        // MARK: - Instance accessors for HealthKitServiceProtocol

        /// Instance-level read of ``defaultReadTypes`` so the protocol seam
        /// works without callers having to know about a concrete static. The
        /// access is `nonisolated` because the underlying static is a pure
        /// computed value with no actor-state read.
        nonisolated func defaultReadTypes() -> Set<HKObjectType> {
            Self.defaultReadTypes
        }

        /// Instance-level read of ``defaultWriteTypes`` — same rationale as
        /// ``defaultReadTypes()``.
        nonisolated func defaultWriteTypes() -> Set<HKSampleType> {
            Self.defaultWriteTypes
        }
    }

#endif
