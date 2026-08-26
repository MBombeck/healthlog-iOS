//
//  MetricFHIRMapper.swift
//  HealthLog (HealthLogCore — plattformfrei)
//
//  Created 2026-05-22 — v0.6.0 H.1 LOINC mapping table.
//
//  Hardcoded MetricKind → LOINC + UCUM table per
//  `.planning/v056-marathon/v060-research.md` ("LOINC mapping table —
//  draft — physician review pending"). Pure value-types only — no
//  FHIRModels / SpeziFHIR dependency so this layer can be tested on
//  any Swift platform.
//
//  Code system: http://loinc.org
//  Unit system: http://unitsofmeasure.org (UCUM)
//
//  Walking-* + body-composition + glucose-context discriminator rows
//  carry `physicianReviewPending: true` and ship to clinician review
//  in `docs/fhir-loinc-mapping.md` (H.1 sub-deliverable). The H.5
//  export sheet surfaces a disclaimer for those rows.
//

import Foundation

/// Maps `MetricKind` cases to their FHIR `Observation.code` LOINC entry
/// and `Observation.valueQuantity.{code,unit}` UCUM entry.
///
/// The mapper is intentionally a `enum`-namespace (non-instantiable) so
/// the H.2 `MeasurementFHIRMapper` (which lives in the iOS-only side
/// because it imports `ModelsR4`) can call it as a free function.
public enum MetricFHIRMapper {
    // MARK: - Blood-pressure panel constants

    /// LOINC `85354-9` — "Blood pressure panel with all children
    /// optional". FHIR R4 BP is a single `Observation` with this code
    /// in `Observation.code` and two children in `Observation.component`
    /// (systolic + diastolic) — **not** three separate Observations.
    public static let bloodPressurePanelLOINC = LOINCCode(
        code: "85354-9",
        display: "Blood pressure panel with all children optional"
    )

    /// LOINC `8480-6` — "Systolic blood pressure".
    public static let bloodPressureSystolicLOINC = LOINCCode(
        code: "8480-6",
        display: "Systolic blood pressure"
    )

    /// LOINC `8462-4` — "Diastolic blood pressure".
    public static let bloodPressureDiastolicLOINC = LOINCCode(
        code: "8462-4",
        display: "Diastolic blood pressure"
    )

    // MARK: - Glucose context-specific LOINC codes

    //
    // Glucose LOINC depends on the meal-time context recorded with the
    // sample. The default mapping (`mapping(for: .glucose)`) returns
    // 2339-0 ("Glucose [Mass/volume] in Blood"), which is appropriate
    // for random / unspecified samples. When a `GlucoseContext` is
    // present, the H.2 mapper should call `glucoseMapping(context:)`
    // to pick the more specific code.
    //
    // App's `GlucoseContext` cases: fasting / beforeMeal / afterMeal /
    // bedtime. Research-spec terminology (random / fasting /
    // postprandial) maps as:
    //   - .fasting       → 1558-6 (Fasting glucose, blood)
    //   - .beforeMeal    → 1558-6 (treat as fasting / pre-prandial)
    //   - .afterMeal     → 1521-4 (Post meal glucose, blood)
    //   - .bedtime       → 2339-0 (Random glucose — no LOINC for bedtime
    //                              specifically; falls back to generic)

    private static let glucoseRandomLOINC = LOINCCode(
        code: "2339-0",
        display: "Glucose [Mass/volume] in Blood",
        physicianReviewPending: true
    )

    private static let glucoseFastingLOINC = LOINCCode(
        code: "1558-6",
        display: "Fasting glucose [Mass/volume] in Serum or Plasma",
        physicianReviewPending: true
    )

    private static let glucosePostprandialLOINC = LOINCCode(
        code: "1521-4",
        display: "Glucose [Mass/volume] in Serum or Plasma --2 hours post meal",
        physicianReviewPending: true
    )

    // MARK: - Per-MetricKind mapping

    // 09-08 — Phase 9 re-enabled `function_body_length` repository-wide. This
    // body is not reducible without losing what makes it auditable: the
    // exhaustive `switch` is the compiler check that forces a newly added
    // `MetricKind` to land its LOINC/UCUM entry in the same commit. A
    // table-driven dictionary compiles fine with a kind missing, and a clinical
    // export would then omit that metric silently.
    // function_body_length exception (owner: 09-08): exhaustive LOINC/UCUM table, one row per MetricKind.
    // swiftlint:disable function_body_length
    /// Returns the LOINC/UCUM mapping for `kind`, or `nil` if the kind
    /// is deliberately unmapped (currently no kinds are unmapped — all
    /// 18 cases have entries).
    ///
    /// The exhaustive `switch` over the 18 `MetricKind` cases trips the
    /// `cyclomatic_complexity` lint; the trade-off is deliberate — a
    /// table-driven `[MetricKind: …]` dictionary would silently allow a
    /// missing kind to compile, whereas this `switch` forces every new
    /// `MetricKind` addition to land an entry at the same time.
    public static func mapping(for kind: MetricKind) -> MetricFHIRMapping? { // swiftlint:disable:this cyclomatic_complexity

        switch kind {
        case .weight:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "29463-7", display: "Body weight"),
                ucum: UCUMUnit(unit: "kg")
            )

        case .bloodPressure:
            // The panel LOINC sits in `Observation.code`; the two
            // component LOINCs sit in `Observation.component[]`. We
            // return the panel code here; the H.2 mapper assembles the
            // components via the `bloodPressure{Systolic,Diastolic}LOINC`
            // statics. UCUM applies to each component (mm[Hg]) — the
            // panel itself has no unit.
            MetricFHIRMapping(
                kind: kind,
                loinc: bloodPressurePanelLOINC,
                ucum: UCUMUnit(unit: "mm[Hg]")
            )

        case .pulse:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "8867-4", display: "Heart rate"),
                ucum: UCUMUnit(unit: "/min")
            )

        case .glucose:
            // Default to random / generic. Use `glucoseMapping(context:)`
            // for context-specific (fasting / postprandial).
            MetricFHIRMapping(
                kind: kind,
                loinc: glucoseRandomLOINC,
                ucum: UCUMUnit(unit: "mg/dL")
            )

        case .bodyFat:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "41982-0",
                    display: "Percentage of body fat Measured",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "%")
            )

        case .bodyTemperature:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "8310-5", display: "Body temperature"),
                ucum: UCUMUnit(unit: "Cel")
            )

        case .spo2:
            // 59408-5 ("Oxygen saturation in Arterial blood by Pulse
            // oximetry") is preferred over the generic 2708-6
            // ("Oxygen saturation in Blood") because Apple Health
            // sources spO2 from pulse oximetry on Apple Watch.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "59408-5",
                    display: "Oxygen saturation in Arterial blood by Pulse oximetry"
                ),
                ucum: UCUMUnit(unit: "%")
            )

        case .bodyWater:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "73704-9",
                    display: "Body water by Bioelectrical impedance analysis",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        case .boneMass:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "73708-0",
                    display: "Bone mineral content by DXA",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        case .sleep:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "93832-4", display: "Sleep duration"),
                ucum: UCUMUnit(unit: "h")
            )

        case .steps:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "41950-7", display: "Number of steps in 24 hour Measured"),
                ucum: UCUMUnit(unit: "{steps}")
            )

        case .restingHeartRate:
            // 40443-4 ("Heart rate --resting") is distinct from the
            // generic pulse code 8867-4 used by `.pulse`. Apple
            // surfaces this from the Watch low-activity average.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "40443-4", display: "Heart rate --resting"),
                ucum: UCUMUnit(unit: "/min")
            )

        case .hrv:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "80404-7",
                    display: "R-R interval.standard deviation (Heart rate variability)",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "ms")
            )

        case .vo2Max:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "96402-2",
                    display: "Oxygen consumption maximum during exercise",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "mL/min/kg")
            )

        case .walkingSpeed:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "41957-2",
                    display: "Gait speed [Velocity] Measured",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "m/s")
            )

        case .walkingAsymmetry:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "91557-1",
                    display: "Walking asymmetry percentage",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "%")
            )

        case .walkingStepLength:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "41955-6",
                    display: "Step length Measured",
                    physicianReviewPending: true
                ),
                ucum: UCUMUnit(unit: "m")
            )

        case .walkingDoubleSupport:
            // v0.7.0 — no published LOINC for "walking double support
            // percentage" yet (Apple's metric pre-dates a LOINC term);
            // we surface the HK code under the custom HealthLog CodeSystem
            // (v0.11 audit B5 — never a non-LOINC code in the loinc.org
            // namespace) so the FHIR round-trip stays addressable +
            // clinician-reviewable. Will upgrade once LOINC publishes a term.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
                    display: "Walking double support percentage",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "%")
            )

        case .walkingSteadiness:
            // W28d — no published LOINC for Apple's walking-steadiness
            // classifier; surface the HK code under the HealthKit CodeSystem
            // (same approach as `walkingDoubleSupport`) so the FHIR round-trip
            // stays addressable + clinician-reviewable.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierAppleWalkingSteadiness",
                    display: "Walking steadiness",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "%")
            )

        case .respiratoryRate:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "9279-1", display: "Respiratory rate"),
                ucum: UCUMUnit(unit: "/min")
            )

        case .audioExposureEnvironment:
            // v0.7.0 — no published LOINC for environmental audio exposure;
            // Apple's dBA metric pre-dates a matching LOINC term. Surface
            // the HK code under the custom HealthLog CodeSystem (v0.11 audit
            // B5) until LOINC publishes a term.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
                    display: "Environmental audio exposure",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "dB[A]")
            )

        case .audioExposureHeadphone:
            // v0.7.0 — same placeholder rationale as the environmental sibling.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierHeadphoneAudioExposure",
                    display: "Headphone audio exposure",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "dB[A]")
            )

        case .bmi:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "39156-5", display: "Body mass index (BMI) [Ratio]"),
                ucum: UCUMUnit(unit: "kg/m2")
            )

        // v0.8.3 W-D — render-backlog activity aggregates. LOINC publishes a
        // term for energy burned; the other three pre-date a matching LOINC,
        // so we surface the HK identifier as a clinician-reviewable placeholder
        // (same rationale as the audio-exposure pair above).
        case .activeEnergy:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "41981-2", display: "Calories burned"),
                ucum: UCUMUnit(unit: "kcal")
            )

        case .flightsClimbed:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierFlightsClimbed",
                    display: "Flights climbed",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{flights}")
            )

        case .distanceWalkingRunning:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierDistanceWalkingRunning",
                    display: "Walking + running distance",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "m")
            )

        case .timeInDaylight:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierTimeInDaylight",
                    display: "Time in daylight",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "min")
            )

        // v0.11 W21 — web-parity body-composition + cardio additions. The
        // Withings-proprietary metrics (vascular age, visceral-fat rating) and
        // the body-composition masses pre-date a published LOINC consensus, so
        // they surface under the custom HealthLog CodeSystem rather than emit a
        // non-LOINC code inside the loinc.org namespace (audit B5). All are
        // clinician-review-pending. Walking-HR uses the generic heart-rate
        // LOINC since it is a true heart-rate observation.
        case .fatFreeMass:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "FAT_FREE_MASS",
                    display: "Fat-free mass",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        // v0.11 reconcile (F3) — 9th W21 type: Withings FAT_MASS (kg).
        case .fatMass:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "FAT_MASS",
                    display: "Fat mass",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        case .leanBodyMass:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierLeanBodyMass",
                    display: "Lean body mass",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        case .muscleMass:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "MUSCLE_MASS",
                    display: "Muscle mass",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        case .skinTemperature:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "SKIN_TEMPERATURE",
                    display: "Skin temperature",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "Cel")
            )

        case .pulseWaveVelocity:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "PULSE_WAVE_VELOCITY",
                    display: "Pulse-wave velocity",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "m/s")
            )

        case .vascularAge:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "VASCULAR_AGE",
                    display: "Vascular age",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "a")
            )

        case .visceralFat:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "VISCERAL_FAT",
                    display: "Visceral fat rating",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{rating}")
            )

        case .walkingHeartRate:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(code: "8867-4", display: "Heart rate"),
                ucum: UCUMUnit(unit: "/min")
            )

        // v0.13.1 IC / v0.14.6 / v0.14.1 W-REGFIX — the additive HealthKit /
        // WHOOP / v1.17.1 source-fixed signals live in a dedicated helper to
        // keep this switch under the type-body-length budget (file_length
        // discipline). See `additiveSignalMapping(for:)`. The grouped case
        // delegates so the parent switch stays exhaustive at the boundary.
        case .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types. Pain + waist carry real LOINCs,
             // grip + waist-to-height carry custom HealthLog codes — all routed
             // through the additive-signal helper to keep this body short.
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types. None has a
             // LOINC we can stand behind: the screener SUMS are instrument
             // scores the SERVER owns, the wearable scores are vendor-scaled
             // (WHOOP 0–21 strain is not comparable to anyone else's), and the
             // categorical events have no quantity to code. The helper returns
             // `nil` for them, so the exporter omits them rather than inventing
             // a code — the same doctrine the app already holds for
             // `ansCharge` / `cardioLoad` / `sleepScore`.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent:
            additiveSignalMapping(for: kind)

        // Build 7 / item 7.3 — mood is a subjective self-report with no LOINC we
        // can stand behind; it is not a `Measurement` and is never exported as an
        // Observation. `nil` omits it, the same doctrine as the wearable scores.
        case .mood:
            nil
        }
    }

    // swiftlint:enable function_body_length

    /// Returns the FHIR R4 `Observation.category` for `kind`, bound to the
    /// HL7 Observation Category CodeSystem.
    ///
    /// - `vital-signs` for the clinical vitals (HR, BP, temp, SpO2,
    ///   respiratory rate, weight, BMI) plus cardiopulmonary fitness
    ///   (HRV, VO₂max) which are physiologically vital-sign-adjacent.
    /// - `laboratory` for blood-chemistry analytes (glucose).
    /// - `activity` for fitness / movement / environmental aggregates
    ///   (steps, sleep, gait, energy, distance, flights, audio exposure,
    ///   daylight) and body-composition measurements (body-fat, body-water,
    ///   bone-mass), which are body-measurement findings rather than
    ///   clinical vital signs.
    ///
    /// The exhaustive `switch` (mirroring `mapping(for:)`) forces every new
    /// `MetricKind` to land a category at the same time.
    public static func category(for kind: MetricKind) -> ObservationCategory { // swiftlint:disable:this cyclomatic_complexity
        switch kind {
        case .weight, .bloodPressure, .pulse, .bodyTemperature,
             .spo2, .restingHeartRate, .respiratoryRate, .bmi,
             .hrv, .vo2Max,
             // v0.11 W21 — cardio + thermal web-parity additions are
             // vital-sign-adjacent (walking-HR is a heart-rate observation;
             // skin temp a thermal vital; PWV / vascular age cardiovascular).
             .walkingHeartRate, .skinTemperature, .pulseWaveVelocity, .vascularAge,
             // v0.13.1 IC — cardio recovery is a heart-rate observation; wrist
             // temperature a thermal vital (same bucket as skin temperature).
             .cardioRecovery, .wristTemperature,
             // v0.14.6 — v1.12.8 WHOOP-native avg/max HR are heart-rate
             // observations → vital signs.
             .averageHeartRate, .maxHeartRate,
             // v0158 — waist circumference (LOINC 8280-0), grip strength + waist-
             // to-height ratio are all `vital-signs` per the server registry
             // (`expected-measurement-loinc.json`); mirror it so the doctor-report
             // FHIR bundle category matches the server's. (L8 fix — grip strength +
             // waist-to-height were previously mis-bucketed as `.activity`.)
             .waistCircumference, .gripStrength, .waistToHeight:
            .vitalSigns
        case .glucose:
            .laboratory
        // v0158 — pain NRS is a patient-reported instrument (LOINC 72514-3,
        // server FHIR category `survey`).
        case .painNRS:
            .survey
        case .bodyFat, .bodyWater, .boneMass, .sleep, .steps,
             .walkingSpeed, .walkingAsymmetry, .walkingStepLength,
             .walkingDoubleSupport, .walkingSteadiness,
             .audioExposureEnvironment, .audioExposureHeadphone,
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — body-composition masses are body-measurement findings,
             // not clinical vital signs (same bucket as body-fat / body-water).
             .fatFreeMass, .leanBodyMass, .muscleMass, .visceralFat, .fatMass,
             // v0.13.1 IC — falls / 6MWT / stair speeds are mobility-fitness
             // findings; breathing-disturbances a sleep finding → activity.
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances,
             // v0.14.6 — sleep-disturbance count is a sleep finding → activity.
             .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23) are derived
             // findings (training-load / autonomic / sleep scores + a thermal
             // baseline offset), not clinical vital signs → activity. (Category
             // is unused at runtime since they aren't exported, but the switch
             // stays exhaustive + auditable.)
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // Build 3 / item 3.3 — the 21 decoder catch-up types. Wearable
             // scores, sleep sub-scores, energy and the categorical events are
             // derived findings → activity. (Unused at runtime since none is
             // exported — `mapping(for:)` returns `nil` — but the switch stays
             // exhaustive + auditable.)
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent:
            .activity
        // Build 3 / item 3.3 — the four screener SUM scores are
        // patient-reported instruments, the same `survey` bucket `painNRS`
        // already sits in. Build 7 / item 7.3 — mood is a patient-reported
        // self-rating → the same `survey` category (unused at runtime since
        // `mapping(for:)` returns `nil` for mood, but the switch stays exhaustive).
        case .phq9Score, .gad7Score, .who5Score, .sciScore, .mood:
            .survey
        }
    }

    /// Returns the glucose-specific LOINC mapping for the given
    /// `GlucoseContext`. Used by the H.2 mapper when a `Measurement.kind
    /// == .glucose` carries a non-nil `glucoseContext`.
    ///
    /// Mapping:
    /// - `.fasting`    → LOINC `1558-6` (Fasting glucose, serum/plasma).
    /// - `.beforeMeal` → LOINC `1558-6` (pre-prandial treated as fasting
    ///                  for FHIR purposes — clinician-reviewable).
    /// - `.afterMeal`  → LOINC `1521-4` (Postprandial glucose, 2h).
    /// - `.bedtime`    → LOINC `2339-0` (generic random — no
    ///                  LOINC-specific code for bedtime exists).
    public static func glucoseMapping(context: GlucoseContext) -> MetricFHIRMapping {
        let loinc: LOINCCode = switch context {
        case .fasting, .beforeMeal:
            glucoseFastingLOINC
        case .afterMeal:
            glucosePostprandialLOINC
        case .bedtime:
            glucoseRandomLOINC
        }
        return MetricFHIRMapping(
            kind: .glucose,
            loinc: loinc,
            ucum: UCUMUnit(unit: "mg/dL"),
            glucoseContext: context
        )
    }

    /// All 18 base mappings (one per `MetricKind`). Glucose-context
    /// variants are **not** included — query `glucoseMapping(context:)`
    /// directly for those.
    public static let allMappings: [MetricFHIRMapping] = MetricKind.allCases.compactMap { kind in
        mapping(for: kind)
    }
}
