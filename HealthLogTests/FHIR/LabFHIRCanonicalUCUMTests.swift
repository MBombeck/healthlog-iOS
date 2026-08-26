//
//  LabFHIRCanonicalUCUMTests.swift
//  HealthLogTests
//
//  v1.18.6 — M1 (canonical-UCUM stamping) coverage for the labs FHIR R4
//  mapper. Split out of `LabsIllnessFHIRTests` to keep that file under the
//  `file_length` budget.
//
//  M1: only genuinely UCUM-canonical units get a coded `Quantity.system` +
//  `code`; free-text / unknown units ride as `Quantity.unit` (display) only.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

/// Local fixtures for the canonical-UCUM / data-absent-reason suite.
private enum UCF {
    static func makeCover() -> DoctorReportSpec.Cover {
        DoctorReportSpec.Cover(
            patientName: "Anna Schmidt",
            periodStart: Date(timeIntervalSince1970: 1_700_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
            generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
            appVersion: "1.18.6",
            locale: .de
        )
    }

    static func makeSpec(labs: [LabResultDTO]) -> DoctorReportSpec {
        DoctorReportSpec(
            cover: makeCover(),
            vitals: nil,
            charts: nil,
            medications: nil,
            adherence: nil,
            mood: nil,
            labs: .init(results: labs),
            illnesses: nil,
            footer: .init(disclaimer: DoctorReportDisclaimer.de)
        )
    }

    static func makeLab(
        value: Double = 5.4,
        unit: String = "%"
    ) -> LabResultDTO {
        LabResultDTO(
            id: "lab-1",
            biomarkerId: nil,
            panel: nil,
            analyte: "HbA1c",
            value: value,
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

    static func firstObservation(in bundle: ModelsR4.Bundle) throws -> Observation {
        let entries = try #require(bundle.entry)
        let obs = entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        return try #require(obs.first)
    }
}

@Suite("DoctorReportToFHIRBundle — M1 canonical-UCUM stamping")
struct LabCanonicalUCUMTests {
    @Test("Canonical UCUM lab unit (mg/dL) gets a coded system + code")
    func canonicalUCUMIsCoded() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: UCF.makeSpec(labs: [UCF.makeLab(value: 180, unit: "mg/dL")]))
        let labObs = try UCF.firstObservation(in: bundle)
        guard case let .quantity(quantity) = labObs.value else {
            Issue.record("Expected valueQuantity")
            return
        }
        #expect(quantity.unit?.value?.string == "mg/dL")
        #expect(quantity.system?.value?.url.absoluteString == "http://unitsofmeasure.org")
        #expect(quantity.code?.value?.string == "mg/dL")
    }

    @Test("Free-text lab unit is unit-text only — no fabricated UCUM system/code")
    func freeTextUnitDropsSystemCode() throws {
        // A German panel label as a "unit" is not canonical UCUM.
        let bundle = try DoctorReportToFHIRBundle.bundle(from: UCF.makeSpec(labs: [UCF.makeLab(value: 1, unit: "Großes Blutbild")]))
        let labObs = try UCF.firstObservation(in: bundle)
        guard case let .quantity(quantity) = labObs.value else {
            Issue.record("Expected valueQuantity")
            return
        }
        #expect(quantity.unit?.value?.string == "Großes Blutbild")
        #expect(quantity.system == nil)
        #expect(quantity.code == nil)
    }

    @Test("Ad-hoc free-text unit 'x' drops system/code but keeps display text")
    func adHocUnitDropsSystemCode() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: UCF.makeSpec(labs: [UCF.makeLab(value: 3, unit: "x")]))
        let labObs = try UCF.firstObservation(in: bundle)
        guard case let .quantity(quantity) = labObs.value else {
            Issue.record("Expected valueQuantity")
            return
        }
        #expect(quantity.unit?.value?.string == "x")
        #expect(quantity.system == nil)
        #expect(quantity.code == nil)
    }

    @Test("Vitals quantity (mm[Hg]) stays canonical-coded — no M1 regression")
    func vitalsMmHgStaysCoded() throws {
        let quantity = try #require(
            DoctorReportToFHIRBundle.makeQuantity(value: 120, ucum: UCUMUnit(unit: "mm[Hg]"))
        )
        #expect(quantity.unit?.value?.string == "mm[Hg]")
        #expect(quantity.system?.value?.url.absoluteString == "http://unitsofmeasure.org")
        #expect(quantity.code?.value?.string == "mm[Hg]")
    }

    @Test("Empty unit → bare numeric Quantity (no unit/system/code)")
    func emptyUnitIsBareQuantity() throws {
        let quantity = try #require(
            DoctorReportToFHIRBundle.makeQuantity(value: 7, ucum: UCUMUnit(unit: ""))
        )
        #expect(quantity.unit == nil)
        #expect(quantity.system == nil)
        #expect(quantity.code == nil)
        #expect(quantity.value?.value?.decimal == Decimal(7))
    }

    // MARK: - AUD-4 M1 — non-finite value drops the Quantity

    @Test("Non-finite makeQuantity value returns nil (AUD-4 M1)")
    func nonFiniteQuantityIsNil() {
        #expect(DoctorReportToFHIRBundle.makeQuantity(value: .infinity, ucum: UCUMUnit(unit: "mg/dL")) == nil)
        #expect(DoctorReportToFHIRBundle.makeQuantity(value: .nan, ucum: UCUMUnit(unit: "mg/dL")) == nil)
        #expect(DoctorReportToFHIRBundle.makeQuantity(value: -.infinity, ucum: UCUMUnit(unit: "mg/dL")) == nil)
    }

    @Test("UCUMUnit.isCanonical allowlist covers common lab/vital units")
    func ucumIsCanonicalAllowlist() {
        let canonical = [
            "mg/dL", "mmol/L", "%", "mm[Hg]", "Cel", "/min", "g/dL",
            "U/L", "ng/mL", "pg/mL", "mmol/mol", "10*9/L", "kg"
        ]
        for unit in canonical {
            #expect(UCUMUnit(unit: unit).isCanonical, "Expected \(unit) canonical")
        }
        for unit in ["Großes Blutbild", "x", "MG/DL", "per minute", ""] {
            #expect(!UCUMUnit(unit: unit).isCanonical, "Expected \(unit) NON-canonical")
        }
    }
}
