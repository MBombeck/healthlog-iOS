//
//  LabFHIRDataAbsentReasonTests.swift
//  HealthLogTests
//
//  v1.18.6 — M2: an absent lab value (server omitted the `value` key) emits
//  `Observation.dataAbsentReason` (HL7 data-absent-reason, code `unknown`)
//  instead of a misleading `valueQuantity: 0`. A genuine `0` (key present)
//  still emits `valueQuantity: 0`. The DTO distinguishes the two via the
//  off-wire `valueIsAbsent` flag set at decode time.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

/// Local fixtures for the data-absent-reason suite.
private enum DARF {
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
        value: Double?,
        valueText: String? = nil,
        unit: String
    ) -> LabResultDTO {
        LabResultDTO(
            id: "lab-1",
            biomarkerId: nil,
            panel: nil,
            analyte: "HbA1c",
            value: value,
            valueText: valueText,
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

@Suite("DoctorReportToFHIRBundle — M2 dataAbsentReason")
struct LabDataAbsentReasonTests {
    @Test("Absent lab value → dataAbsentReason unknown, no valueQuantity")
    func absentValueEmitsDataAbsentReason() throws {
        let lab = DARF.makeLab(value: nil, unit: "mg/dL")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: DARF.makeSpec(labs: [lab]))
        let labObs = try DARF.firstObservation(in: bundle)
        #expect(labObs.value == nil)
        let coding = try #require(labObs.dataAbsentReason?.coding?.first)
        #expect(coding.system?.value?.url.absoluteString
            == "http://terminology.hl7.org/CodeSystem/data-absent-reason")
        #expect(coding.code?.value?.string == "unknown")
    }

    @Test("Genuine 0 → valueQuantity 0, no dataAbsentReason")
    func genuineZeroEmitsValueQuantity() throws {
        let lab = DARF.makeLab(value: 0, unit: "mg/dL")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: DARF.makeSpec(labs: [lab]))
        let labObs = try DARF.firstObservation(in: bundle)
        #expect(labObs.dataAbsentReason == nil)
        guard case let .quantity(quantity) = labObs.value else {
            Issue.record("Expected valueQuantity for a genuine 0")
            return
        }
        #expect(quantity.value?.value?.decimal == Decimal(0))
    }

    @Test("Present non-zero value → valueQuantity, no dataAbsentReason")
    func presentValueEmitsValueQuantity() throws {
        let lab = DARF.makeLab(value: 5.4, unit: "%")
        let bundle = try DoctorReportToFHIRBundle.bundle(from: DARF.makeSpec(labs: [lab]))
        let labObs = try DARF.firstObservation(in: bundle)
        #expect(labObs.dataAbsentReason == nil)
        guard case .quantity = labObs.value else {
            Issue.record("Expected valueQuantity")
            return
        }
    }

    @Test("Decode: missing value key sets valueIsAbsent; present 0 does not")
    func decodeDistinguishesAbsentFromZero() throws {
        let absentJSON = #"{"id":"l1","analyte":"HbA1c","unit":"%","takenAt":"2023-12-01T08:30:00Z"}"#
        let absent = try JSONDecoder().decode(LabResultDTO.self, from: Data(absentJSON.utf8))
        #expect(absent.valueIsAbsent)
        #expect(absent.value == nil, "absence must never decode as a fabricated 0")

        let zeroJSON = #"{"id":"l2","analyte":"HbA1c","value":0,"unit":"%","takenAt":"2023-12-01T08:30:00Z"}"#
        let zero = try JSONDecoder().decode(LabResultDTO.self, from: Data(zeroJSON.utf8))
        #expect(!zero.valueIsAbsent)
        #expect(zero.value == 0)
    }

    @Test("Encode round-trip preserves value absence (omits the value key)")
    func encodeRoundTripPreservesAbsence() throws {
        let absent = DARF.makeLab(value: nil, unit: "%")
        let data = try JSONEncoder().encode(absent)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"value\""))
        let decoded = try JSONDecoder().decode(LabResultDTO.self, from: data)
        #expect(decoded.valueIsAbsent)
    }
}
