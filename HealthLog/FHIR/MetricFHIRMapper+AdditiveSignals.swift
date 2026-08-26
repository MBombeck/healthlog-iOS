//
//  MetricFHIRMapper+AdditiveSignals.swift
//  HealthLog (HealthLogCore — plattformfrei)
//
//  Split out of `MetricFHIRMapper.swift` (W-REGFIX) to keep the parent
//  enum body under the SwiftLint `type_body_length` budget. This is a
//  pure move — the cases below were previously inline in `mapping(for:)`.
//
//  Holds the FHIR LOINC/UCUM mappings for the additive read-only signal
//  families:
//   - v0.13.1 IC — v1.10.0 additive HealthKit signals (falls / 6MWT /
//     stair speeds / breathing-disturbances / cardio-recovery / wrist temp).
//   - v0.14.6 — v1.12.8 WHOOP-native aggregates (avg/max HR + sleep
//     disturbance count) — deliberately unmapped (`nil`).
//   - v0.14.1 W-REGFIX — v1.17.1 source-fixed render-only signals
//     (ANS-charge / cardio-load / sleep-score / body-temp deviation) carry
//     a custom HealthLog CodeSystem code so the FHIR export stays complete.
//

import Foundation

extension MetricFHIRMapper {
    // 09-08 — same family, same reason as `mapping(for:)`: the additive-signal
    // rows are an exhaustive table whose `switch` is the audit surface. It is
    // long because there are that many signals, not because it does too much.
    // function_body_length exception (owner: 09-08): exhaustive additive-signal FHIR table, one row per kind.
    // swiftlint:disable function_body_length
    /// FHIR mapping for the additive read-only signal families. Returns `nil`
    /// only for the WHOOP-native aggregates that have no clean FHIR mapping.
    ///
    /// Precondition: `kind` is one of the additive-signal cases routed here
    /// from `mapping(for:)`. Any other kind returns `nil` (defensive — the
    /// parent switch never dispatches a non-additive kind here).
    static func additiveSignalMapping(for kind: MetricKind) -> MetricFHIRMapping? { // swiftlint:disable:this cyclomatic_complexity
        switch kind {
        // v0.13.1 IC — v1.10.0 additive HealthKit signals. No published LOINC
        // for these Apple-Watch-derived metrics, so they carry their HealthKit
        // identifier as the code (system `.healthKit`, physician-review-pending)
        // exactly like the W21 Withings additions.
        case .falls:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierNumberOfTimesFallen",
                    display: "Number of falls",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{count}")
            )

        case .sixMinuteWalk:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierSixMinuteWalkTestDistance",
                    display: "Six-minute walk test distance",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "m")
            )

        case .stairAscentSpeed:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierStairAscentSpeed",
                    display: "Stair ascent speed",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "m/s")
            )

        case .stairDescentSpeed:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierStairDescentSpeed",
                    display: "Stair descent speed",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "m/s")
            )

        case .breathingDisturbances:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "BREATHING_DISTURBANCES",
                    display: "Sleep breathing disturbances",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{count}")
            )

        case .cardioRecovery:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute",
                    display: "Cardio recovery (1-minute heart-rate recovery)",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "/min")
            )

        case .wristTemperature:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
                    display: "Wrist temperature",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "Cel")
            )

        // v0.14.6 — v1.12.8 WHOOP-native aggregates have no clean FHIR mapping
        // (avg/max HR over a day/session would mis-read as a spot heart rate;
        // sleep-disturbance count has no standard LOINC), so they are not
        // exported as FHIR Observations.
        case .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount:
            nil

        // v0.14.1 W-REGFIX — v1.17.1 source-fixed render-only signals (#23) have
        // no published LOINC (vendor-derived autonomic / training-load / sleep
        // scores + a signed thermal baseline offset), so they carry a custom
        // HealthLog CodeSystem code, `physicianReviewPending: true` — exactly
        // like the W21 / IC additive `.healthKit` rows (vascularAge,
        // breathingDisturbances, cardioRecovery). The FHIR export stays
        // complete; downstream consumers read the custom system URI + display.
        case .ansCharge:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "ANS_CHARGE",
                    display: "Autonomic-nervous-system charge",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{score}")
            )

        case .cardioLoad:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "CARDIO_LOAD",
                    display: "Cardio load (cumulative training-load score)",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{score}")
            )

        case .sleepScore:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "SLEEP_SCORE",
                    display: "Sleep score (composite nightly sleep-quality score)",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "{score}")
            )

        case .bodyTemperatureDeviation:
            // SIGNED nightly offset from the user's personal baseline (°C), NOT
            // an absolute temperature — the custom code + display make that
            // explicit so a consumer never mis-reads it as an absolute reading.
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "BODY_TEMPERATURE_DEVIATION",
                    display: "Body-temperature deviation from baseline (signed)",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "Cel")
            )

        // v0158 — v1.25 clinical measurement types. Pain + waist carry published
        // LOINCs (real `.loinc` system); grip + waist-to-height have no LOINC, so
        // they carry a custom HealthLog code (`.healthKit` system,
        // `physicianReviewPending: true`) exactly like the W21 / IC additive rows.
        case .painNRS:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "72514-3",
                    display: "Pain severity - 0-10 verbal numeric rating [Score] - Reported"
                ),
                ucum: UCUMUnit(unit: "{score}")
            )

        case .gripStrength:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "GRIP_STRENGTH",
                    display: "Grip strength",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "kg")
            )

        case .waistCircumference:
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "8280-0",
                    display: "Waist circumference at umbilicus by Tape measure"
                ),
                ucum: UCUMUnit(unit: "cm")
            )

        case .waistToHeight:
            // Render-only on iOS, but it carries a clean FHIR mapping for export
            // completeness (dimensionless ratio → UCUM "1").
            MetricFHIRMapping(
                kind: kind,
                loinc: LOINCCode(
                    code: "WAIST_TO_HEIGHT",
                    display: "Waist-to-height ratio",
                    physicianReviewPending: true,
                    system: .healthKit
                ),
                ucum: UCUMUnit(unit: "1")
            )

        default:
            nil
        }
    }

    // swiftlint:enable function_body_length
}
