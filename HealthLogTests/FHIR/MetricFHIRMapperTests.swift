//
//  MetricFHIRMapperTests.swift
//  HealthLogTests / HealthLogCoreTests
//
//  Created 2026-05-22 — v0.6.0 H.1 coverage for the LOINC/UCUM table.
//
//  Pure value-type test — no `import HealthKit`, no `import SpeziFHIR`.
//  Runs in both the iOS XCTest host **and** the macOS SwiftPM test
//  target (`HealthLogCoreTests`).
//

import Foundation
@testable import HealthLog
import Testing

@Suite("MetricFHIRMapper — v0.6.0 H.1 LOINC/UCUM table")
struct MetricFHIRMapperTests {
    // MARK: - Completeness

    /// v0.14.6 — the three WHOOP-native aggregates (`averageHeartRate`,
    /// `maxHeartRate`, `sleepDisturbanceCount`) have **no clean FHIR mapping**
    /// by design: avg/max HR over a day/session would mis-read as a spot heart
    /// rate, and sleep-disturbance count has no standard LOINC. `mapping(for:)`
    /// returns nil for them, so they are excluded from the FHIR completeness
    /// contracts below (the `compactMap` in `allMappings` drops them too).
    ///
    /// **Build 3 / item 3.3** extends the set with the 21 decoder catch-up
    /// kinds. Same doctrine, same reason: an instrument SUM score is owned by
    /// the server's questionnaire definition, a vendor-scaled wearable score
    /// (WHOOP's 0–21 strain) is not comparable to anyone else's, and a
    /// categorical `1…1` event has no quantity to code. Inventing a LOINC for
    /// any of them would put a number in a clinical export that a receiving
    /// system would misread — so the exporter omits them.
    private static let unmappedWHOOPKinds: Set<MetricKind> = [
        .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
        .phq9Score, .gad7Score, .who5Score, .sciScore,
        .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
        .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
        .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
        .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
        .walkingSteadinessEvent, .breathingDisturbanceEvent,
        // Build 7 / item 7.3 — mood is a subjective self-report with no LOINC we
        // can stand behind; it is never FHIR-exported. Adding it here keeps the
        // FHIR-mapped count invariant (allCases +1, unmapped +1 → 51 unchanged).
        .mood
    ]

    @Test("Every MetricKind has a non-nil mapping")
    func everyMetricKindMaps() {
        for kind in MetricKind.allCases where !Self.unmappedWHOOPKinds.contains(kind) {
            #expect(MetricFHIRMapper.mapping(for: kind) != nil, "Missing mapping for \(kind.rawValue)")
        }
    }

    @Test("Read-only ingest kinds have no FHIR mapping (display only)")
    func whoopKindsHaveNoMapping() {
        for kind in Self.unmappedWHOOPKinds {
            #expect(MetricFHIRMapper.mapping(for: kind) == nil, "\(kind.rawValue) should not be FHIR-exported")
        }
    }

    @Test("allMappings exposes one entry per FHIR-mapped MetricKind")
    func allMappingsCount() {
        let fhirMappedCount = MetricKind.allCases.count - Self.unmappedWHOOPKinds.count
        #expect(MetricFHIRMapper.allMappings.count == fhirMappedCount)
        // v0.11 W21 — +8 web-parity body-composition + cardio kinds (was 26).
        // v0.11 reconcile (F3) — +1 (fatMass) → 35.
        // v0.11 W28d — +1 (walkingSteadiness) → 36.
        // v0.13.1 IC — +7 v1.10.0 additive HealthKit signals → 43.
        // v0.14.6 — the three WHOOP-native kinds map to nil → still 43.
        // v0.14.1 W-REGFIX — +4 v1.17.1 source-fixed render-only signals
        // (ansCharge / cardioLoad / sleepScore / bodyTemperatureDeviation) map
        // to a custom HealthLog CodeSystem (FHIR export stays complete) → 47.
        // v0158 — +4 v1.25 clinical types, all FHIR-mapped (pain LOINC 72514-3,
        // waist LOINC 8280-0, grip + waist-to-height custom HealthLog codes) → 51.
        // Build 3 / item 3.3 — +21 decoder catch-up kinds, ALL of them
        // deliberately unmapped (see `unmappedWHOOPKinds`) → still 51.
        #expect(MetricFHIRMapper.allMappings.count == 51)
    }

    @Test("allMappings has one entry per FHIR-mapped kind, no duplicates")
    func allMappingsAreUnique() {
        let kinds = MetricFHIRMapper.allMappings.map(\.kind)
        let unique = Set(kinds)
        #expect(unique.count == kinds.count)
        #expect(unique == Set(MetricKind.allCases).subtracting(Self.unmappedWHOOPKinds))
    }

    // MARK: - Blood-pressure panel

    @Test("Blood-pressure panel LOINC = 85354-9")
    func bloodPressurePanelLOINC() {
        #expect(MetricFHIRMapper.bloodPressurePanelLOINC.code == "85354-9")
    }

    @Test("BP systolic component LOINC = 8480-6")
    func bpSystolicLOINC() {
        #expect(MetricFHIRMapper.bloodPressureSystolicLOINC.code == "8480-6")
    }

    @Test("BP diastolic component LOINC = 8462-4")
    func bpDiastolicLOINC() {
        #expect(MetricFHIRMapper.bloodPressureDiastolicLOINC.code == "8462-4")
    }

    @Test("MetricKind.bloodPressure mapping points to the panel LOINC, not a component")
    func bloodPressureMappingIsPanel() {
        let mapping = MetricFHIRMapper.mapping(for: .bloodPressure)
        #expect(mapping?.loinc.code == "85354-9")
        #expect(mapping?.ucum.unit == "mm[Hg]")
    }

    // MARK: - Glucose discriminators

    @Test("Glucose context-specific mapping: fasting → 1558-6")
    func glucoseFasting() {
        let mapping = MetricFHIRMapper.glucoseMapping(context: .fasting)
        #expect(mapping.kind == .glucose)
        #expect(mapping.loinc.code == "1558-6")
        #expect(mapping.glucoseContext == .fasting)
    }

    @Test("Glucose context-specific mapping: afterMeal → 1521-4 (postprandial)")
    func glucoseAfterMeal() {
        let mapping = MetricFHIRMapper.glucoseMapping(context: .afterMeal)
        #expect(mapping.loinc.code == "1521-4")
        #expect(mapping.glucoseContext == .afterMeal)
    }

    @Test("Glucose context-specific mapping: beforeMeal also uses 1558-6 (pre-prandial)")
    func glucoseBeforeMeal() {
        let mapping = MetricFHIRMapper.glucoseMapping(context: .beforeMeal)
        #expect(mapping.loinc.code == "1558-6")
    }

    @Test("Glucose context-specific mapping: bedtime falls back to 2339-0 (random)")
    func glucoseBedtime() {
        let mapping = MetricFHIRMapper.glucoseMapping(context: .bedtime)
        #expect(mapping.loinc.code == "2339-0")
    }

    @Test("Default glucose mapping uses random LOINC 2339-0")
    func glucoseDefaultIsRandom() {
        let mapping = MetricFHIRMapper.mapping(for: .glucose)
        #expect(mapping?.loinc.code == "2339-0")
        #expect(mapping?.glucoseContext == nil)
    }

    @Test("All three glucose discriminator codes are physician-review-pending")
    func glucoseCodesNeedReview() {
        for context in GlucoseContext.allCases {
            let mapping = MetricFHIRMapper.glucoseMapping(context: context)
            #expect(mapping.loinc.physicianReviewPending == true)
        }
    }

    // MARK: - Resting HR vs pulse

    @Test("restingHeartRate LOINC differs from pulse LOINC")
    func restingHeartRateDistinctFromPulse() {
        let resting = MetricFHIRMapper.mapping(for: .restingHeartRate)
        let pulse = MetricFHIRMapper.mapping(for: .pulse)
        #expect(resting?.loinc.code == "40443-4")
        #expect(pulse?.loinc.code == "8867-4")
        #expect(resting?.loinc.code != pulse?.loinc.code)
    }

    // MARK: - Selected high-value LOINC pin checks

    @Test("Body temperature uses LOINC 8310-5")
    func bodyTempCode() {
        #expect(MetricFHIRMapper.mapping(for: .bodyTemperature)?.loinc.code == "8310-5")
    }

    @Test("spO2 uses LOINC 59408-5 (pulse-ox preferred over generic 2708-6)")
    func spo2Code() {
        #expect(MetricFHIRMapper.mapping(for: .spo2)?.loinc.code == "59408-5")
    }

    @Test("Weight uses LOINC 29463-7 (kg)")
    func weightCode() {
        let mapping = MetricFHIRMapper.mapping(for: .weight)
        #expect(mapping?.loinc.code == "29463-7")
        #expect(mapping?.ucum.unit == "kg")
    }

    @Test("BMI uses LOINC 39156-5 (kg/m2 UCUM)")
    func bmiCode() {
        let mapping = MetricFHIRMapper.mapping(for: .bmi)
        #expect(mapping?.loinc.code == "39156-5")
        #expect(mapping?.ucum.unit == "kg/m2")
    }

    // MARK: - physicianReviewPending flag — walking-* + body-composition

    @Test("Walking-* + body-composition + HRV/VO2max are physician-review-pending")
    func reviewPendingKinds() {
        let reviewKinds: [MetricKind] = [
            .bodyFat, .bodyWater, .boneMass,
            .hrv, .vo2Max,
            .walkingSpeed, .walkingAsymmetry, .walkingStepLength
        ]
        for kind in reviewKinds {
            let mapping = MetricFHIRMapper.mapping(for: kind)
            #expect(
                mapping?.loinc.physicianReviewPending == true,
                "Expected \(kind.rawValue) LOINC to be flagged for clinician review"
            )
        }
    }

    @Test("Core vital-signs (weight, BP, pulse, temp, spO2, BMI, RHR) are NOT review-pending")
    func nonReviewPendingKinds() {
        let stableKinds: [MetricKind] = [
            .weight, .bloodPressure, .pulse, .bodyTemperature,
            .spo2, .bmi, .restingHeartRate, .sleep, .steps
        ]
        for kind in stableKinds {
            let mapping = MetricFHIRMapper.mapping(for: kind)
            #expect(
                mapping?.loinc.physicianReviewPending == false,
                "Expected \(kind.rawValue) LOINC to be stable (not review-pending)"
            )
        }
    }

    // MARK: - UCUM validity

    /// Basic UCUM grammar check. UCUM strings are case-sensitive ASCII;
    /// allowed characters in our table: letters, digits, `/`, `[`, `]`,
    /// `{`, `}`, `%`, `.`. This is a coarse sanity guard — full UCUM
    /// validation would need a parser; we settle for "no whitespace,
    /// no control chars, non-empty, ASCII".
    @Test("Every UCUM unit string passes basic syntactic validation")
    func ucumStringsAreValid() {
        let allowedCharset = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/[]{}%.")
        for mapping in MetricFHIRMapper.allMappings {
            let unit = mapping.ucum.unit
            #expect(!unit.isEmpty, "Empty UCUM unit for \(mapping.kind.rawValue)")
            #expect(
                unit.unicodeScalars.allSatisfy { allowedCharset.contains($0) },
                "Invalid UCUM char in \(unit) for \(mapping.kind.rawValue)"
            )
        }
    }

    @Test("BP panel and glucose mapping UCUMs are also valid")
    func ucumGlucoseAndBPValid() {
        let allowedCharset = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/[]{}%.")
        for context in GlucoseContext.allCases {
            let mapping = MetricFHIRMapper.glucoseMapping(context: context)
            #expect(mapping.ucum.unit.unicodeScalars.allSatisfy { allowedCharset.contains($0) })
        }
    }

    // MARK: - Observation category (v0.11 audit B1)

    @Test("Every MetricKind resolves to a category")
    func everyKindHasCategory() {
        for kind in MetricKind.allCases {
            _ = MetricFHIRMapper.category(for: kind)
        }
    }

    @Test("Glucose categorises as laboratory; vitals as vital-signs; steps as activity")
    func categoryClassification() {
        #expect(MetricFHIRMapper.category(for: .glucose) == .laboratory)
        #expect(MetricFHIRMapper.category(for: .bloodPressure) == .vitalSigns)
        #expect(MetricFHIRMapper.category(for: .pulse) == .vitalSigns)
        #expect(MetricFHIRMapper.category(for: .respiratoryRate) == .vitalSigns)
        #expect(MetricFHIRMapper.category(for: .steps) == .activity)
        #expect(MetricFHIRMapper.category(for: .activeEnergy) == .activity)
        #expect(MetricFHIRMapper.category(for: .bodyFat) == .activity)
    }

    @Test("observation-category system URI is the HL7 terminology CodeSystem")
    func categorySystemURI() {
        #expect(ObservationCategory.systemURI == "http://terminology.hl7.org/CodeSystem/observation-category")
    }

    // MARK: - Custom CodeSystem for HK-native codes (v0.11 audit B5)

    @Test("No mapping emits a non-LOINC code inside the loinc.org namespace")
    func noFakeLOINCCodes() {
        // A true-LOINC entry must look like a LOINC code (digits-dash-digit),
        // never a HealthKit identifier.
        for mapping in MetricFHIRMapper.allMappings where mapping.loinc.system == .loinc {
            #expect(
                !mapping.loinc.code.hasPrefix("HKQuantityTypeIdentifier"),
                "HK identifier in loinc.org namespace for \(mapping.kind.rawValue)"
            )
        }
    }

    @Test("HealthKit-native placeholder kinds carry the custom HealthLog CodeSystem")
    func hkNativeKindsUseCustomSystem() {
        let hkKinds: [MetricKind] = [
            .walkingDoubleSupport, .audioExposureEnvironment, .audioExposureHeadphone,
            .flightsClimbed, .distanceWalkingRunning, .timeInDaylight
        ]
        for kind in hkKinds {
            let mapping = MetricFHIRMapper.mapping(for: kind)
            #expect(mapping?.loinc.system == .healthKit, "\(kind.rawValue) should be .healthKit")
            #expect(
                mapping?.loinc.system.uri == "https://healthlog.dev/fhir/CodeSystem/healthkit"
            )
        }
    }
}
