//
//  DoctorReportToFHIRBundle+Codings.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  #115 R3 — the R4 vital-signs "magic" codes, byte-aligned with the server's
//  v1.39.3 exporter (`src/lib/fhir/resources/common.ts`,
//  `VITAL_SIGNS_MAGIC_CODE`). Kept out of `DoctorReportToFHIRBundle.swift`,
//  whose length is frozen in the SwiftLint baseline.
//

import Foundation
import ModelsR4

extension MetricFHIRMapper {
    /// The R4 vital-signs profile requires a fixed LOINC code on
    /// `Observation.code` and allows a more specific one beside it
    /// (https://hl7.org/fhir/R4/observation-vitalsigns.html). A resting heart
    /// rate is a heart rate (8867-4) and a pulse-oximetry SpO2 is an oxygen
    /// saturation (2708-6); without that second coding the HL7 validator
    /// rejects both Observations. Returns the companion for the specific code,
    /// or `nil` when the code needs none.
    static func vitalSignsCompanionCode(for loinc: LOINCCode) -> LOINCCode? {
        guard loinc.system == .loinc else { return nil }
        switch loinc.code {
        case "40443-4": return LOINCCode(code: "8867-4", display: "Heart rate")
        case "59408-5": return LOINCCode(code: "2708-6", display: "Oxygen saturation in Arterial blood")
        default: return nil
        }
    }
}

extension DoctorReportToFHIRBundle {
    /// The companion `Coding`s that ride after the specific code on a
    /// `CodeableConcept` (see ``MetricFHIRMapper/vitalSignsCompanionCode(for:)``).
    /// Empty for every code that needs none. Shared by the bundle assembler and
    /// `MeasurementToFHIRObservation`, so both emit the identical concept.
    static func companionCodings(for loinc: LOINCCode) -> [Coding] {
        guard let companion = MetricFHIRMapper.vitalSignsCompanionCode(for: loinc) else { return [] }
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(companion.system.uri).asPrimitive()
        coding.code = FHIRString(companion.code).asPrimitive()
        coding.display = FHIRString(companion.display).asPrimitive()
        return [coding]
    }
}
