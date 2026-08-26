//
//  MeasurementToFHIRObservationTests.swift
//  HealthLogTests
//
//  Created 2026-05-22 — v0.6.0 H.2 coverage for
//  `MeasurementToFHIRObservation`.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

@Suite("MeasurementToFHIRObservation — v0.6.0 H.2 mapper")
struct MeasurementToFHIRObservationTests {
    private let patientID = "patient-123"

    // MARK: - Helpers

    private func makeScalar(kind: MetricKind, value: Double, id: String = "m-1") -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: id,
            kind: kind,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(value),
            note: nil
        )
    }

    // MARK: - Spot kinds

    @Test("Weight measurement → Observation code 29463-7, value in kg")
    func weightMapping() throws {
        let measurement = makeScalar(kind: .weight, value: 82.5)
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: patientID))

        let coding = try #require(observation.code.coding?.first)
        #expect(coding.code?.value?.string == "29463-7")
        #expect(coding.system?.value?.url.absoluteString == "http://loinc.org")

        guard case let .quantity(quantity) = observation.value else {
            Issue.record("Expected .quantity value")
            return
        }
        #expect(quantity.value?.value?.decimal == Decimal(82.5))
        #expect(quantity.unit?.value?.string == "kg")
        #expect(quantity.code?.value?.string == "kg")
        #expect(quantity.system?.value?.url.absoluteString == "http://unitsofmeasure.org")
    }

    @Test("Pulse measurement → LOINC 8867-4, UCUM /min")
    func pulseMapping() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .pulse, value: 72), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.code?.value?.string == "8867-4")
        guard case let .quantity(q) = observation.value else { Issue.record("expected quantity")
            return
        }
        #expect(q.code?.value?.string == "/min")
    }

    @Test("Body-temperature → 8310-5, Cel")
    func bodyTempMapping() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .bodyTemperature, value: 36.8), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.code?.value?.string == "8310-5")
        guard case let .quantity(q) = observation.value else { Issue.record("expected quantity")
            return
        }
        #expect(q.code?.value?.string == "Cel")
    }

    @Test("Body-fat → 41982-0, %")
    func bodyFatMapping() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .bodyFat, value: 17.4), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.code?.value?.string == "41982-0")
        guard case let .quantity(q) = observation.value else { Issue.record("expected quantity")
            return
        }
        #expect(q.code?.value?.string == "%")
    }

    @Test("spO2 → 59408-5 (pulse-ox preferred)")
    func spo2Mapping() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .spo2, value: 97), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.code?.value?.string == "59408-5")
    }

    @Test("BMI → 39156-5, kg/m2")
    func bmiMapping() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .bmi, value: 24.1), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.code?.value?.string == "39156-5")
        guard case let .quantity(q) = observation.value else { Issue.record("expected quantity")
            return
        }
        #expect(q.code?.value?.string == "kg/m2")
    }

    @Test("Resting heart-rate is distinct from .pulse (40443-4 vs 8867-4)")
    func restingHeartRateMapping() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .restingHeartRate, value: 56), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.code?.value?.string == "40443-4")
    }

    // MARK: - Blood pressure

    @Test("BP emits ONE panel Observation (85354-9) with TWO components")
    func bloodPressurePanelComponents() throws {
        let measurement = HealthLog.Measurement(
            id: "bp-1",
            kind: .bloodPressure,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .bloodPressure(systolic: 134, diastolic: 86)
        )
        let observation = try #require(
            MeasurementToFHIRObservation.map(measurement, patientID: patientID)
        )

        // Top-level code = panel.
        #expect(observation.code.coding?.first?.code?.value?.string == "85354-9")

        // No top-level value — components carry it.
        #expect(observation.value == nil)

        let components = try #require(observation.component)
        #expect(components.count == 2)

        let systolic = components[0]
        let diastolic = components[1]
        #expect(systolic.code.coding?.first?.code?.value?.string == "8480-6")
        #expect(diastolic.code.coding?.first?.code?.value?.string == "8462-4")

        guard case let .quantity(sysQ) = systolic.value else { Issue.record("sys not quantity")
            return
        }
        guard case let .quantity(diaQ) = diastolic.value else { Issue.record("dia not quantity")
            return
        }
        #expect(sysQ.value?.value?.decimal == Decimal(134))
        #expect(diaQ.value?.value?.decimal == Decimal(86))
        #expect(sysQ.code?.value?.string == "mm[Hg]")
        #expect(diaQ.code?.value?.string == "mm[Hg]")
    }

    // MARK: - Glucose context

    @Test("Glucose w/ .fasting context → LOINC 1558-6")
    func glucoseFastingContext() throws {
        let measurement = HealthLog.Measurement(
            id: "g-1",
            kind: .glucose,
            recordedAt: Date(),
            value: .scalar(95),
            glucoseContext: .fasting
        )
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: patientID))
        #expect(observation.code.coding?.first?.code?.value?.string == "1558-6")
    }

    @Test("Glucose w/ .afterMeal context → LOINC 1521-4 (postprandial)")
    func glucoseAfterMealContext() throws {
        let measurement = HealthLog.Measurement(
            id: "g-2", kind: .glucose, recordedAt: Date(),
            value: .scalar(140), glucoseContext: .afterMeal
        )
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: patientID))
        #expect(observation.code.coding?.first?.code?.value?.string == "1521-4")
    }

    @Test("Glucose w/ no context → default LOINC 2339-0 (random)")
    func glucoseNoContext() throws {
        let measurement = HealthLog.Measurement(
            id: "g-3", kind: .glucose, recordedAt: Date(),
            value: .scalar(110), glucoseContext: nil
        )
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: patientID))
        #expect(observation.code.coding?.first?.code?.value?.string == "2339-0")
    }

    // MARK: - Subject + effectiveDateTime

    @Test("Subject reference uses Patient/<id> format")
    func subjectReference() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .weight, value: 70), patientID: "abc-42")
        )
        #expect(observation.subject?.reference?.value?.string == "Patient/abc-42")
    }

    @Test("effective preserves measurement.recordedAt timestamp")
    func effectiveDateTime() throws {
        let recorded = Date(timeIntervalSince1970: 1_700_000_000)
        let measurement = HealthLog.Measurement(
            id: "t-1", kind: .pulse, recordedAt: recorded,
            value: .scalar(70)
        )
        let observation = try #require(
            MeasurementToFHIRObservation.map(measurement, patientID: patientID)
        )
        guard case let .dateTime(dt) = observation.effective else {
            Issue.record("expected effective .dateTime")
            return
        }
        let decoded = try dt.value?.asNSDate()
        #expect(decoded?.timeIntervalSince1970 == recorded.timeIntervalSince1970)
    }

    // MARK: - Identifier + meta.profile + status

    @Test("Observation.identifier round-trips measurement.id")
    func identifierRoundTrips() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(
                makeScalar(kind: .weight, value: 70, id: "domain-id-42"),
                patientID: patientID
            )
        )
        #expect(observation.identifier?.first?.value?.value?.string == "domain-id-42")
    }

    @Test("Status is .final for spot measurements")
    func statusIsFinal() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .weight, value: 70), patientID: patientID)
        )
        #expect(observation.status.value == .final)
    }

    @Test("Vital-sign kinds carry meta.profile = vitalsigns URL")
    func vitalSignsProfileApplied() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .weight, value: 70), patientID: patientID)
        )
        let profiles = observation.meta?.profile?.compactMap(\.value?.url.absoluteString)
        #expect(profiles?.contains("http://hl7.org/fhir/StructureDefinition/vitalsigns") == true)
    }

    @Test("Non-vital-signs kinds (body-fat) skip vital-signs profile")
    func nonVitalSignsKindsOmitProfile() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .bodyFat, value: 18), patientID: patientID)
        )
        #expect(observation.meta?.profile == nil)
    }

    // MARK: - Observation.category (v0.11 audit B1)

    private func categoryCode(_ kind: MetricKind, value: Double = 1) throws -> (system: String?, code: String?) {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: kind, value: value), patientID: patientID)
        )
        let coding = try #require(observation.category?.first?.coding?.first)
        return (coding.system?.value?.url.absoluteString, coding.code?.value?.string)
    }

    @Test("Every Observation carries a category bound to the HL7 observation-category system")
    func categorySystemIsHL7() throws {
        let (system, code) = try categoryCode(.weight)
        #expect(system == "http://terminology.hl7.org/CodeSystem/observation-category")
        #expect(code == "vital-signs")
    }

    @Test(
        "Vital-sign kinds → category vital-signs",
        arguments: [
            MetricKind.weight, .bloodPressure, .pulse, .bodyTemperature,
            .spo2, .restingHeartRate, .respiratoryRate, .bmi, .hrv, .vo2Max
        ]
    )
    func vitalSignsCategory(_ kind: MetricKind) throws {
        let (_, code) = try categoryCode(kind)
        #expect(code == "vital-signs")
    }

    @Test("Glucose → category laboratory")
    func glucoseCategoryIsLaboratory() throws {
        let measurement = HealthLog.Measurement(
            id: "g-cat", kind: .glucose, recordedAt: Date(), value: .scalar(95)
        )
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: patientID))
        #expect(observation.category?.first?.coding?.first?.code?.value?.string == "laboratory")
    }

    @Test(
        "Activity kinds (steps / energy / distance / walking) → category activity",
        arguments: [
            MetricKind.steps, .sleep, .activeEnergy, .distanceWalkingRunning,
            .flightsClimbed, .walkingSpeed, .bodyFat
        ]
    )
    func activityCategory(_ kind: MetricKind) throws {
        let (_, code) = try categoryCode(kind)
        #expect(code == "activity")
    }

    // MARK: - Custom CodeSystem for HK-native codes (v0.11 audit B5)

    @Test(
        "HealthKit-native placeholder kinds do NOT emit a code in the loinc.org namespace",
        arguments: [
            MetricKind.walkingDoubleSupport, .audioExposureEnvironment, .audioExposureHeadphone,
            .flightsClimbed, .distanceWalkingRunning, .timeInDaylight
        ]
    )
    func hkNativeCodesUseCustomSystem(_ kind: MetricKind) throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: kind, value: 1), patientID: patientID)
        )
        let coding = try #require(observation.code.coding?.first)
        let system = coding.system?.value?.url.absoluteString
        #expect(system == "https://healthlog.dev/fhir/CodeSystem/healthkit")
        #expect(system != "http://loinc.org")
        // The code itself is the HK identifier, not a fake LOINC number.
        #expect(coding.code?.value?.string.hasPrefix("HKQuantityTypeIdentifier") == true)
    }

    @Test("Real LOINC kinds keep the loinc.org system")
    func realLOINCKindsKeepLOINCSystem() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .weight, value: 70), patientID: patientID)
        )
        #expect(observation.code.coding?.first?.system?.value?.url.absoluteString == "http://loinc.org")
    }

    // MARK: - JSON round-trip

    @Test("Observation encodes and decodes cleanly via FHIRModels JSON coder")
    func jsonRoundTrip() throws {
        let observation = try #require(
            MeasurementToFHIRObservation.map(makeScalar(kind: .weight, value: 82.5), patientID: patientID)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(observation)
        #expect(data.isEmpty == false)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Observation.self, from: data)
        #expect(decoded.code.coding?.first?.code?.value?.string == "29463-7")
        #expect(decoded.subject?.reference?.value?.string == "Patient/\(patientID)")
        #expect(decoded.status.value == .final)
    }

    @Test("BP Observation round-trips via FHIRModels JSON encoder with both components")
    func bpJsonRoundTrip() throws {
        let measurement = HealthLog.Measurement(
            id: "bp-rt",
            kind: .bloodPressure,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .bloodPressure(systolic: 120, diastolic: 80)
        )
        let observation = try #require(MeasurementToFHIRObservation.map(measurement, patientID: patientID))
        let data = try JSONEncoder().encode(observation)
        let decoded = try JSONDecoder().decode(Observation.self, from: data)
        #expect(decoded.component?.count == 2)
        #expect(decoded.component?[0].code.coding?.first?.code?.value?.string == "8480-6")
        #expect(decoded.component?[1].code.coding?.first?.code?.value?.string == "8462-4")
    }
}
