//
//  DoctorReportToFHIRBundle.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  Created 2026-05-22 — v0.6.0 H.4 DoctorReportSpec → FHIR R4 Bundle
//  assembler. Folds the Patient (H.2), Observations (per vitals row +
//  per chart point — H.2), MedicationStatements (H.3) and a clinician-
//  routing Composition + DiagnosticReport into a single FHIR R4
//  **Document** Bundle.
//
//  Why `.document` and not `.collection` / `.transaction`?
//  -------------------------------------------------------
//  The Doctor-Report export is the clinician-facing atomic snapshot of
//  a fixed report period. FHIR R4 reserves `Bundle.type = .document`
//  for "a self-contained set of resources at a point in time", with a
//  **mandatory first entry of type `Composition`** that describes the
//  document's structure (subject, author, sections, narrative). This
//  matches our use case 1:1:
//   - Atomic snapshot → operator hands the same Bundle to two doctors;
//     both see the identical period + sections.
//   - Composition.section gives the receiver a clinician-friendly
//     "Vital signs" + "Medications" table-of-contents without parsing
//     the resource graph.
//   - `.collection` would lose the Composition narrative + section
//     structure; `.transaction` would imply the receiver should PUT
//     each entry into its own store, which is the wrong contract for
//     a read-only doctor handoff.
//
//  Cross-reference resolution
//  --------------------------
//  Every Bundle entry sets `fullUrl = "urn:uuid:<resource.id>"`. Per
//  FHIR R4 §3.2.0.6 ("Bundle - Resolving References in Bundles"), a
//  Reference of the form `"Patient/<id>"` resolves to the entry whose
//  `Resource.id` matches — both forms (relative + urn:uuid) are
//  accepted by every spec-conformant FHIR consumer (HAPI, Microsoft
//  FHIR server, Apple Health Records). We keep the existing H.2 / H.3
//  mappers' `Reference("Patient/<patientID>")` convention and add the
//  `urn:uuid:` fullUrl so a future Bundle-aware consumer can resolve
//  either way.
//
//  Composition sections layout
//  ---------------------------
//  - "Vital signs"  → all Observation references (vitals rows + chart points).
//  - "Medications"  → all MedicationStatement references (active + archived).
//  - DiagnosticReport (last entry) → routes the same Observation refs as
//    `result[]`, with `effective = .period(cover.periodStart .. periodEnd)`.
//
//  Empty-section handling: per FHIR R4 `Composition.section` cardinality,
//  empty sections are valid but noisy. We omit a section entirely when
//  it would have zero entries — the receiver sees only the sections that
//  carry data. The Composition + Patient always render (Composition.subject
//  is mandatory for `Bundle.type = .document`).
//

import Foundation
import ModelsR4

/// Assembles a FHIR R4 **Document** `Bundle` from a `DoctorReportSpec`.
///
/// The same `DoctorReportSpec` that drives the PDF renderer drives the
/// FHIR emitter — single source of truth for one report-export request.
/// See file header for the `.document` rationale and Composition layout.
enum DoctorReportToFHIRBundle {
    /// FHIR-canonical URI for LOINC vital-signs codes (used by section text).
    static let loincSystemURI = "http://loinc.org"

    /// LOINC code for the "Diagnostic imaging study" parent class — we use
    /// the more generic "Vital signs panel" instead for the DiagnosticReport
    /// code because the report is a vitals roll-up.
    /// Source: https://loinc.org/85353-1/
    private static let vitalSignsPanelLOINC = "85353-1"

    /// Build a FHIR R4 Document Bundle from the given spec.
    ///
    /// - Throws: never in practice — the FHIR builders only throw on
    ///   invalid calendar components (which Foundation `Date` cannot
    ///   produce). The `throws` is kept on the signature to preserve
    ///   forward-compatibility with H.5 / H.6 (which may introduce
    ///   validator-driven failure paths).
    static func bundle(from spec: DoctorReportSpec) throws -> ModelsR4.Bundle {
        // Fresh Patient ID per export. The export is a snapshot, not an
        // upsert into a longitudinal record — the receiver should treat
        // each Bundle as self-contained.
        let patientID = UUID().uuidString.lowercased()

        // ---- 1) Patient ---------------------------------------------------

        let patient = makePatient(from: spec.cover, patientID: patientID)
        let patientFullURL = "urn:uuid:\(patientID)"

        // ---- 1b) Coverage (payor / insurer) ------------------------------
        // Machine-resolvable insurer (Krankenkasse) via a fhir.de Coverage
        // with a contained Organization carrying the IKNR. Emitted whenever
        // there is any payor signal (insurer name and/or KVNR); see
        // `makeCoverage` for the adaptive name-only fallback.
        let coverageID = UUID().uuidString.lowercased()
        let coverage = makeCoverage(from: spec.cover, coverageID: coverageID, patientID: patientID)

        // ---- 2) Observations (vitals rows + chart points) -----------------

        var observations: [Observation] = []

        if let vitals = spec.vitals {
            for row in vitals.rows {
                // AUD-4 M1 — a row whose value is non-finite / out-of-range is
                // dropped (nil) rather than emitting a corrupt Quantity.
                if let observation = makeSummaryObservation(
                    row: row,
                    patientID: patientID,
                    cover: spec.cover
                ) {
                    observations.append(observation)
                }
            }
        }

        if let charts = spec.charts {
            for series in charts.series {
                for point in series.points {
                    // AUD-4 M1 — drop non-finite / out-of-range points.
                    if let observation = makePointObservation(
                        kind: series.kind,
                        point: point,
                        patientID: patientID
                    ) {
                        observations.append(observation)
                    }
                }
            }
        }

        // ---- 3) MedicationStatements (active + archived) ------------------

        var medicationStatements: [MedicationStatement] = []

        if let medications = spec.medications {
            for row in medications.active {
                medicationStatements.append(makeMedicationStatement(
                    row: row,
                    archived: false,
                    patientID: patientID
                ))
            }
            for row in medications.archived {
                medicationStatements.append(makeMedicationStatement(
                    row: row,
                    archived: true,
                    patientID: patientID
                ))
            }
        }

        // ---- 3b) Lab Observations (v1.18.1 — category laboratory) ---------

        let labObservations = makeLabObservations(labs: spec.labs, patientID: patientID)

        // ---- 3c) Conditions + day-log Observations (v1.18.1) --------------

        let illnessResources = makeIllnessResources(illnesses: spec.illnesses, patientID: patientID)
        let conditions = illnessResources.conditions
        let illnessObservations = illnessResources.observations

        // ---- 4) Composition (first entry — mandatory for .document) -------

        let compositionID = UUID().uuidString.lowercased()
        let compositionFullURL = "urn:uuid:\(compositionID)"

        let observationRefs = observations.map { obs in
            Reference(reference: FHIRString("Observation/\(obs.id?.value?.string ?? "")").asPrimitive())
        }
        let medicationRefs = medicationStatements.map { stmt in
            Reference(reference: FHIRString("MedicationStatement/\(stmt.id?.value?.string ?? "")").asPrimitive())
        }
        let labRefs = labObservations.map { obs in
            Reference(reference: FHIRString("Observation/\(obs.id?.value?.string ?? "")").asPrimitive())
        }
        // The Conditions section routes the Condition refs; the supporting
        // day-log Observations also sit under it so a clinician sees the whole
        // episode in one place.
        let conditionRefs = conditions.map { cond in
            Reference(reference: FHIRString("Condition/\(cond.id?.value?.string ?? "")").asPrimitive())
        }
        let illnessObservationRefs = illnessObservations.map { obs in
            Reference(reference: FHIRString("Observation/\(obs.id?.value?.string ?? "")").asPrimitive())
        }

        let composition = makeComposition(
            compositionID: compositionID,
            patientID: patientID,
            spec: spec,
            observationRefs: observationRefs,
            medicationRefs: medicationRefs,
            labRefs: labRefs,
            conditionRefs: conditionRefs + illnessObservationRefs
        )

        // ---- 5) DiagnosticReport (vitals) ---------------------------------

        let diagnosticReportID = UUID().uuidString.lowercased()
        let diagnosticReport = makeDiagnosticReport(
            reportID: diagnosticReportID,
            patientID: patientID,
            spec: spec,
            observationRefs: observationRefs
        )

        // ---- 5b) Lab DiagnosticReport (groups the lab Observations) -------

        let labReportID = UUID().uuidString.lowercased()
        let labDiagnosticReport: DiagnosticReport? = labObservations.isEmpty
            ? nil
            : makeLabDiagnosticReport(
                reportID: labReportID,
                patientID: patientID,
                spec: spec,
                labRefs: labRefs
            )

        // ---- 6) Assemble Bundle -------------------------------------------

        let bundle = ModelsR4.Bundle(type: BundleType.document.asPrimitive())

        // Bundle identifier — fresh URN per export so two consecutive
        // generations are distinguishable.
        let bundleIdentifier = Identifier()
        bundleIdentifier.system = FHIRPrimitiveFactory.uri("urn:ietf:rfc:3986").asPrimitive()
        bundleIdentifier.value = FHIRString("urn:uuid:\(UUID().uuidString.lowercased())").asPrimitive()
        bundle.identifier = bundleIdentifier

        // Bundle timestamp — when the export was generated.
        bundle.timestamp = FHIRPrimitiveFactory.instant(from: spec.cover.generatedAt)

        bundle.entry = assembleEntries(
            composition: (compositionFullURL, composition),
            patient: (patientFullURL, patient),
            coverage: coverage.map { (coverageID, $0) },
            observations: observations,
            medicationStatements: medicationStatements,
            labObservations: labObservations,
            conditions: conditions,
            illnessObservations: illnessObservations,
            vitalsReport: (diagnosticReportID, diagnosticReport),
            labReport: labDiagnosticReport.map { (labReportID, $0) }
        )
        return bundle
    }

    // MARK: - Patient

    /// Official German GKV KVNR (Krankenversichertennummer) identifier system
    /// per fhir.de. Marks the KVNR identifier so a German FHIR consumer
    /// (Telematik-Infrastruktur, gematik) recognises it as the patient's
    /// statutory insurance number rather than a generic local id.
    private static let germanKVNRSystem = "http://fhir.de/sid/gkv/kvid-10"

    /// fhir.de IKNR (Institutionskennzeichen) identifier system — the
    /// machine-resolvable id of a German Krankenkasse. Carried on the
    /// contained `Organization.identifier` inside the `Coverage` payor.
    /// Confirmed byte-aligned with the server in v1.8.6
    /// (`v1.8.6-server-to-ios-coverage-CONFIRMED.md`).
    private static let germanIKNRSystem = "http://fhir.de/sid/arge-ik/iknr"

    private static func makePatient(from cover: DoctorReportSpec.Cover, patientID: String) -> Patient {
        let patient = Patient()
        patient.id = FHIRString(patientID).asPrimitive()

        // v0.10.0 — prefer the full legal name for the FHIR HumanName; fall
        // back to the cover's display patientName when no full name is set.
        let raw = (cover.fullName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? cover.patientName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            let parts = raw.split(separator: " ").map(String.init)
            let name = HumanName()
            name.text = FHIRString(raw).asPrimitive()
            if parts.count >= 2, let last = parts.last {
                name.family = FHIRString(last).asPrimitive()
                name.given = parts.dropLast().map { FHIRString($0).asPrimitive() }
            } else {
                name.given = [FHIRString(raw).asPrimitive()]
            }
            patient.name = [name]
        }

        // v0.10.0 — KVNR as the patient's statutory-insurance identifier. The
        // insurer (Krankenkasse) is the assigner of that number, so it rides
        // as `identifier.assigner.display` — semantically exact in FHIR R4 and
        // keeps everything inside the single Patient resource. The KVNR value
        // is the operator's own data on their own device (matches the web
        // export + the PDF cover); it is never logged.
        let kvnr = cover.insuranceNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let insurer = cover.insurerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let kvnr, !kvnr.isEmpty {
            let identifier = Identifier()
            identifier.system = FHIRPrimitiveFactory.uri(germanKVNRSystem).asPrimitive()
            identifier.value = FHIRString(kvnr).asPrimitive()
            if let insurer, !insurer.isEmpty {
                // The Krankenkasse is the assigner of the KVNR — surfaced as a
                // display-only assigner (which FHIR R4 allows on a Reference).
                // The machine-resolvable insurer (IKNR) now additionally rides
                // on the contained Organization inside the Coverage resource
                // (see `makeCoverage`); this assigner stays for redundancy so a
                // Patient-only consumer still sees the insurer name.
                let assigner = Reference()
                assigner.display = FHIRString(insurer).asPrimitive()
                identifier.assigner = assigner
            }
            patient.identifier = [identifier]
        }
        // No KVNR → no Patient.identifier. We deliberately do NOT emit an
        // Identifier carrying only an `assigner.display` (no system + no
        // value): such an Identifier is malformed FHIR (meaningless, some
        // validators warn). The insurer-without-KVNR case is dropped here;
        // the machine-resolvable home for the payor is the Coverage resource
        // (see `makeCoverage`, v0.11.0) — audit A2.
        return patient
    }

    // MARK: - Coverage

    /// Emit a fhir.de `Coverage` resource linking the patient to their
    /// statutory health insurer (Krankenkasse), so a German FHIR consumer can
    /// machine-resolve the payor. Shape confirmed byte-aligned with the server
    /// in v1.8.6 (`v1.8.6-server-to-ios-coverage-CONFIRMED.md`):
    ///   - `status = active`
    ///   - `beneficiary` → the Patient
    ///   - `subscriberId` → the KVNR (also on `Patient.identifier`, unchanged)
    ///   - `payor` → a **contained** `Organization` (local `#org` ref):
    ///       - `identifier` = `{ http://fhir.de/sid/arge-ik/iknr : <IKNR> }`
    ///       - `name` = insurer name
    ///
    /// Adaptive emission (per the confirmation): when the IKNR is absent we
    /// still emit the Coverage with a **name-only** Organization (no
    /// `identifier`) — keeping the payor relationship is more useful than
    /// dropping it. Returns `nil` only when there is no payor signal at all
    /// (no insurer name **and** no KVNR) — there is then nothing meaningful to
    /// model and a payor-less Coverage would be malformed.
    ///
    /// The KVNR + IKNR are the operator's own data; both are **never** logged.
    private static func makeCoverage(
        from cover: DoctorReportSpec.Cover,
        coverageID: String,
        patientID: String
    ) -> Coverage? {
        func trimmedNonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let kvnr = trimmedNonEmpty(cover.insuranceNumber)
        let insurer = trimmedNonEmpty(cover.insurerName)
        let iknr = trimmedNonEmpty(cover.insurerIkNumber)

        // Payor signal = insurer name OR IKNR. A bare KVNR (no name, no IK)
        // does NOT emit a Coverage: the KVNR already lives on
        // `Patient.identifier`, and a name-/IK-less payor Organization is
        // hollow FHIR. This matches the server's omit-on-KVNR-only rule so
        // both exporters omit Coverage under the identical condition (no
        // insurer name AND no IKNR) — coord
        // `v0.11-ios-to-server-kvnr-only-coverage.md`.
        guard insurer != nil || iknr != nil else { return nil }

        // ---- contained Organization (the payor) -------------------------
        let orgID = "org"
        let organization = Organization()
        organization.id = FHIRString(orgID).asPrimitive()
        if let insurer {
            organization.name = FHIRString(insurer).asPrimitive()
        }
        if let iknr {
            let orgIdentifier = Identifier()
            orgIdentifier.system = FHIRPrimitiveFactory.uri(germanIKNRSystem).asPrimitive()
            orgIdentifier.value = FHIRString(iknr).asPrimitive()
            organization.identifier = [orgIdentifier]
        }

        // ---- Coverage ---------------------------------------------------
        let beneficiary = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        // Local reference to the contained Organization (`#org`).
        let payorRef = Reference(reference: FHIRString("#\(orgID)").asPrimitive())

        let coverage = Coverage(
            beneficiary: beneficiary,
            payor: [payorRef],
            status: FinancialResourceStatusCodes.active.asPrimitive()
        )
        coverage.id = FHIRString(coverageID).asPrimitive()
        coverage.contained = [.organization(organization)]
        if let kvnr {
            coverage.subscriberId = FHIRString(kvnr).asPrimitive()
        }
        return coverage
    }

    // MARK: - Observations

    /// One Observation per `VitalsSummary.Row` — uses the row's `mean` as
    /// the canonical value. For BP, the secondary mean becomes the
    /// diastolic component.
    ///
    /// A summary row is an aggregate over the whole report window, so it
    /// carries `effectivePeriod = cover.periodStart .. periodEnd` rather
    /// than a single dateless instant — every Observation must carry a
    /// valid `effective[x]` (FHIR-R4 conformance — audit B6).
    /// Returns `nil` when the row's value is non-finite / out-of-range so the
    /// caller drops it from the bundle rather than emitting a corrupt /
    /// encode-aborting Quantity (AUD-4 M1).
    private static func makeSummaryObservation(
        row: DoctorReportSpec.VitalsSummary.Row,
        patientID: String,
        cover: DoctorReportSpec.Cover
    ) -> Observation? {
        let mapping = MetricFHIRMapper.mapping(for: row.kind)
            ?? fallbackMapping(kind: row.kind)

        let code = makeCodeableConcept(loinc: mapping.loinc)
        let status: FHIRPrimitive<ObservationStatus> = ObservationStatus.final.asPrimitive()
        let observation = Observation(code: code, status: status)
        observation.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()
        observation.category = [makeCategoryConcept(MetricFHIRMapper.category(for: row.kind))]
        observation.subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())

        // Aggregate over the report window → effectivePeriod.
        let period = Period()
        period.start = FHIRPrimitiveFactory.dateTime(from: cover.periodStart)
        period.end = FHIRPrimitiveFactory.dateTime(from: cover.periodEnd)
        observation.effective = .period(period)

        if row.kind == .bloodPressure { // summary row
            // Systolic always present; emit the diastolic component only when
            // a secondary mean exists — never fabricate a `0 mm[Hg]` reading
            // (FHIR-R4 data-correctness — audit B4-edge). AUD-4 M1: a non-finite
            // systolic drops the whole row.
            guard let sysComponent = makeBPComponent(
                loinc: MetricFHIRMapper.bloodPressureSystolicLOINC, value: row.mean
            ) else { return nil }
            var components = [sysComponent]
            if let diastolic = row.secondaryMean,
               let diaComponent = makeBPComponent(
                   loinc: MetricFHIRMapper.bloodPressureDiastolicLOINC, value: diastolic
               )
            {
                components.append(diaComponent)
            }
            observation.component = components
        } else {
            guard let quantity = makeQuantity(value: row.mean, ucum: mapping.ucum) else { return nil }
            observation.value = .quantity(quantity)
        }

        return observation
    }

    /// Fallback mapping for a `MetricKind` with no LOINC entry. Surfaces the
    /// raw kind name under the custom HealthLog CodeSystem rather than the
    /// invalid `00000-0` LOINC placeholder (FHIR-R4 conformance — audit B5).
    /// In practice `MetricFHIRMapper.mapping(for:)` covers every kind, so
    /// this is a forward-compat guard for a future `MetricKind` addition.
    private static func fallbackMapping(kind: MetricKind) -> MetricFHIRMapping {
        MetricFHIRMapping(
            kind: kind,
            loinc: LOINCCode(code: kind.rawValue, display: kind.rawValue, system: .healthKit),
            ucum: UCUMUnit(unit: "1")
        )
    }

    /// One Observation per chart point — `effective = .dateTime(point.at)`,
    /// `value = .quantity(point.value)`.
    /// Returns `nil` when the point's value is non-finite / out-of-range so the
    /// caller drops it from the bundle rather than emitting a corrupt /
    /// encode-aborting Quantity (AUD-4 M1).
    private static func makePointObservation(
        kind: MetricKind,
        point: DoctorReportSpec.ChartsBlock.Point,
        patientID: String
    ) -> Observation? {
        let mapping = MetricFHIRMapper.mapping(for: kind)
            ?? fallbackMapping(kind: kind)

        let code = makeCodeableConcept(loinc: mapping.loinc)
        let status: FHIRPrimitive<ObservationStatus> = ObservationStatus.final.asPrimitive()
        let observation = Observation(code: code, status: status)
        observation.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()
        observation.category = [makeCategoryConcept(MetricFHIRMapper.category(for: kind))]
        observation.subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        observation.effective = .dateTime(FHIRPrimitiveFactory.dateTime(from: point.at))

        if kind == .bloodPressure {
            // Emit the diastolic component only when present — never a
            // fabricated `0 mm[Hg]` reading (audit B4-edge). AUD-4 M1: a
            // non-finite systolic drops the whole point.
            guard let sysComponent = makeBPComponent(
                loinc: MetricFHIRMapper.bloodPressureSystolicLOINC, value: point.value
            ) else { return nil }
            var components = [sysComponent]
            if let diastolic = point.secondary,
               let diaComponent = makeBPComponent(
                   loinc: MetricFHIRMapper.bloodPressureDiastolicLOINC, value: diastolic
               )
            {
                components.append(diaComponent)
            }
            observation.component = components
        } else {
            guard let quantity = makeQuantity(value: point.value, ucum: mapping.ucum) else { return nil }
            observation.value = .quantity(quantity)
        }
        return observation
    }

    // MARK: - MedicationStatement

    private static func makeMedicationStatement(
        row: DoctorReportSpec.MedicationsBlock.Row,
        archived: Bool,
        patientID: String
    ) -> MedicationStatement {
        let concept = CodeableConcept()
        concept.text = FHIRString(row.name).asPrimitive()

        let status: MedicationStatementStatusCodes = archived ? .completed : .active
        let statement = MedicationStatement(
            medication: .codeableConcept(concept),
            status: status.asPrimitive(),
            subject: Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        )
        statement.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()

        let identifier = Identifier()
        identifier.value = FHIRString(row.id).asPrimitive()
        statement.identifier = [identifier]

        // Surface dose + schedule as free-text dosage — the spec rows are
        // already the operator-edited display strings.
        let dosage = Dosage()
        if !row.dose.isEmpty {
            dosage.text = FHIRString("\(row.dose) — \(row.schedule)").asPrimitive()
        } else if !row.schedule.isEmpty {
            dosage.text = FHIRString(row.schedule).asPrimitive()
        }
        statement.dosage = [dosage]

        return statement
    }

    // MARK: - Composition

    private static func makeComposition(
        compositionID: String,
        patientID: String,
        spec: DoctorReportSpec,
        observationRefs: [Reference],
        medicationRefs: [Reference],
        labRefs: [Reference],
        conditionRefs: [Reference]
    ) -> Composition {
        let typeConcept = CodeableConcept()
        let typeCoding = Coding()
        typeCoding.system = FHIRPrimitiveFactory.uri(loincSystemURI).asPrimitive()
        typeCoding.code = FHIRString("11503-0").asPrimitive() // "Medical records"
        typeCoding.display = FHIRString("Medical records").asPrimitive()
        typeConcept.coding = [typeCoding]
        typeConcept.text = FHIRString("HealthLog Doctor Report").asPrimitive()

        let patientRef = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())

        let composition = Composition(
            author: [patientRef], // self-reported snapshot
            date: FHIRPrimitiveFactory.dateTime(from: spec.cover.generatedAt),
            status: CompositionStatus.final.asPrimitive(),
            subject: patientRef,
            title: FHIRString("HealthLog Doctor Report").asPrimitive(),
            type: typeConcept
        )
        composition.id = FHIRString(compositionID).asPrimitive()

        // Composition.text — a `Bundle.type = document` requires a
        // human-readable narrative on the Composition (the legally-renderable
        // content). Generate a minimal `status = generated` XHTML summary of
        // the report period + section counts (FHIR-R4 conformance — audit D2).
        let summaryHTML = "<p>HealthLog Doctor Report — \(reportPeriodText(spec.cover))</p>"
            + "<p>\(observationRefs.count) Observation(s), \(medicationRefs.count) Medication(s), "
            + "\(labRefs.count) Lab result(s), \(conditionRefs.count) Condition resource(s).</p>"
        composition.text = makeNarrative(html: summaryHTML)

        var sections: [CompositionSection] = []

        if !observationRefs.isEmpty {
            sections.append(makeSection(
                title: "Vital signs",
                narrativeHTML: "<p>\(observationRefs.count) vital-sign observation(s) over the report period.</p>",
                entries: observationRefs
            ))
        }
        if !labRefs.isEmpty {
            sections.append(makeSection(
                title: "Laboratory",
                narrativeHTML: "<p>\(labRefs.count) laboratory observation(s).</p>",
                entries: labRefs
            ))
        }
        if !medicationRefs.isEmpty {
            sections.append(makeSection(
                title: "Medications",
                narrativeHTML: "<p>\(medicationRefs.count) medication statement(s).</p>",
                entries: medicationRefs
            ))
        }
        if !conditionRefs.isEmpty {
            sections.append(makeSection(
                title: "Conditions",
                narrativeHTML: "<p>\(conditionRefs.count) condition / supporting observation resource(s).</p>",
                entries: conditionRefs
            ))
        }

        if !sections.isEmpty {
            composition.section = sections
        }

        return composition
    }

    private static func makeSection(
        title: String,
        narrativeHTML: String,
        entries: [Reference]
    ) -> CompositionSection {
        let section = CompositionSection()
        section.title = FHIRString(title).asPrimitive()
        section.text = makeNarrative(html: narrativeHTML)
        section.entry = entries
        return section
    }

    /// Build a FHIR `Narrative` with `status = generated` and an XHTML
    /// `div`. FHIR requires the div to be a single root `<div>` in the
    /// XHTML namespace (`http://www.w3.org/1999/xhtml`). `html` is the
    /// inner markup (already HTML-safe — generated from counts + a
    /// pre-escaped period string, never raw user input).
    static func makeNarrative(html: String) -> Narrative {
        Narrative(
            div: FHIRString("<div xmlns=\"http://www.w3.org/1999/xhtml\">\(html)</div>").asPrimitive(),
            status: NarrativeStatus.generated.asPrimitive()
        )
    }

    /// Human-readable, HTML-safe report-period string for the narrative.
    /// Dates are rendered ISO-8601 (yyyy-MM-dd) so the output contains no
    /// XHTML-significant characters.
    private static func reportPeriodText(_ cover: DoctorReportSpec.Cover) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: cover.periodStart)) – \(formatter.string(from: cover.periodEnd))"
    }

    // MARK: - DiagnosticReport

    private static func makeDiagnosticReport(
        reportID: String,
        patientID: String,
        spec: DoctorReportSpec,
        observationRefs: [Reference]
    ) -> DiagnosticReport {
        let codeConcept = CodeableConcept()
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(loincSystemURI).asPrimitive()
        coding.code = FHIRString(vitalSignsPanelLOINC).asPrimitive()
        coding.display = FHIRString("Vital signs, weight, height, head circumference, oxygen saturation and BMI panel").asPrimitive()
        codeConcept.coding = [coding]
        codeConcept.text = FHIRString("Vital signs panel").asPrimitive()

        let report = DiagnosticReport(
            code: codeConcept,
            status: DiagnosticReportStatus.final.asPrimitive()
        )
        report.id = FHIRString(reportID).asPrimitive()
        report.subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())

        let period = Period()
        period.start = FHIRPrimitiveFactory.dateTime(from: spec.cover.periodStart)
        period.end = FHIRPrimitiveFactory.dateTime(from: spec.cover.periodEnd)
        report.effective = .period(period)

        if !observationRefs.isEmpty {
            report.result = observationRefs
        }
        return report
    }

    // MARK: - Bundle entry helpers

    static func makeEntry(fullURL: String, resource: ResourceProxy) -> BundleEntry {
        let entry = BundleEntry()
        entry.fullUrl = FHIRPrimitiveFactory.uri(fullURL).asPrimitive()
        entry.resource = resource
        return entry
    }

    // MARK: - Shared FHIR primitive helpers

    static func makeCodeableConcept(loinc: LOINCCode) -> CodeableConcept {
        let coding = Coding()
        // Honour the code's own system — true LOINC stays in
        // `http://loinc.org`; HealthKit-native placeholders ride the custom
        // HealthLog CodeSystem (audit B5).
        coding.system = FHIRPrimitiveFactory.uri(loinc.system.uri).asPrimitive()
        coding.code = FHIRString(loinc.code).asPrimitive()
        coding.display = FHIRString(loinc.display).asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        concept.text = FHIRString(loinc.display).asPrimitive()
        return concept
    }

    /// Build the `Observation.category` CodeableConcept for a category,
    /// bound to the HL7 Observation Category CodeSystem (audit B1).
    static func makeCategoryConcept(_ category: ObservationCategory) -> CodeableConcept {
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(ObservationCategory.systemURI).asPrimitive()
        coding.code = FHIRString(category.rawValue).asPrimitive()
        coding.display = FHIRString(category.display).asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    /// FHIR-canonical UCUM system URI (`Quantity.system` for coded units).
    static let ucumSystemURI = "http://unitsofmeasure.org"

    /// Build a FHIR `Quantity` from a value + a UCUM unit.
    ///
    /// Only **genuinely UCUM-canonical** units (``UCUMUnit/isCanonical``) get a
    /// coded `system` (`http://unitsofmeasure.org`) + `code` — a strict UCUM
    /// validator rejects free-text units stamped as canonical codes. A
    /// non-canonical / free-text unit (e.g. a German panel name, or "x") is
    /// emitted as `Quantity.unit` (human display) WITHOUT a system/code, which
    /// is valid FHIR R4: a Quantity may carry a unit string without a coded
    /// system. The empty unit produces a bare numeric Quantity (no unit at all).
    ///
    /// Vitals (mm[Hg], Cel, /min, kg, …) are all canonical, so the vitals path
    /// is unchanged — they keep their coded system+code.
    /// Returns `nil` for a non-finite / out-of-range `value` (AUD-4 M1) so the
    /// caller can DROP the observation rather than emit a corrupt / encode-
    /// aborting Quantity.
    static func makeQuantity(value: Double, ucum: UCUMUnit) -> Quantity? {
        guard let safeValue = FHIRDecimal(safeServer: value) else { return nil }
        let quantity = Quantity()
        quantity.value = safeValue.asPrimitive()
        let unitString = ucum.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unitString.isEmpty else { return quantity }

        if ucum.isCanonical {
            // Canonical UCUM → coded Quantity (system + code + display unit).
            quantity.unit = FHIRString(unitString).asPrimitive()
            quantity.system = FHIRPrimitiveFactory.uri(ucumSystemURI).asPrimitive()
            quantity.code = FHIRString(unitString).asPrimitive()
        } else {
            // Free-text / unknown unit → display-only `unit`, NO system/code.
            // (Fabricating `code = "<free text>"` produces invalid UCUM that
            //  strict validators reject — drop to unit-text-only instead.)
            quantity.unit = FHIRString(unitString).asPrimitive()
        }
        return quantity
    }

    /// Returns `nil` for a non-finite / out-of-range `value` (AUD-4 M1).
    private static func makeBPComponent(loinc: LOINCCode, value: Double) -> ObservationComponent? {
        guard let quantity = makeQuantity(value: value, ucum: UCUMUnit(unit: "mm[Hg]")) else { return nil }
        let component = ObservationComponent(code: makeCodeableConcept(loinc: loinc))
        component.value = .quantity(quantity)
        return component
    }
}

/// File-private low-level FHIR primitive builders, lifted out of
/// `DoctorReportToFHIRBundle` to keep the assembler's type-body length in
/// check (these are pure leaf constructors with no assembler state).
enum FHIRPrimitiveFactory {
    static func uri(_ string: String) -> FHIRURI {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid FHIR URI: \(string)")
        }
        return FHIRURI(url)
    }

    static func dateTime(from date: Date) -> FHIRPrimitive<DateTime> {
        // A2-L4 — non-throwing construction (no `try!` on runtime dates).
        FHIRDateConverter.dateTime(from: date).asPrimitive()
    }

    static func instant(from date: Date) -> FHIRPrimitive<Instant> {
        // A2-L4 — non-throwing construction (no `try!` on runtime dates).
        FHIRDateConverter.instant(from: date).asPrimitive()
    }
}
