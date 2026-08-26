//
//  MeasurementToFHIRObservation.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  Created 2026-05-22 — v0.6.0 H.2 Measurement → FHIR R4 Observation
//  mapper. Consumes the platform-free `MetricFHIRMapper` LOINC/UCUM
//  table (H.1) and emits a `ModelsR4.Observation` ready to land inside
//  an H.3 transaction Bundle.
//
//  Why iOS-only (and **not** `HealthLogCore`):
//  `ModelsR4.Observation` lives in `apple/FHIRModels` which we pull in
//  transitively through SpeziFHIR. SpeziFHIR is iOS-targeted and pulls
//  HealthKit, so this mapper cannot compile inside the plattformfrei
//  `HealthLogCore` SPM target. Only the LOINC/UCUM value-types travel
//  upstream into the core library.
//
//  Reference shape (FHIR R4 vital-signs profile):
//    - `code` : `CodeableConcept` with single `Coding` (loinc).
//    - `value`: `.quantity(Quantity(value: …, unit: …, system: ucum,
//                                    code: ucum))`.
//    - `subject`: `Reference(reference: "Patient/<id>")`.
//    - `effective`: `.dateTime(...)` from `measurement.recordedAt`.
//    - `status`: `.final`.
//    - `meta.profile`: vital-signs URL for the kinds that fall under
//      the FHIR R4 vital-signs IG (weight, BP-panel, pulse, body-temp,
//      spO2, resting HR, BMI, body-height/length etc.).
//
//  Blood-pressure: per FHIR R4 BP guidance and our H.1 mapping table,
//  BP emits ONE Observation with `code = 85354-9` (the panel LOINC)
//  and TWO `Observation.component` entries — systolic (8480-6) +
//  diastolic (8462-4) — **not** three separate Observations.
//

import Foundation
import ModelsR4

/// Maps a domain `Measurement` to a FHIR R4 `ModelsR4.Observation`.
///
/// Returns `nil` only when `MetricFHIRMapper.mapping(for:)` returns
/// `nil` (currently no `MetricKind` is unmapped — the H.1 table covers
/// all 18 cases — so a `nil` return today indicates a future-MetricKind
/// row that landed without an accompanying LOINC mapping).
enum MeasurementToFHIRObservation {
    /// FHIR R4 vital-signs profile URL. Applied to `Observation.meta.profile`
    /// for the kinds that fall under the official vital-signs IG.
    /// Source: https://hl7.org/fhir/R4/observation-vitalsigns.html
    private static let vitalSignsProfileURL = "http://hl7.org/fhir/StructureDefinition/vitalsigns"

    /// UCUM code-system URI (FHIR-canonical, required for `Quantity.system`).
    private static let ucumSystemURI = "http://unitsofmeasure.org"

    /// Maps the given measurement to a FHIR R4 `Observation`.
    ///
    /// - Parameters:
    ///   - measurement: the domain measurement to encode.
    ///   - patientID: the FHIR `Patient.id` to reference from
    ///     `Observation.subject` (`"Patient/<patientID>"`).
    /// - Returns: a populated `Observation`, or `nil` if the kind is
    ///   unmapped (today: never `nil`).
    static func map(_ measurement: Measurement, patientID: String) -> Observation? {
        // Glucose: prefer context-specific LOINC if a `glucoseContext` is
        // present on the measurement — otherwise the H.1 default
        // (`mapping(for: .glucose)`) returns the generic random code.
        let mapping: MetricFHIRMapping? = if measurement.kind == .glucose,
                                             let context = measurement.glucoseContext
        {
            MetricFHIRMapper.glucoseMapping(context: context)
        } else {
            MetricFHIRMapper.mapping(for: measurement.kind)
        }

        guard let mapping else { return nil }

        let code = makeCodeableConcept(loinc: mapping.loinc)
        let status: FHIRPrimitive<ObservationStatus> = ObservationStatus.final.asPrimitive()
        let observation = Observation(code: code, status: status)

        // Observation.category — required by the vital-signs profile (1..*)
        // and a preferred binding for every Observation. Driven from the
        // metric mapping (FHIR-R4 conformance — audit B1).
        observation.category = [makeCategoryConcept(MetricFHIRMapper.category(for: measurement.kind))]

        observation.subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        observation.effective = .dateTime(makeDateTime(from: measurement.recordedAt))

        switch measurement.value {
        case let .scalar(scalar):
            // AUD-4 M1 — a non-finite / out-of-range scalar must not reach
            // `FHIRDecimal(floatLiteral:)` (garbage Quantity on +inf, thrown
            // encode error on NaN). Drop the whole measurement from the bundle.
            guard let quantity = makeQuantity(value: scalar, ucum: mapping.ucum) else { return nil }
            observation.value = .quantity(quantity)

        case let .bloodPressure(systolic, diastolic):
            // BP panel: no top-level `value`, instead two `component`s. Both
            // operands must be finite — a half-formed BP panel (one garbage
            // operand) is worse than dropping the row (AUD-4 M1).
            guard let sysComponent = makeBPComponent(
                loinc: MetricFHIRMapper.bloodPressureSystolicLOINC, value: systolic
            ),
                let diaComponent = makeBPComponent(
                    loinc: MetricFHIRMapper.bloodPressureDiastolicLOINC, value: diastolic
                ) else { return nil }
            observation.component = [sysComponent, diaComponent]
        }

        // Identifier: surface the domain id so a round-trip can correlate
        // back to the source measurement.
        let identifier = Identifier()
        identifier.value = FHIRString(measurement.id).asPrimitive()
        observation.identifier = [identifier]

        // Meta.profile for vital-signs kinds. Body-composition + walking-*
        // kinds aren't part of the official vital-signs IG, so we skip
        // the profile assertion for them.
        if isVitalSign(measurement.kind) {
            let meta = Meta()
            meta.profile = [makeCanonical(vitalSignsProfileURL).asPrimitive()]
            observation.meta = meta
        }

        return observation
    }

    // MARK: - Helpers

    private static func makeCodeableConcept(loinc: LOINCCode) -> CodeableConcept {
        let coding = Coding()
        // Honour the code's own system — true LOINC codes stay in
        // `http://loinc.org`; HealthKit-native placeholders ride the custom
        // HealthLog CodeSystem (never a non-LOINC code in the LOINC
        // namespace — audit B5).
        coding.system = makeFHIRURI(loinc.system.uri).asPrimitive()
        coding.code = FHIRString(loinc.code).asPrimitive()
        coding.display = FHIRString(loinc.display).asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        concept.text = FHIRString(loinc.display).asPrimitive()
        return concept
    }

    /// Build the `Observation.category` CodeableConcept for a category,
    /// bound to the HL7 Observation Category CodeSystem.
    private static func makeCategoryConcept(_ category: ObservationCategory) -> CodeableConcept {
        let coding = Coding()
        coding.system = makeFHIRURI(ObservationCategory.systemURI).asPrimitive()
        coding.code = FHIRString(category.rawValue).asPrimitive()
        coding.display = FHIRString(category.display).asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    /// Returns `nil` for a non-finite / out-of-range `value` (AUD-4 M1) so the
    /// caller can DROP the measurement rather than emit a corrupt Quantity.
    private static func makeQuantity(value: Double, ucum: UCUMUnit) -> Quantity? {
        guard let safeValue = FHIRDecimal(safeServer: value) else { return nil }
        let quantity = Quantity()
        quantity.value = safeValue.asPrimitive()
        quantity.unit = FHIRString(ucum.unit).asPrimitive()
        quantity.system = makeFHIRURI(ucumSystemURI).asPrimitive()
        quantity.code = FHIRString(ucum.unit).asPrimitive()
        return quantity
    }

    /// Build a `FHIRURI` from a string. `FHIRURI` only exposes a
    /// `URL`-taking initialiser and an `ExpressibleByStringLiteral`
    /// (which won't accept a runtime String). Fall through `URL(string:)`
    /// — the constants we feed it are FHIR-canonical URIs and never fail
    /// to parse; force-unwrap is the FHIRModels-recommended pattern for
    /// static URI literals.
    private static func makeFHIRURI(_ string: String) -> FHIRURI {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid FHIR URI: \(string)")
        }
        return FHIRURI(url)
    }

    private static func makeCanonical(_ string: String) -> Canonical {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid Canonical URI: \(string)")
        }
        return Canonical(url)
    }

    /// Returns `nil` for a non-finite / out-of-range `value` (AUD-4 M1).
    private static func makeBPComponent(loinc: LOINCCode, value: Double) -> ObservationComponent? {
        guard let quantity = makeQuantity(value: value, ucum: UCUMUnit(unit: "mm[Hg]")) else { return nil }
        let component = ObservationComponent(code: makeCodeableConcept(loinc: loinc))
        component.value = .quantity(quantity)
        return component
    }

    private static func makeDateTime(from date: Date) -> FHIRPrimitive<DateTime> {
        // A2-L4 — non-throwing construction from calendar components (no `try!`
        // on a runtime date). See `FHIRDateConverter`.
        FHIRDateConverter.dateTime(from: date).asPrimitive()
    }

    /// Kinds covered by the FHIR R4 vital-signs profile IG. Body-
    /// composition + walking-* + HRV/VO2max land **without** profile
    /// assertion (no official vital-signs profile exists for them).
    private static func isVitalSign(_ kind: MetricKind) -> Bool {
        switch kind {
        case .weight, .bloodPressure, .pulse, .bodyTemperature,
             .spo2, .restingHeartRate, .respiratoryRate, .bmi:
            true
        case .glucose, .bodyFat, .bodyWater, .boneMass, .sleep, .steps,
             .hrv, .vo2Max, .walkingSpeed, .walkingAsymmetry, .walkingStepLength,
             .walkingDoubleSupport, .walkingSteadiness,
             .audioExposureEnvironment, .audioExposureHeadphone,
             // v0.8.3 W-D — no FHIR vital-signs profile for these activity aggregates.
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — no official FHIR R4 vital-signs profile exists for the
             // Withings body-composition + arterial metrics or walking-HR.
             .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
             .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
             .fatMass,
             // v0.13.1 IC — no official FHIR R4 vital-signs profile for the
             // v1.10.0 Apple-Watch-derived mobility/sleep/recovery signals.
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             // v0.14.6 — no FHIR vital-signs profile for the WHOOP-native
             // aggregates (they're not exported as Observations anyway).
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23): no FHIR
             // profile (derived scores / a signed temperature offset), not
             // exported as Observations.
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types: pain (survey), grip + waist
             // measurements + waist-to-height ratio are NOT in the FHIR R4
             // base vital-signs profile.
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types: instrument
             // sums, vendor-scaled scores and categorical events are not in the
             // FHIR R4 base vital-signs profile (and carry no LOINC, so they
             // aren't exported as Observations at all).
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood is a survey self-report, not a FHIR
             // vital sign (and is never exported as an Observation anyway).
             .mood:
            false
        }
    }
}
