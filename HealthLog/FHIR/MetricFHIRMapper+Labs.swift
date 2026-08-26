//
//  MetricFHIRMapper+Labs.swift
//  HealthLog (app target — same membership as MetricFHIRMapper)
//
//  v1.18.1 — labs/biomarker → FHIR R4 `Observation` mapping support
//  (`.planning/v0149-coherence/SPEC-labs-illness.md` §A — FHIR).
//
//  A `LabResultDTO` carries a free-text `analyte` string (server-resolved
//  from the linked `Biomarker` when `biomarkerId != nil`, otherwise
//  operator-typed). There is NO LOINC on the wire — the server contract
//  resolves analyte/unit/range only — so iOS maps the analyte NAME to a
//  LOINC code via a small curated table for the common blood-chemistry
//  analytes a German user actually logs. A linked biomarker whose analyte
//  resolves to a known LOINC rides the LOINC code path; everything else
//  (unknown analyte name OR an unlinked free-text row) degrades to a
//  text-only `Observation.code` (clinician-review-pending, the existing
//  LOINC-draft convention) so the export stays addressable + honest about
//  the missing terminology.
//
//  All entries carry `physicianReviewPending: true` — the analyte→LOINC
//  resolution is heuristic (name match, not a server-side terminology
//  binding) and must be clinician-reviewed before EMR import, exactly like
//  the body-composition / walking placeholders in the metric table.
//

import Foundation

public extension MetricFHIRMapper {
    /// One resolved lab-analyte mapping: the FHIR `Observation.code` LOINC
    /// entry plus the UCUM unit string to stamp on `valueQuantity`.
    ///
    /// `loinc == nil` means "no curated LOINC for this analyte" — the
    /// assembler then emits a **text-only** `Observation.code` (just
    /// `code.text = analyte`), which is valid FHIR R4 (`CodeableConcept`
    /// allows text without a coding) and the honest representation of an
    /// un-terminology-bound free-text lab row.
    struct LabAnalyteMapping: Hashable, Sendable {
        public let loinc: LOINCCode?
        public let ucum: UCUMUnit

        public init(loinc: LOINCCode?, ucum: UCUMUnit) {
            self.loinc = loinc
            self.ucum = ucum
        }
    }

    /// Curated analyte-name → LOINC table for the common blood-chemistry
    /// analytes. Keys are lower-cased, whitespace-trimmed analyte names; the
    /// lookup is name-based because the server contract carries no LOINC.
    /// Each LOINC entry is `physicianReviewPending` — the name match is a
    /// heuristic, not a server-bound terminology code.
    ///
    /// **Authority boundary (W-FHIR-CODING-CLEANUP, #30):** This table is
    /// trimmed to the analytes the server's authoritative coding map also
    /// resolves, so the OFFLINE local emitter never asserts a LOINC the server
    /// itself would not stamp (the `$everything` path passes server codings
    /// through unchanged — this fallback must agree with it, not over-reach).
    /// Client-only SPECULATIVE name guesses the server does NOT map were
    /// dropped — `ft3`, `ft4`, `vitamin b12`, `sodium`/`natrium`,
    /// `potassium`/`kalium`, and generic `glucose`/`glukose` — so those
    /// analytes now fall to the honest text-only path (no fabricated LOINC).
    ///
    /// UCUM strings follow the FHIR R4 grammar (case-sensitive). The unit a
    /// LabResult reports is preferred at the call site (operator/server
    /// truth); this table's UCUM is only a fallback when the row has none.
    private static let labAnalyteLOINCTable: [String: LOINCCode] = [
        "hba1c": LOINCCode(code: "4548-4", display: "Hemoglobin A1c/Hemoglobin.total in Blood", physicianReviewPending: true),
        "hemoglobin": LOINCCode(code: "718-7", display: "Hemoglobin [Mass/volume] in Blood", physicianReviewPending: true),
        "hämoglobin": LOINCCode(code: "718-7", display: "Hemoglobin [Mass/volume] in Blood", physicianReviewPending: true),
        "haemoglobin": LOINCCode(code: "718-7", display: "Hemoglobin [Mass/volume] in Blood", physicianReviewPending: true),
        "ldl": LOINCCode(
            code: "13457-7",
            display: "Cholesterol in LDL [Mass/volume] in Serum or Plasma by calculation",
            physicianReviewPending: true
        ),
        "ldl cholesterol": LOINCCode(
            code: "13457-7",
            display: "Cholesterol in LDL [Mass/volume] in Serum or Plasma by calculation",
            physicianReviewPending: true
        ),
        "hdl": LOINCCode(code: "2085-9", display: "Cholesterol in HDL [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "hdl cholesterol": LOINCCode(
            code: "2085-9",
            display: "Cholesterol in HDL [Mass/volume] in Serum or Plasma",
            physicianReviewPending: true
        ),
        "cholesterol": LOINCCode(code: "2093-3", display: "Cholesterol [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "total cholesterol": LOINCCode(
            code: "2093-3",
            display: "Cholesterol [Mass/volume] in Serum or Plasma",
            physicianReviewPending: true
        ),
        "triglycerides": LOINCCode(code: "2571-8", display: "Triglyceride [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "tsh": LOINCCode(code: "3016-3", display: "Thyrotropin [Units/volume] in Serum or Plasma", physicianReviewPending: true),
        "creatinine": LOINCCode(code: "2160-0", display: "Creatinine [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "kreatinin": LOINCCode(code: "2160-0", display: "Creatinine [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "ferritin": LOINCCode(code: "2276-4", display: "Ferritin [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "crp": LOINCCode(code: "1988-5", display: "C reactive protein [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "vitamin d": LOINCCode(code: "1989-3", display: "Vitamin D [Mass/volume] in Serum or Plasma", physicianReviewPending: true),
        "25-oh vitamin d": LOINCCode(code: "1989-3", display: "Vitamin D [Mass/volume] in Serum or Plasma", physicianReviewPending: true)
    ]

    /// Resolve a lab-result `analyte` name (+ the row's `isLinked` state) to a
    /// FHIR mapping.
    ///
    /// - A **linked** biomarker row (`isLinked == true`) whose analyte name
    ///   hits the curated table rides the LOINC code path.
    /// - An **unlinked** free-text row, OR a linked row whose analyte name has
    ///   no curated LOINC, returns `loinc == nil` → the assembler emits a
    ///   text-only `Observation.code` (review-pending, no fabricated code).
    ///
    /// The UCUM unit is the row's own `unit` when non-empty (operator/server
    /// truth), falling back to the curated table's UCUM, then to the
    /// dimensionless `"1"` so `valueQuantity` always carries a unit code.
    static func labMapping(analyte: String, unit: String, isLinked: Bool) -> LabAnalyteMapping {
        let normalized = analyte.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only a linked row earns the LOINC code path — an unlinked free-text
        // row is deliberately text-only even when its name happens to match,
        // because we have no terminology binding to trust it (SPEC §A FHIR).
        let loinc = isLinked ? labAnalyteLOINCTable[normalized] : nil
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let ucum = if !trimmedUnit.isEmpty {
            UCUMUnit(unit: trimmedUnit)
        } else {
            UCUMUnit(unit: "1")
        }
        return LabAnalyteMapping(loinc: loinc, ucum: ucum)
    }
}
