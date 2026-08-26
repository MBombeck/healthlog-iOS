//
//  DoctorReportToFHIRBundle+LabsIllness.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  v1.18.1 — labs + illness/condition FHIR R4 mappers, split out of
//  `DoctorReportToFHIRBundle.swift` to keep the assembler's type-body under
//  the SwiftLint budget (file_length discipline). These are pure leaf
//  constructors with no assembler state — same idiom as the existing
//  per-row Observation / MedicationStatement makers.
//
//  Mapping contract (`.planning/v0149-coherence/SPEC-labs-illness.md` §A/§B):
//   - Labs → one `Observation` per `LabResultDTO`, category `laboratory`,
//     `valueQuantity` (value + unit, UCUM where known), `referenceRange`
//     from `referenceLow`/`referenceHigh`, `interpretation` from the
//     server's singular `rangeStatus` verdict (in-range→N, below→L,
//     above→H — RENDERED, never recomputed). Linked-biomarker rows whose
//     analyte resolves to a curated LOINC ride the LOINC code path; every
//     other row (unlinked free-text OR unknown analyte) degrades to a
//     text-only `Observation.code` marked physician-review-pending.
//   - Illness → one `Condition` per episode, `clinicalStatus`
//     active/resolved from `resolvedAt`, `category` problem-list-item,
//     `onsetDateTime`=onsetAt, `abatementDateTime`=resolvedAt, `code` from
//     type/label (text coding — no terminology binding on the wire). Day-log
//     `functionalImpact` / `feverC` become supporting `Observation`s whose
//     `focus` points back to the Condition.
//

import Foundation
import ModelsR4

extension DoctorReportToFHIRBundle {
    // MARK: - Shared system URIs

    /// HL7 Condition clinical-status CodeSystem.
    static let conditionClinicalSystem = "http://terminology.hl7.org/CodeSystem/condition-clinical"
    /// HL7 Condition category CodeSystem.
    static let conditionCategorySystem = "http://terminology.hl7.org/CodeSystem/condition-category"
    /// HL7 Condition verification-status CodeSystem (`Condition.verificationStatus`).
    static let conditionVerStatusSystem = "http://terminology.hl7.org/CodeSystem/condition-ver-status"
    /// SNOMED CT CodeSystem (`Condition.code` clinical category coding).
    static let snomedSystem = "http://snomed.info/sct"
    /// HL7 v3 Observation interpretation CodeSystem.
    static let interpretationSystem = "http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation"
    /// HL7 Data-Absent-Reason CodeSystem (`Observation.dataAbsentReason`).
    static let dataAbsentReasonSystem = "http://terminology.hl7.org/CodeSystem/data-absent-reason"

    // MARK: - Bundle entry assembly

    /// Assemble the full ordered `BundleEntry` list. Lifted out of
    /// `bundle(from:)` so the assembler's cyclomatic complexity stays within
    /// budget (the per-collection loops + optional guards live here instead).
    /// Order is unchanged: Composition, Patient, (Coverage), vital + chart
    /// Observations, MedicationStatements, lab Observations, Conditions,
    /// day-log Observations, vitals DiagnosticReport, (lab DiagnosticReport).
    static func assembleEntries(
        composition: (id: String, resource: Composition),
        patient: (id: String, resource: Patient),
        coverage: (id: String, resource: Coverage)?,
        observations: [Observation],
        medicationStatements: [MedicationStatement],
        labObservations: [Observation],
        conditions: [Condition],
        illnessObservations: [Observation],
        vitalsReport: (id: String, resource: DiagnosticReport),
        labReport: (id: String, resource: DiagnosticReport)?
    ) -> [BundleEntry] {
        var entries: [BundleEntry] = []
        entries.append(makeEntry(fullURL: composition.id, resource: .composition(composition.resource)))
        entries.append(makeEntry(fullURL: patient.id, resource: .patient(patient.resource)))
        if let coverage {
            entries.append(makeEntry(fullURL: "urn:uuid:\(coverage.id)", resource: .coverage(coverage.resource)))
        }
        entries.append(contentsOf: observations.map { makeURNEntry(.observation($0), id: $0.id) })
        entries.append(contentsOf: medicationStatements.map { makeURNEntry(.medicationStatement($0), id: $0.id) })
        entries.append(contentsOf: labObservations.map { makeURNEntry(.observation($0), id: $0.id) })
        entries.append(contentsOf: conditions.map { makeURNEntry(.condition($0), id: $0.id) })
        entries.append(contentsOf: illnessObservations.map { makeURNEntry(.observation($0), id: $0.id) })
        entries.append(makeEntry(fullURL: "urn:uuid:\(vitalsReport.id)", resource: .diagnosticReport(vitalsReport.resource)))
        if let labReport {
            entries.append(makeEntry(fullURL: "urn:uuid:\(labReport.id)", resource: .diagnosticReport(labReport.resource)))
        }
        return entries
    }

    /// Wrap a resource in a `BundleEntry` whose `fullUrl` is the resource's own
    /// `urn:uuid:<id>`. The resource id is read off the proxy's underlying id.
    private static func makeURNEntry(_ resource: ResourceProxy, id: FHIRPrimitive<FHIRString>?) -> BundleEntry {
        makeEntry(fullURL: "urn:uuid:\(id?.value?.string ?? "")", resource: resource)
    }

    // MARK: - Block builders (called by the assembler)

    /// Build one lab `Observation` per result. Empty when the block is `nil`.
    static func makeLabObservations(labs: DoctorReportSpec.LabsBlock?, patientID: String) -> [Observation] {
        guard let labs else { return [] }
        return labs.results.map { makeLabObservation(row: $0, patientID: patientID) }
    }

    /// Build one `Condition` per episode plus the supporting day-log
    /// `Observation`s (focused back on their Condition). Empty when `nil`.
    static func makeIllnessResources(
        illnesses: DoctorReportSpec.IllnessBlock?,
        patientID: String
    ) -> (conditions: [Condition], observations: [Observation]) {
        guard let illnesses else { return ([], []) }
        var conditions: [Condition] = []
        var observations: [Observation] = []
        for episode in illnesses.episodes {
            let condition = makeCondition(episode: episode, patientID: patientID)
            let conditionID = condition.id?.value?.string ?? ""
            conditions.append(condition)
            let dayLogs = illnesses.dayLogsByEpisode[episode.id] ?? []
            for dayLog in dayLogs {
                observations.append(contentsOf: makeDayLogObservations(
                    dayLog: dayLog,
                    conditionID: conditionID,
                    patientID: patientID
                ))
            }
        }
        return (conditions, observations)
    }

    // MARK: - Labs → Observation

    /// One `Observation` (category `laboratory`) per lab result.
    ///
    /// Linked-biomarker rows whose analyte resolves to a curated LOINC carry
    /// the LOINC `code.coding`; everything else carries a text-only
    /// `code` (just `code.text = analyte`) — valid FHIR R4 and the honest
    /// representation of a row without a terminology binding. The text-only
    /// rows are flagged review-pending via an explicit `dataAbsentReason`-free
    /// note in the section narrative + the absence of a coding.
    static func makeLabObservation(row: LabResultDTO, patientID: String) -> Observation {
        let mapping = MetricFHIRMapper.labMapping(
            analyte: row.analyte,
            unit: row.unit,
            isLinked: row.isLinked
        )

        let code: CodeableConcept
        if let loinc = mapping.loinc {
            code = makeCodeableConcept(loinc: loinc)
        } else {
            // Text-only code — no fabricated LOINC. The analyte string is the
            // operator/server truth; a clinician reviews the mapping manually.
            code = CodeableConcept()
            code.text = FHIRString(row.analyte.isEmpty ? "Lab result" : row.analyte).asPrimitive()
        }

        let observation = Observation(code: code, status: ObservationStatus.final.asPrimitive())
        observation.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()
        observation.category = [makeCategoryConcept(.laboratory)]
        observation.subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())

        // Effective = takenAt when parseable; the lab value is a point sample.
        if let takenAt = parseISO(row.takenAt) {
            observation.effective = .dateTime(FHIRPrimitiveFactory.dateTime(from: takenAt))
        }

        // Absent value (server omitted the measurement) → emit
        // `dataAbsentReason` INSTEAD of a misleading `valueQuantity: 0`. FHIR R4
        // forbids `value[x]` and `dataAbsentReason` together, so it is strictly
        // one or the other. A genuine `0` (key present) still emits
        // `valueQuantity: 0`.
        // AUD-4 M1 — a non-finite / out-of-range lab value can't be represented
        // as a valid Quantity (garbage on +inf, encode-abort on NaN). Treat it
        // as data-absent (FHIR-correct) rather than emitting a corrupt value.
        // Item 1.5 — a QUALITATIVE row ("negativ") is not data-absent: it has a
        // result, just not a numeric one. FHIR R4 models that as `valueString`,
        // so emit it rather than claiming the value is unknown. Order matters:
        // numeric wins, then qualitative text, then genuine absence.
        if let value = row.value, let quantity = makeQuantity(value: value, ucum: mapping.ucum) {
            observation.value = .quantity(quantity)
        } else if let valueText = row.valueText, !valueText.isEmpty {
            observation.value = .string(FHIRString(valueText).asPrimitive())
        } else {
            observation.dataAbsentReason = makeDataAbsentReason()
        }

        // referenceRange from the row's bounds (server-resolved for linked
        // rows; operator-typed otherwise). Emit only the present bounds —
        // never a fabricated 0 bound.
        if let referenceRange = makeLabReferenceRange(low: row.referenceLow, high: row.referenceHigh, ucum: mapping.ucum) {
            observation.referenceRange = [referenceRange]
        }

        // interpretation from the server's singular NEUTRAL verdict — rendered,
        // never recomputed. `unknown` → no interpretation (nothing to assert).
        if let interpretation = makeInterpretation(for: row.rangeStatus) {
            observation.interpretation = [interpretation]
        }

        return observation
    }

    /// Build an `ObservationReferenceRange` from the (optional) low/high
    /// bounds. Returns `nil` when neither bound is present (an empty range is
    /// noise). Each present bound becomes a `SimpleQuantity` in the row's UCUM.
    private static func makeLabReferenceRange(
        low: Double?,
        high: Double?,
        ucum: UCUMUnit
    ) -> ObservationReferenceRange? {
        guard low != nil || high != nil else { return nil }
        // AUD-4 M1 — skip a non-finite / out-of-range bound (makeQuantity → nil)
        // rather than stamping a corrupt SimpleQuantity onto the range.
        let lowQuantity = low.flatMap { makeQuantity(value: $0, ucum: ucum) }
        let highQuantity = high.flatMap { makeQuantity(value: $0, ucum: ucum) }
        guard lowQuantity != nil || highQuantity != nil else { return nil }
        let range = ObservationReferenceRange()
        range.low = lowQuantity
        range.high = highQuantity
        return range
    }

    /// Map the server's NEUTRAL `rangeStatus` to a v3 ObservationInterpretation
    /// coding (`N` normal / `L` low / `H` high). `unknown` → `nil` (we assert
    /// nothing when the lab reported no usable bounds). This RENDERS the
    /// server's singular verdict — it never recomputes from value vs. range.
    private static func makeInterpretation(for status: LabRangeStatus) -> CodeableConcept? {
        let codeAndDisplay: (String, String)? = switch status {
        case .inRange: ("N", "Normal")
        case .below: ("L", "Low")
        case .above: ("H", "High")
        case .unknown: nil
        }
        guard let (code, display) = codeAndDisplay else { return nil }
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(interpretationSystem).asPrimitive()
        coding.code = FHIRString(code).asPrimitive()
        coding.display = FHIRString(display).asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    /// Build the `Observation.dataAbsentReason` CodeableConcept for an absent
    /// lab value, bound to the HL7 Data-Absent-Reason CodeSystem with code
    /// `unknown` ("The value is expected to exist but is not known").
    private static func makeDataAbsentReason() -> CodeableConcept {
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(dataAbsentReasonSystem).asPrimitive()
        coding.code = FHIRString("unknown").asPrimitive()
        coding.display = FHIRString("Unknown").asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    /// A lab `DiagnosticReport` (category `laboratory`, LOINC `11502-2`
    /// "Laboratory report") grouping every lab Observation as `result[]`.
    static func makeLabDiagnosticReport(
        reportID: String,
        patientID: String,
        spec: DoctorReportSpec,
        labRefs: [Reference]
    ) -> DiagnosticReport {
        let codeConcept = CodeableConcept()
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(loincSystemURI).asPrimitive()
        coding.code = FHIRString("11502-2").asPrimitive()
        coding.display = FHIRString("Laboratory report").asPrimitive()
        codeConcept.coding = [coding]
        codeConcept.text = FHIRString("Laboratory report").asPrimitive()

        let report = DiagnosticReport(
            code: codeConcept,
            status: DiagnosticReportStatus.final.asPrimitive()
        )
        report.id = FHIRString(reportID).asPrimitive()
        report.subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        report.category = [makeCategoryConcept(.laboratory)]

        let period = Period()
        period.start = FHIRPrimitiveFactory.dateTime(from: spec.cover.periodStart)
        period.end = FHIRPrimitiveFactory.dateTime(from: spec.cover.periodEnd)
        report.effective = .period(period)

        if !labRefs.isEmpty {
            report.result = labRefs
        }
        return report
    }

    // MARK: - Illness → Condition

    /// One `Condition` per illness episode.
    static func makeCondition(episode: IllnessEpisodeDTO, patientID: String) -> Condition {
        let condition = Condition(subject: Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive()))
        condition.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()

        // clinicalStatus — resolved when an abatement date exists, else active.
        let isResolved = !(episode.resolvedAt ?? "").isEmpty
        condition.clinicalStatus = makeConditionClinicalStatus(resolved: isResolved)

        // verificationStatus — `unconfirmed`. The episode is a patient self-log,
        // never a clinician-confirmed diagnosis. Mirrors the server's guard rail
        // so the Condition does not over-assert (W-FHIR-CODING-CLEANUP, #30).
        condition.verificationStatus = makeConditionVerificationStatus()

        // category — problem-list-item (a journaled long-lived condition,
        // not an encounter-scoped diagnosis).
        condition.category = [makeConditionCategory()]

        // code — the episode label as text PLUS the server's deterministic
        // SNOMED-CT clinical-category coding for the `IllnessType` (enum→code,
        // mirrored 1:1 from the server map — never a per-row guess). The free
        // text stays the operator's own words; the SNOMED coding makes the
        // Condition addressable by a clinician's EMR.
        let codeConcept = CodeableConcept()
        let label = episode.label.trimmingCharacters(in: .whitespacesAndNewlines)
        codeConcept.text = FHIRString(label.isEmpty ? illnessTypeDisplay(episode.type) : label).asPrimitive()
        codeConcept.coding = [makeIllnessCategoryCoding(episode.type)]
        condition.code = codeConcept

        // note — flag the patient-reported provenance so a reviewing clinician
        // reads the SNOMED category as a self-reported bucket, not a diagnosis.
        condition.note = [Annotation(text: FHIRString(patientReportedNote).asPrimitive())]

        // onset = onsetAt; abatement = resolvedAt (when present).
        if let onset = parseISO(episode.onsetAt) {
            condition.onset = .dateTime(FHIRPrimitiveFactory.dateTime(from: onset))
        }
        if let resolvedAt = episode.resolvedAt, let abatement = parseISO(resolvedAt) {
            condition.abatement = .dateTime(FHIRPrimitiveFactory.dateTime(from: abatement))
        }

        return condition
    }

    private static func makeConditionClinicalStatus(resolved: Bool) -> CodeableConcept {
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(conditionClinicalSystem).asPrimitive()
        if resolved {
            coding.code = FHIRString("resolved").asPrimitive()
            coding.display = FHIRString("Resolved").asPrimitive()
        } else {
            coding.code = FHIRString("active").asPrimitive()
            coding.display = FHIRString("Active").asPrimitive()
        }
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    private static func makeConditionCategory() -> CodeableConcept {
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(conditionCategorySystem).asPrimitive()
        coding.code = FHIRString("problem-list-item").asPrimitive()
        coding.display = FHIRString("Problem List Item").asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    /// `Condition.verificationStatus = unconfirmed` — every episode is a patient
    /// self-log, never a clinician-confirmed diagnosis. Mirrors the server's
    /// guard rail (W-FHIR-CODING-CLEANUP, #30).
    private static func makeConditionVerificationStatus() -> CodeableConcept {
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(conditionVerStatusSystem).asPrimitive()
        coding.code = FHIRString("unconfirmed").asPrimitive()
        coding.display = FHIRString("Unconfirmed").asPrimitive()
        let concept = CodeableConcept()
        concept.coding = [coding]
        return concept
    }

    /// The patient-reported provenance note stamped on every Condition.
    static let patientReportedNote =
        "Patient-reported condition logged in HealthLog. The clinical category is a "
            + "self-reported classification, not a clinician-confirmed diagnosis."

    /// Map an `IllnessType` to the server's deterministic SNOMED-CT clinical
    /// category coding (enum→code, mirrored 1:1 from the server map — never a
    /// per-row guess). These are coarse category concepts, paired with the
    /// `unconfirmed` verificationStatus + patient-reported note so the Condition
    /// stays honest about its provenance.
    static func makeIllnessCategoryCoding(_ type: IllnessType) -> Coding {
        let (code, display) = switch type {
        case .infection: ("40733004", "Infectious disease")
        case .allergy: ("106190000", "Allergy")
        case .injury: ("417163006", "Traumatic or non-traumatic injury")
        case .mentalHealth: ("74732009", "Mental disorder")
        case .autoimmune: ("85828009", "Autoimmune disease")
        case .chronic: ("27624003", "Chronic disease")
        case .other: ("64572001", "Disease")
        }
        let coding = Coding()
        coding.system = FHIRPrimitiveFactory.uri(snomedSystem).asPrimitive()
        coding.code = FHIRString(code).asPrimitive()
        coding.display = FHIRString(display).asPrimitive()
        return coding
    }

    private static func illnessTypeDisplay(_ type: IllnessType) -> String {
        switch type {
        case .infection: "Infection"
        case .allergy: "Allergy"
        case .injury: "Injury"
        case .mentalHealth: "Mental health"
        case .autoimmune: "Autoimmune"
        case .chronic: "Chronic"
        case .other: "Condition"
        }
    }

    // MARK: - Illness day-log → supporting Observation(s)

    /// Supporting `Observation`s for one day-log: a functional-impact score
    /// and/or a body-temperature (fever) reading, each `focus`ed on the
    /// Condition. Returns an empty array when the day-log carries neither.
    static func makeDayLogObservations(
        dayLog: IllnessDayLogDTO,
        conditionID: String,
        patientID: String
    ) -> [Observation] {
        var result: [Observation] = []
        let conditionFocus = Reference(reference: FHIRString("Condition/\(conditionID)").asPrimitive())
        let subject = Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        let effective: Observation.EffectiveX? = parseDayKey(dayLog.date).map {
            .dateTime(FHIRPrimitiveFactory.dateTime(from: $0))
        }

        if let impact = dayLog.functionalImpact,
           let quantity = makeQuantity(value: Double(impact), ucum: UCUMUnit(unit: "{score}"))
        {
            let code = CodeableConcept()
            code.text = FHIRString("Functional impact (0–3)").asPrimitive()
            let obs = Observation(code: code, status: ObservationStatus.final.asPrimitive())
            obs.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()
            obs.category = [makeCategoryConcept(.activity)]
            obs.subject = subject
            obs.focus = [conditionFocus]
            obs.effective = effective
            obs.value = .quantity(quantity)
            result.append(obs)
        }

        if let feverC = dayLog.feverC,
           let quantity = makeQuantity(value: feverC, ucum: UCUMUnit(unit: "Cel"))
        {
            // Body temperature is a true LOINC vital sign even when logged as
            // part of an illness day — reuse the canonical body-temperature
            // mapping so a clinician sees it under the right code. AUD-4 M1: a
            // non-finite fever value drops the supporting observation.
            let mapping = MetricFHIRMapper.mapping(for: .bodyTemperature)
            let code = mapping.map { makeCodeableConcept(loinc: $0.loinc) } ?? {
                let c = CodeableConcept()
                c.text = FHIRString("Body temperature").asPrimitive()
                return c
            }()
            let obs = Observation(code: code, status: ObservationStatus.final.asPrimitive())
            obs.id = FHIRString(UUID().uuidString.lowercased()).asPrimitive()
            obs.category = [makeCategoryConcept(.vitalSigns)]
            obs.subject = subject
            obs.focus = [conditionFocus]
            obs.effective = effective
            obs.value = .quantity(quantity)
            result.append(obs)
        }

        return result
    }

    // MARK: - Date parsing

    /// Parse an ISO-8601 wire instant (with or without fractional seconds).
    /// Reuses the app's shared formatter pair so there is one parsing path.
    static func parseISO(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }

    /// Parse a `YYYY-MM-DD` day key into the local-noon `Date` (avoids the
    /// midnight-DST edge so the FHIR `dateTime` lands on the intended day).
    static func parseDayKey(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: raw) else {
            // A full ISO instant in the date field still parses via the shared path.
            return parseISO(raw)
        }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }
}
