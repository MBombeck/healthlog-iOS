//
//  FHIRServerCodeAlignmentTests.swift
//  HealthLogTests
//
//  #115 R3 — the app's own FHIR exporter (doctor report → FHIR R4 document
//  bundle) aligned with the server's v1.39.3 code table (#115, section D).
//  The server checked its bundles with the HL7 validator against
//  tx.fhir.org; several of the old codes were commented there as matching
//  this exporter, and the validator rejects them or reads them as a
//  different measurement.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

@Suite("R3 — FHIR export codes match the server's v1.39.3 table")
struct FHIRServerCodeAlignmentTests {
    // MARK: - Fixtures

    private static let cover = DoctorReportSpec.Cover(
        patientName: "Anna Schmidt",
        periodStart: Date(timeIntervalSince1970: 1_700_000_000),
        periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
        generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
        appVersion: "1.1.0",
        locale: .de
    )

    private static func spec(
        rows: [DoctorReportSpec.VitalsSummary.Row],
        labs: DoctorReportSpec.LabsBlock? = nil,
        illnesses: DoctorReportSpec.IllnessBlock? = nil,
        medications: DoctorReportSpec.MedicationsBlock? = nil
    ) -> DoctorReportSpec {
        DoctorReportSpec(
            cover: cover,
            vitals: rows.isEmpty ? nil : DoctorReportSpec.VitalsSummary(rows: rows),
            charts: nil,
            medications: medications,
            adherence: nil,
            mood: nil,
            labs: labs,
            illnesses: illnesses,
            footer: .init(disclaimer: DoctorReportDisclaimer.de)
        )
    }

    private static func row(_ kind: MetricKind, _ value: Double = 50) -> DoctorReportSpec.VitalsSummary.Row {
        .init(
            kind: kind,
            mean: value,
            median: value,
            min: value,
            max: value,
            count: 3,
            secondaryMean: kind == .bloodPressure ? 80 : nil
        )
    }

    private static func linkedLab(_ analyte: String, unit: String) -> LabResultDTO {
        LabResultDTO(
            id: "lab-\(analyte)",
            biomarkerId: "bm-\(analyte)",
            panel: nil,
            analyte: analyte,
            value: 42,
            valueText: nil,
            unit: unit,
            referenceLow: nil,
            referenceHigh: nil,
            takenAt: "2023-12-01T08:30:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .unknown,
            createdAt: "2023-12-01T08:30:00Z",
            updatedAt: "2023-12-01T08:30:00Z"
        )
    }

    private static func observations(_ bundle: ModelsR4.Bundle) -> [Observation] {
        (bundle.entry ?? []).compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
    }

    /// One coding on `Observation.code`, flattened for assertions.
    private struct Flat {
        let system: String?
        let code: String?
        let display: String?
    }

    private static func codings(_ observation: Observation) -> [Flat] {
        (observation.code.coding ?? []).map {
            Flat(system: $0.system?.value?.url.absoluteString, code: $0.code?.value?.string, display: $0.display?.value?.string)
        }
    }

    private static let healthKitSystem = "https://healthlog.dev/fhir/CodeSystem/healthkit"
    private static let loincSystem = "http://loinc.org"

    // MARK: - Mapping table

    @Test("Body water and bone mass carry the LOINC body-composition codes")
    func bodyComposition() {
        let water = MetricFHIRMapper.mapping(for: .bodyWater)?.loinc
        #expect(water?.code == "101683-1")
        #expect(water?.display == "Body water mass")
        #expect(water?.system == .loinc)
        let bone = MetricFHIRMapper.mapping(for: .boneMass)?.loinc
        #expect(bone?.code == "101685-6")
        #expect(bone?.display == "Body bone mass")
        #expect(bone?.system == .loinc)
    }

    @Test("VO2 max and the walking trio are HealthKit identifiers, not invented LOINC", arguments: [
        (MetricKind.vo2Max, "HKQuantityTypeIdentifierVO2Max", "VO2 max (estimated)"),
        (.walkingSpeed, "HKQuantityTypeIdentifierWalkingSpeed", "Walking speed"),
        (.walkingAsymmetry, "HKQuantityTypeIdentifierWalkingAsymmetryPercentage", "Walking asymmetry percentage"),
        (.walkingStepLength, "HKQuantityTypeIdentifierWalkingStepLength", "Walking step length")
    ])
    func healthKitRows(kind: MetricKind, code: String, display: String) {
        let loinc = MetricFHIRMapper.mapping(for: kind)?.loinc
        #expect(loinc?.code == code)
        #expect(loinc?.display == display)
        #expect(loinc?.system == .healthKit)
        // Still a draft mapping for clinician review, like every HK row.
        #expect(loinc?.physicianReviewPending == true)
    }

    @Test("LDL is method-less 2089-1, vitamin D is total 25-OH D 62292-8")
    func labCodes() {
        let ldl = MetricFHIRMapper.labMapping(analyte: "LDL", unit: "mg/dL", isLinked: true).loinc
        #expect(ldl?.code == "2089-1")
        #expect(ldl?.display == "Cholesterol in LDL [Mass/volume] in Serum or Plasma")
        #expect(MetricFHIRMapper.labMapping(analyte: "LDL Cholesterol", unit: "mg/dL", isLinked: true).loinc?.code == "2089-1")
        let vitaminD = MetricFHIRMapper.labMapping(analyte: "Vitamin D", unit: "ng/mL", isLinked: true).loinc
        #expect(vitaminD?.code == "62292-8")
        #expect(vitaminD?.display == "25-Hydroxyvitamin D3+25-Hydroxyvitamin D2 [Mass/volume] in Serum or Plasma")
        #expect(MetricFHIRMapper.labMapping(analyte: "25-OH Vitamin D", unit: "ng/mL", isLinked: true).loinc?.code == "62292-8")
    }

    // MARK: - Bundle output

    @Test("Resting heart rate carries 40443-4 plus the vital-signs code 8867-4")
    func restingHeartRateMagicCode() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [Self.row(.restingHeartRate, 52)]))
        let observation = try #require(Self.observations(bundle).first)
        let codings = Self.codings(observation)
        #expect(codings.count == 2)
        #expect(codings.first?.code == "40443-4")
        #expect(codings.last?.system == Self.loincSystem)
        #expect(codings.last?.code == "8867-4")
        #expect(codings.last?.display == "Heart rate")
    }

    @Test("SpO2 carries 59408-5 plus the vital-signs code 2708-6")
    func spo2MagicCode() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [Self.row(.spo2, 97)]))
        let codings = try Self.codings(#require(Self.observations(bundle).first))
        #expect(codings.map(\.code) == ["59408-5", "2708-6"])
        #expect(codings.last?.display == "Oxygen saturation in Arterial blood")
    }

    @Test("Plain pulse keeps exactly one coding (no duplicate 8867-4)")
    func pulseSingleCoding() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [Self.row(.pulse, 64)]))
        let codings = try Self.codings(#require(Self.observations(bundle).first))
        #expect(codings.map(\.code) == ["8867-4"])
    }

    @Test("The per-measurement mapper emits the same companion coding")
    func measurementMapperCompanion() throws {
        let measurement = Measurement(id: "m1", kind: .spo2, recordedAt: .now, value: .scalar(97))
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: "p"))
        #expect(Self.codings(observation).map(\.code) == ["59408-5", "2708-6"])
    }

    @Test("An allergy Condition is SNOMED 473011001 'Allergic condition'")
    func allergySnomed() throws {
        let episode = IllnessEpisodeDTO(
            id: "ep-1", label: "Hay fever", type: .allergy, lifecycle: .acute,
            onsetAt: "2023-11-15T00:00:00Z", resolvedAt: nil, parentConditionId: nil,
            note: nil, createdAt: "2023-11-15T00:00:00Z", updatedAt: "2023-11-15T00:00:00Z"
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [], illnesses: .init(episodes: [episode])))
        let condition = try #require((bundle.entry ?? []).compactMap { entry -> Condition? in
            if case let .condition(c) = entry.resource { return c }
            return nil
        }.first)
        let snomed = try #require(condition.code?.coding?.first)
        #expect(snomed.code?.value?.string == "473011001")
        #expect(snomed.display?.value?.string == "Allergic condition")
        // The person's own words stay the text.
        #expect(condition.code?.text?.value?.string == "Hay fever")
        // No body site: the app's illness episodes carry none, so none is sent.
        #expect(condition.bodySite == nil)
    }

    @Test("A medication carries its name as text and no coding (no ATC display = the user's name)")
    func medicationTextOnly() throws {
        let meds = DoctorReportSpec.MedicationsBlock(
            active: [.init(id: "m1", name: "Lisinopril", dose: "5 mg", treatmentClass: nil, schedule: "daily")],
            archived: []
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [], medications: meds))
        let statement = try #require((bundle.entry ?? []).compactMap { entry -> MedicationStatement? in
            if case let .medicationStatement(s) = entry.resource { return s }
            return nil
        }.first)
        guard case let .codeableConcept(concept) = statement.medication else {
            Issue.record("expected a CodeableConcept medication")
            return
        }
        #expect(concept.text?.value?.string == "Lisinopril")
        #expect(concept.coding == nil)
    }

    @Test("Vitals present → exactly one vitals DiagnosticReport, routing them")
    func vitalsReportWhenVitals() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [Self.row(.weight, 80)]))
        let reports = (bundle.entry ?? []).compactMap { entry -> DiagnosticReport? in
            if case let .diagnosticReport(r) = entry.resource { return r }
            return nil
        }
        #expect(reports.count == 1)
        #expect(reports.first?.result?.count == 1)
    }

    @Test("Labs only → a lab report but no empty vitals report")
    func noVitalsReportForLabsOnly() throws {
        let labs = DoctorReportSpec.LabsBlock(results: [Self.linkedLab("LDL", unit: "mg/dL")])
        let bundle = try DoctorReportToFHIRBundle.bundle(from: Self.spec(rows: [], labs: labs))
        let codes = (bundle.entry ?? []).compactMap { entry -> String? in
            if case let .diagnosticReport(r) = entry.resource { return r.code.coding?.first?.code?.value?.string }
            return nil
        }
        #expect(codes == ["11502-2"])
    }

    /// Every code the server table retired, across a bundle that exports a row
    /// for every kind the app can export plus the affected labs and an allergy.
    @Test("No retired code survives anywhere in a full export")
    func noRetiredCodes() throws {
        let rows = MetricKind.allCases.filter { !$0.isUnknown }.map { Self.row($0) }
        let labs = DoctorReportSpec.LabsBlock(results: [
            Self.linkedLab("LDL", unit: "mg/dL"),
            Self.linkedLab("Vitamin D", unit: "ng/mL")
        ])
        let allergy = IllnessEpisodeDTO(
            id: "ep-a", label: "Pollen", type: .allergy, lifecycle: .acute,
            onsetAt: "2023-11-15T00:00:00Z", resolvedAt: nil, parentConditionId: nil,
            note: nil, createdAt: "2023-11-15T00:00:00Z", updatedAt: "2023-11-15T00:00:00Z"
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(
            from: Self.spec(rows: rows, labs: labs, illnesses: .init(episodes: [allergy]))
        )
        let json = try #require(try String(data: JSONEncoder().encode(bundle), encoding: .utf8))
        let retired = [
            "73704-9", "73708-0", "41955-6", "41957-2", "91557-1", "96402-2", // body comp, gait, VO2 max
            "76542-6", "41995-2", "64700-8", "64698-4", "97507-8", // mood, eA1C, cycle, mean glucose
            "18262-6", "13457-7", "1989-3", "33914-3", // LDL by method, vitamin D3 only, MDRD eGFR
            "106190000" // inactive allergy concept
        ]
        for code in retired {
            #expect(!json.contains("\"\(code)\""), "retired code \(code) is still exported")
        }
        // And the replacements are there.
        for code in ["101683-1", "101685-6", "2089-1", "62292-8", "473011001", "8867-4", "2708-6"] {
            #expect(json.contains("\"\(code)\""), "\(code) missing from the export")
        }
    }
}
