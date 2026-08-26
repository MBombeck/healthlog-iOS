//
//  LabsIllnessFHIRTests.swift
//  HealthLogTests
//
//  v1.18.1 — coverage for the labs + illness FHIR R4 mappers added to
//  `DoctorReportToFHIRBundle` (lab Observation, illness Condition, day-log
//  supporting Observations, gating, bundle well-formedness). Mirrors the
//  `DoctorReportToFHIRBundleTests` idiom.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

/// Shared fixtures + resource extractors for the labs/illness FHIR suites,
/// lifted out of the test structs so each suite body stays under the
/// `type_body_length` budget.
private enum LIF {
    static func makeCover() -> DoctorReportSpec.Cover {
        DoctorReportSpec.Cover(
            patientName: "Anna Schmidt",
            periodStart: Date(timeIntervalSince1970: 1_700_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
            generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
            appVersion: "1.18.1",
            locale: .de
        )
    }

    static func makeSpec(
        labs: DoctorReportSpec.LabsBlock? = nil,
        illnesses: DoctorReportSpec.IllnessBlock? = nil
    ) -> DoctorReportSpec {
        DoctorReportSpec(
            cover: makeCover(),
            vitals: nil,
            charts: nil,
            medications: nil,
            adherence: nil,
            mood: nil,
            labs: labs,
            illnesses: illnesses,
            footer: .init(disclaimer: DoctorReportDisclaimer.de)
        )
    }

    static func makeLab(
        id: String = "lab-1",
        biomarkerId: String? = nil,
        analyte: String = "HbA1c",
        value: Double? = 5.4,
        valueText: String? = nil,
        unit: String = "%",
        referenceLow: Double? = 4.0,
        referenceHigh: Double? = 6.0,
        rangeStatus: LabRangeStatus = .inRange
    ) -> LabResultDTO {
        LabResultDTO(
            id: id,
            biomarkerId: biomarkerId,
            panel: nil,
            analyte: analyte,
            value: value,
            valueText: valueText,
            unit: unit,
            referenceLow: referenceLow,
            referenceHigh: referenceHigh,
            takenAt: "2023-12-01T08:30:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: rangeStatus,
            createdAt: "2023-12-01T08:30:00Z",
            updatedAt: "2023-12-01T08:30:00Z"
        )
    }

    static func makeEpisode(
        id: String = "ep-1",
        label: String = "Common cold",
        type: IllnessType = .infection,
        lifecycle: IllnessLifecycle = .acute,
        onsetAt: String = "2023-11-15T00:00:00Z",
        resolvedAt: String? = nil
    ) -> IllnessEpisodeDTO {
        IllnessEpisodeDTO(
            id: id,
            label: label,
            type: type,
            lifecycle: lifecycle,
            onsetAt: onsetAt,
            resolvedAt: resolvedAt,
            parentConditionId: nil,
            note: nil,
            createdAt: onsetAt,
            updatedAt: onsetAt
        )
    }

    static func observations(in bundle: ModelsR4.Bundle) throws -> [Observation] {
        let entries = try #require(bundle.entry)
        return entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
    }

    static func conditions(in bundle: ModelsR4.Bundle) throws -> [Condition] {
        let entries = try #require(bundle.entry)
        return entries.compactMap { entry -> Condition? in
            if case let .condition(c) = entry.resource { return c }
            return nil
        }
    }
}

@Suite("DoctorReportToFHIRBundle — v1.18.1 labs")
struct LabsFHIRTests {
    private func makeSpec(labs: DoctorReportSpec.LabsBlock? = nil) -> DoctorReportSpec {
        LIF.makeSpec(labs: labs)
    }

    private func makeLab(
        id: String = "lab-1",
        biomarkerId: String? = nil,
        analyte: String = "HbA1c",
        value: Double? = 5.4,
        valueText: String? = nil,
        unit: String = "%",
        referenceLow: Double? = 4.0,
        referenceHigh: Double? = 6.0,
        rangeStatus: LabRangeStatus = .inRange
    ) -> LabResultDTO {
        LIF.makeLab(
            id: id, biomarkerId: biomarkerId, analyte: analyte, value: value,
            valueText: valueText, unit: unit, referenceLow: referenceLow,
            referenceHigh: referenceHigh, rangeStatus: rangeStatus
        )
    }

    private func observations(in bundle: ModelsR4.Bundle) throws -> [Observation] {
        try LIF.observations(in: bundle)
    }

    // MARK: - Labs → Observation

    @Test("Linked biomarker lab with known analyte uses the LOINC code path")
    func linkedLabUsesLOINC() throws {
        let lab = makeLab(biomarkerId: "bm-hba1c", analyte: "HbA1c")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
        let labObs = try #require(try observations(in: bundle).first)

        // LOINC coding present, category laboratory.
        let coding = try #require(labObs.code.coding?.first)
        #expect(coding.system?.value?.url.absoluteString == "http://loinc.org")
        #expect(coding.code?.value?.string == "4548-4") // HbA1c LOINC
        let category = try #require(labObs.category?.first?.coding?.first)
        #expect(category.code?.value?.string == "laboratory")
    }

    @Test("Free-text (unlinked) lab degrades to a text-only Observation (no coding)")
    func freeTextLabIsTextOnly() throws {
        let lab = makeLab(biomarkerId: nil, analyte: "Some niche marker")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
        let labObs = try #require(try observations(in: bundle).first)

        // No coding — text only.
        #expect(labObs.code.coding == nil)
        #expect(labObs.code.text?.value?.string == "Some niche marker")
    }

    @Test("Linked lab with an unknown analyte name still degrades to text-only")
    func linkedUnknownAnalyteIsTextOnly() throws {
        let lab = makeLab(biomarkerId: "bm-x", analyte: "Proprietary index")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
        let labObs = try #require(try observations(in: bundle).first)
        #expect(labObs.code.coding == nil)
        #expect(labObs.code.text?.value?.string == "Proprietary index")
    }

    @Test("Dropped speculative analyte (sodium) now degrades to honest text-only")
    func droppedSpeculativeAnalyteIsTextOnly() throws {
        // `sodium`/`natrium`, `potassium`/`kalium`, `ft3`/`ft4`, `vitamin b12`
        // and generic `glucose` were dropped from the curated table (the server
        // does not map them) — even a LINKED row degrades to text-only now.
        for analyte in ["Sodium", "Natrium", "Potassium", "Glucose", "ft3", "Vitamin B12"] {
            let lab = makeLab(biomarkerId: "bm-x", analyte: analyte, unit: "mmol/L")
            let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
            let labObs = try #require(try observations(in: bundle).first)
            #expect(labObs.code.coding == nil, "\(analyte) should no longer carry a LOINC coding")
            #expect(labObs.code.text?.value?.string == analyte)
        }
    }

    @Test("Lab valueQuantity carries value + unit (UCUM system)")
    func labValueQuantity() throws {
        let lab = makeLab(value: 5.4, unit: "%")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
        let labObs = try #require(try observations(in: bundle).first)
        guard case let .quantity(quantity) = labObs.value else {
            Issue.record("Expected valueQuantity")
            return
        }
        #expect(quantity.value?.value?.decimal == Decimal(5.4))
        #expect(quantity.unit?.value?.string == "%")
        #expect(quantity.system?.value?.url.absoluteString == "http://unitsofmeasure.org")
    }

    @Test("Lab referenceRange reflects referenceLow/High")
    func labReferenceRange() throws {
        let lab = makeLab(referenceLow: 4.0, referenceHigh: 6.0)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
        let labObs = try #require(try observations(in: bundle).first)
        let range = try #require(labObs.referenceRange?.first)
        #expect(range.low?.value?.value?.decimal == Decimal(4.0))
        #expect(range.high?.value?.value?.decimal == Decimal(6.0))
    }

    @Test("Lab with no bounds emits no referenceRange")
    func labNoBoundsNoRange() throws {
        let lab = makeLab(referenceLow: nil, referenceHigh: nil, rangeStatus: .unknown)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
        let labObs = try #require(try observations(in: bundle).first)
        #expect(labObs.referenceRange == nil)
    }

    @Test("interpretation renders the server verdict — in-range→N, below→L, above→H")
    func labInterpretationFromRangeStatus() throws {
        let cases: [(LabRangeStatus, String?)] = [
            (.inRange, "N"),
            (.below, "L"),
            (.above, "H"),
            (.unknown, nil)
        ]
        for (status, expectedCode) in cases {
            let lab = makeLab(rangeStatus: status)
            let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: .init(results: [lab])))
            let labObs = try #require(try observations(in: bundle).first)
            if let expectedCode {
                let coding = try #require(labObs.interpretation?.first?.coding?.first)
                #expect(coding.code?.value?.string == expectedCode)
                #expect(coding.system?.value?.url.absoluteString
                    == "http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation")
            } else {
                #expect(labObs.interpretation == nil)
            }
        }
    }

    @Test("Lab DiagnosticReport groups every lab Observation as result[]")
    func labDiagnosticReportGroups() throws {
        let labs = DoctorReportSpec.LabsBlock(results: [
            makeLab(id: "lab-1", analyte: "HbA1c"),
            makeLab(id: "lab-2", analyte: "Cholesterol", value: 180, unit: "mg/dL")
        ])
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: labs))
        let entries = try #require(bundle.entry)
        let reports = entries.compactMap { entry -> DiagnosticReport? in
            if case let .diagnosticReport(r) = entry.resource { return r }
            return nil
        }
        let labReport = try #require(reports.first { $0.code.coding?.first?.code?.value?.string == "11502-2" })
        #expect(labReport.result?.count == 2)
        #expect(labReport.category?.first?.coding?.first?.code?.value?.string == "laboratory")
    }
}

@Suite("DoctorReportToFHIRBundle — v1.18.1 illness + sections + gating")
struct IllnessFHIRTests {
    private func makeSpec(
        labs: DoctorReportSpec.LabsBlock? = nil,
        illnesses: DoctorReportSpec.IllnessBlock? = nil
    ) -> DoctorReportSpec {
        LIF.makeSpec(labs: labs, illnesses: illnesses)
    }

    private func makeLab(
        id: String = "lab-1",
        analyte: String = "HbA1c",
        value: Double = 5.4,
        unit: String = "%",
        rangeStatus: LabRangeStatus = .inRange
    ) -> LabResultDTO {
        LIF.makeLab(id: id, analyte: analyte, value: value, unit: unit, rangeStatus: rangeStatus)
    }

    private func makeEpisode(
        id: String = "ep-1",
        label: String = "Common cold",
        type: IllnessType = .infection,
        lifecycle: IllnessLifecycle = .acute,
        onsetAt: String = "2023-11-15T00:00:00Z",
        resolvedAt: String? = nil
    ) -> IllnessEpisodeDTO {
        LIF.makeEpisode(
            id: id, label: label, type: type, lifecycle: lifecycle,
            onsetAt: onsetAt, resolvedAt: resolvedAt
        )
    }

    private func observations(in bundle: ModelsR4.Bundle) throws -> [Observation] {
        try LIF.observations(in: bundle)
    }

    private func conditions(in bundle: ModelsR4.Bundle) throws -> [Condition] {
        try LIF.conditions(in: bundle)
    }

    // MARK: - Illness → Condition

    @Test("Open episode → Condition clinicalStatus active, onsetDateTime, no abatement")
    func openEpisodeActive() throws {
        let episode = makeEpisode(resolvedAt: nil)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(illnesses: .init(episodes: [episode])))
        let condition = try #require(try conditions(in: bundle).first)

        let clinical = try #require(condition.clinicalStatus?.coding?.first)
        #expect(clinical.code?.value?.string == "active")
        #expect(clinical.system?.value?.url.absoluteString
            == "http://terminology.hl7.org/CodeSystem/condition-clinical")
        // onset present, abatement absent.
        guard case .dateTime = condition.onset else {
            Issue.record("Expected onsetDateTime")
            return
        }
        #expect(condition.abatement == nil)
        // category problem-list-item; code text = label.
        #expect(condition.category?.first?.coding?.first?.code?.value?.string == "problem-list-item")
        #expect(condition.code?.text?.value?.string == "Common cold")

        // SNOMED clinical-category coding carried ALONGSIDE the retained text.
        let snomed = try #require(condition.code?.coding?.first)
        #expect(snomed.system?.value?.url.absoluteString == "http://snomed.info/sct")
        #expect(snomed.code?.value?.string == "40733004") // INFECTION

        // verificationStatus unconfirmed (patient self-log guard rail).
        let verification = try #require(condition.verificationStatus?.coding?.first)
        #expect(verification.code?.value?.string == "unconfirmed")
        #expect(verification.system?.value?.url.absoluteString
            == "http://terminology.hl7.org/CodeSystem/condition-ver-status")

        // patient-reported provenance note present.
        let note = try #require(condition.note?.first?.text.value?.string)
        #expect(note.contains("Patient-reported"))
    }

    @Test("Condition SNOMED category coding follows the server's deterministic IllnessType map")
    func conditionSNOMEDCategoryMap() throws {
        let cases: [(IllnessType, String)] = [
            (.infection, "40733004"),
            (.allergy, "106190000"),
            (.injury, "417163006"),
            (.mentalHealth, "74732009"),
            (.autoimmune, "85828009"),
            (.chronic, "27624003"),
            (.other, "64572001")
        ]
        for (type, expectedCode) in cases {
            let episode = makeEpisode(label: "X", type: type)
            let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(illnesses: .init(episodes: [episode])))
            let condition = try #require(try conditions(in: bundle).first)
            let snomed = try #require(condition.code?.coding?.first)
            #expect(snomed.system?.value?.url.absoluteString == "http://snomed.info/sct")
            #expect(snomed.code?.value?.string == expectedCode, "\(type) → \(expectedCode)")
            // Free-text label is still carried alongside the coding.
            #expect(condition.code?.text?.value?.string == "X")
        }
    }

    @Test("Resolved episode → Condition clinicalStatus resolved + abatementDateTime")
    func resolvedEpisodeResolved() throws {
        let episode = makeEpisode(resolvedAt: "2023-11-25T00:00:00Z")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(illnesses: .init(episodes: [episode])))
        let condition = try #require(try conditions(in: bundle).first)
        #expect(condition.clinicalStatus?.coding?.first?.code?.value?.string == "resolved")
        guard case .dateTime = condition.abatement else {
            Issue.record("Expected abatementDateTime on a resolved episode")
            return
        }
    }

    @Test("Empty episode label falls back to a type display in code.text")
    func emptyLabelUsesTypeDisplay() throws {
        let episode = makeEpisode(label: "", type: .allergy)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(illnesses: .init(episodes: [episode])))
        let condition = try #require(try conditions(in: bundle).first)
        #expect(condition.code?.text?.value?.string == "Allergy")
    }

    @Test("Day-logs become supporting Observations focused on the Condition")
    func dayLogSupportingObservations() throws {
        let episode = makeEpisode()
        let dayLog = IllnessDayLogDTO(
            id: "dl-1",
            episodeId: episode.id,
            date: "2023-11-16",
            functionalImpact: 2,
            feverC: 38.5,
            symptoms: [],
            note: nil,
            updatedAt: "2023-11-16T00:00:00Z"
        )
        let block = DoctorReportSpec.IllnessBlock(
            episodes: [episode],
            dayLogsByEpisode: [episode.id: [dayLog]]
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(illnesses: block))
        let condition = try #require(try conditions(in: bundle).first)
        let conditionID = try #require(condition.id?.value?.string)

        // Two supporting Observations (functional impact + fever), both focused.
        let obs = try observations(in: bundle)
        #expect(obs.count == 2)
        for o in obs {
            let focus = try #require(o.focus?.first?.reference?.value?.string)
            #expect(focus == "Condition/\(conditionID)")
        }
        // Fever uses the body-temperature LOINC.
        let fever = try #require(obs.first { $0.code.coding?.first?.code?.value?.string == "8310-5" })
        guard case let .quantity(q) = fever.value else {
            Issue.record("Expected fever valueQuantity")
            return
        }
        #expect(q.unit?.value?.string == "Cel")
    }

    @Test("Day-log with no impact + no fever yields no supporting Observation")
    func emptyDayLogNoObservation() throws {
        let episode = makeEpisode()
        let dayLog = IllnessDayLogDTO(
            id: "dl-empty",
            episodeId: episode.id,
            date: "2023-11-16",
            functionalImpact: nil,
            feverC: nil,
            symptoms: [],
            note: nil,
            updatedAt: "2023-11-16T00:00:00Z"
        )
        let block = DoctorReportSpec.IllnessBlock(
            episodes: [episode],
            dayLogsByEpisode: [episode.id: [dayLog]]
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(illnesses: block))
        #expect(try observations(in: bundle).isEmpty)
    }

    // MARK: - Composition sections

    @Test("Composition carries Laboratory + Conditions sections when present")
    func compositionSections() throws {
        let spec = makeSpec(
            labs: .init(results: [makeLab()]),
            illnesses: .init(episodes: [makeEpisode()])
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let entries = try #require(bundle.entry)
        let composition = try #require(entries.compactMap { entry -> Composition? in
            if case let .composition(c) = entry.resource { return c }
            return nil
        }.first)
        let sections = try #require(composition.section)
        #expect(sections.contains { $0.title?.value?.string == "Laboratory" })
        #expect(sections.contains { $0.title?.value?.string == "Conditions" })
    }

    // MARK: - Gating (absent when block nil)

    @Test("No labs/illness blocks → no lab Observation, no Condition, no lab report, no sections")
    func gatingAbsent() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(labs: nil, illnesses: nil))
        #expect(try observations(in: bundle).isEmpty)
        #expect(try conditions(in: bundle).isEmpty)

        let entries = try #require(bundle.entry)
        // Only one DiagnosticReport (the vitals one) — no lab report.
        let reports = entries.compactMap { entry -> DiagnosticReport? in
            if case let .diagnosticReport(r) = entry.resource { return r }
            return nil
        }
        #expect(reports.count == 1)

        let composition = try #require(entries.compactMap { entry -> Composition? in
            if case let .composition(c) = entry.resource { return c }
            return nil
        }.first)
        let sections = composition.section ?? []
        #expect(!sections.contains { $0.title?.value?.string == "Laboratory" })
        #expect(!sections.contains { $0.title?.value?.string == "Conditions" })
    }

    // MARK: - Bundle well-formedness

    @Test("Every lab + day-log Observation references the bundle Patient + carries an effective date")
    func observationsWellFormed() throws {
        let episode = makeEpisode()
        let dayLog = IllnessDayLogDTO(
            id: "dl-1", episodeId: episode.id, date: "2023-11-16",
            functionalImpact: 1, feverC: nil, symptoms: [], note: nil,
            updatedAt: "2023-11-16T00:00:00Z"
        )
        let spec = makeSpec(
            labs: .init(results: [makeLab()]),
            illnesses: .init(episodes: [episode], dayLogsByEpisode: [episode.id: [dayLog]])
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let entries = try #require(bundle.entry)
        let patient = try #require(entries.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }.first)
        let patientID = try #require(patient.id?.value?.string)

        for obs in try observations(in: bundle) {
            #expect(obs.subject?.reference?.value?.string == "Patient/\(patientID)")
            switch obs.effective {
            case .dateTime, .period: break
            default: Issue.record("Observation has no effective date")
            }
        }
    }

    @Test("JSON round-trip preserves lab Observations + Conditions")
    func jsonRoundTrip() throws {
        let spec = makeSpec(
            labs: .init(results: [
                makeLab(id: "lab-1"),
                makeLab(id: "lab-2", analyte: "LDL", value: 120, unit: "mg/dL", rangeStatus: .above)
            ]),
            illnesses: .init(episodes: [makeEpisode(), makeEpisode(id: "ep-2", resolvedAt: "2023-12-01T00:00:00Z")])
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        let decoded = try JSONDecoder().decode(Bundle.self, from: data)

        #expect(decoded.type.value == .document)
        let labObs = try observations(in: decoded)
        #expect(labObs.count == 2)
        #expect(try conditions(in: decoded).count == 2)
    }
}
