//
//  LOINCCode.swift
//  HealthLog (HealthLogCore — plattformfrei)
//
//  Created 2026-05-22 — v0.6.0 H.1 LOINC/UCUM value types.
//
//  Pure value types. NO `import HealthKit`, NO `import SpeziFHIR`. These
//  must compile inside the plattformfrei `HealthLogCore` SPM target so
//  the mapping table can be unit-tested on macOS without HealthKit and
//  reused by both the iOS-only `MeasurementFHIRMapper` (H.2) and any
//  future platform-free encoder.
//
//  Sources:
//  - LOINC: https://loinc.org (license: LOINC Terms of Use; codes are
//    free to use, attribution required at distribution time).
//  - UCUM: https://unitsofmeasure.org (Unified Code for Units of
//    Measure; required by FHIR R4 `Quantity.system`
//    = http://unitsofmeasure.org).
//

import Foundation

// MARK: - LOINC

/// A LOINC (Logical Observation Identifiers Names and Codes) reference.
///
/// LOINC is the FHIR-recommended code system for observations
/// (`Observation.code.coding[].system = "http://loinc.org"`). Each
/// entry pins a single LOINC `code` (e.g. `"8480-6"`) plus the
/// official English `display` string from loinc.org.
///
/// `physicianReviewPending` flags rows whose mapping needs clinical
/// sign-off before being shipped to an EMR. The v0.6.x research pass
/// (`.planning/v056-marathon/v060-research.md`) marks the following
/// rows as high-uncertainty:
///
/// - Body-composition: `bodyWater` (73704-9), `boneMass` (73708-0),
///   `bodyFat` (41982-0).
/// - Performance: `hrv` (80404-7), `vo2Max` (96402-2).
/// - Walking-* (Apple-Health-derived metrics without LOINC consensus):
///   `walkingSpeed`, `walkingAsymmetry`, `walkingStepLength`.
/// - Glucose discriminator codes (fasting / postprandial / random).
///
/// The flag is intentionally **not** consumed by the mapper — it surfaces
/// in `docs/fhir-loinc-mapping.md` (H.1 sub-deliverable) for clinician
/// review, and the H.5 export sheet can disclaim "draft mapping" rows.
public struct LOINCCode: Hashable, Sendable {
    /// LOINC numeric-dash code, e.g. `"8480-6"` (systolic BP).
    public let code: String
    /// Official LOINC long-name display string (English, from loinc.org).
    public let display: String
    /// `true` when the LOINC choice for this metric still needs clinician
    /// sign-off. Used by docs + UI disclaimers; the mapper emits the code
    /// regardless.
    public let physicianReviewPending: Bool
    /// The FHIR `Coding.system` URI this code belongs to. Defaults to the
    /// LOINC canonical URI. Apple-Health-native metrics that pre-date a
    /// LOINC term carry the HealthKit identifier under the custom HealthLog
    /// CodeSystem instead (`http://loinc.org` would be invalid for a
    /// non-LOINC code — see v0.11 FHIR-R4 conformance fixes / audit B5).
    public let system: CodeSystem

    public init(
        code: String,
        display: String,
        physicianReviewPending: Bool = false,
        system: CodeSystem = .loinc
    ) {
        self.code = code
        self.display = display
        self.physicianReviewPending = physicianReviewPending
        self.system = system
    }
}

/// The code system a `LOINCCode` entry lives under. Most entries are true
/// LOINC; Apple-Health metrics without a published LOINC term carry their
/// HealthKit identifier under a custom HealthLog CodeSystem so we never
/// emit a non-LOINC code inside the `http://loinc.org` namespace
/// (FHIR-R4 conformance — audit B5).
public enum CodeSystem: Hashable, Sendable {
    /// LOINC canonical URI — `http://loinc.org`.
    case loinc
    /// HealthLog custom CodeSystem for HealthKit-native identifiers that
    /// have no LOINC equivalent — `https://healthlog.dev/fhir/CodeSystem/healthkit`.
    case healthKit

    /// The FHIR `Coding.system` URI for this system.
    public var uri: String {
        switch self {
        case .loinc: "http://loinc.org"
        case .healthKit: "https://healthlog.dev/fhir/CodeSystem/healthkit"
        }
    }
}

// MARK: - Observation category

/// FHIR R4 `Observation.category` value, bound to the HL7 Observation
/// Category CodeSystem (`http://terminology.hl7.org/CodeSystem/observation-category`).
///
/// The vital-signs profile makes `category` **required** (1..*), and the
/// category is a preferred-binding field for every Observation. We pick
/// the category from the `MetricKind` so clinical vitals carry
/// `vital-signs`, lab analytes carry `laboratory`, and activity / fitness
/// aggregates carry `activity` (FHIR-R4 conformance — audit B1).
public enum ObservationCategory: String, Hashable, Sendable, CaseIterable {
    /// Clinical vital signs (HR, BP, temp, SpO2, respiratory rate, weight, BMI, …).
    case vitalSigns = "vital-signs"
    /// Laboratory analytes (blood glucose).
    case laboratory
    /// Activity / fitness measurements (steps, energy, distance, sleep, gait, …).
    case activity
    /// Survey / patient-reported instruments (v0158 — pain NRS, LOINC 72514-3).
    case survey

    /// The HL7 Observation Category CodeSystem URI.
    public static let systemURI = "http://terminology.hl7.org/CodeSystem/observation-category"

    /// Human-readable display for the category code.
    public var display: String {
        switch self {
        case .vitalSigns: "Vital Signs"
        case .laboratory: "Laboratory"
        case .activity: "Activity"
        case .survey: "Survey"
        }
    }
}

// MARK: - UCUM

/// A UCUM (Unified Code for Units of Measure) unit reference, suitable
/// for FHIR R4 `Quantity` (`system = "http://unitsofmeasure.org"`).
///
/// UCUM strings are case-sensitive and follow strict grammar — e.g.
/// millimetres of mercury is `"mm[Hg]"` (brackets are part of the
/// canonical form, **not** decoration), `"/min"` for "per minute"
/// (with the leading slash), and `"Cel"` for degrees Celsius (not
/// `"°C"`). See https://unitsofmeasure.org/ucum-essence.xml.
public struct UCUMUnit: Hashable, Sendable {
    /// UCUM-canonical unit code, e.g. `"mm[Hg]"`, `"kg"`, `"/min"`.
    public let unit: String

    public init(unit: String) {
        self.unit = unit
    }

    /// `true` when ``unit`` is a genuinely UCUM-canonical code that may be
    /// stamped as a FHIR `Quantity.system` (`http://unitsofmeasure.org`) +
    /// `Quantity.code`. Free-text / human-display unit strings (e.g. a German
    /// panel name "Großes Blutbild", or an ad-hoc "x") are NOT canonical — a
    /// strict UCUM validator rejects them — so they must ride as
    /// `Quantity.unit` (display text) only, WITHOUT a coded system/code.
    ///
    /// The allowlist covers the common lab + vital units a HealthLog user
    /// actually logs. UCUM is case-sensitive and grammar-strict; each entry is
    /// the exact canonical form (e.g. `"mm[Hg]"` with brackets, `"Cel"` for
    /// degrees Celsius, `"/min"` with the leading slash, `"10*9/L"` for
    /// 10⁹/L). Membership is decided on the exact (un-normalised) string —
    /// `"MG/DL"` is deliberately NOT canonical because UCUM is case-sensitive
    /// and the metric/prefix case carries meaning.
    public var isCanonical: Bool {
        UCUMUnit.canonicalUnits.contains(unit)
    }

    /// Exact-match allowlist of UCUM-canonical unit codes. Curated for the
    /// lab/vital units in scope; extend deliberately (each addition must be a
    /// real UCUM atom, verified against the UCUM grammar / ucum-essence.xml).
    ///
    /// Grouped by domain for review:
    ///  - dimensionless / ratios: `1`, `%`, `{score}` is *not* canonical UCUM
    ///    (annotation-only — intentionally excluded so day-log scores fall to
    ///    display text).
    ///  - mass-concentration: `g/dL`, `mg/dL`, `ug/dL`, `ng/mL`, `pg/mL`,
    ///    `ng/dL`, `ug/L`, `mg/L`, `g/L`.
    ///  - substance-concentration: `mmol/L`, `umol/L`, `nmol/L`, `pmol/L`,
    ///    `mol/L`, `mmol/mol`.
    ///  - catalytic activity: `U/L`, `mU/L`, `IU/L`, `mIU/L`.
    ///  - cell counts: `10*9/L`, `10*12/L`, `10*6/uL`, `10*3/uL`.
    ///  - vitals: `mm[Hg]`, `Cel`, `/min`, `kg`, `cm`, `m`, `kg/m2`, `%`,
    ///    `L/min`, `mL`, `L`.
    static let canonicalUnits: Set<String> = [
        // dimensionless + ratio
        "1", "%",
        // mass-concentration
        "g/dL", "mg/dL", "ug/dL", "ng/dL", "ng/mL", "pg/mL", "ug/L", "mg/L", "g/L", "ng/L", "pg/L",
        // substance-concentration
        "mol/L", "mmol/L", "umol/L", "nmol/L", "pmol/L", "mmol/mol",
        // catalytic activity (enzymes)
        "U/L", "mU/L", "IU/L", "mIU/L", "U/mL",
        // cell / particle counts
        "10*9/L", "10*12/L", "10*6/uL", "10*3/uL", "/uL", "/L",
        // vitals + anthropometry
        "mm[Hg]", "Cel", "/min", "kg", "g", "mg", "ug", "cm", "m", "mm",
        "kg/m2", "L/min", "mL", "L", "fL",
        // time / rate
        "h", "min", "s", "d"
    ]
}

// MARK: - Mapping record

/// One row of the `MetricKind` → FHIR mapping table.
///
/// `glucoseContext` is set **only** for glucose discriminator rows
/// returned by `MetricFHIRMapper.glucoseMapping(context:)`; for all
/// other kinds (including the default glucose row 2339-0) it stays
/// `nil`.
public struct MetricFHIRMapping: Hashable, Sendable {
    public let kind: MetricKind
    public let loinc: LOINCCode
    public let ucum: UCUMUnit
    public let glucoseContext: GlucoseContext?

    public init(
        kind: MetricKind,
        loinc: LOINCCode,
        ucum: UCUMUnit,
        glucoseContext: GlucoseContext? = nil
    ) {
        self.kind = kind
        self.loinc = loinc
        self.ucum = ucum
        self.glucoseContext = glucoseContext
    }
}
