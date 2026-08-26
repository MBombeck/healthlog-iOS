//
//  MedicationToFHIRStatementTests.swift
//  HealthLogTests
//
//  Created 2026-05-22 — v0.6.0 H.3 coverage for `MedicationToFHIRStatement`.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

// Disambiguate the domain type from `ModelsR4.Medication` — both modules
// are re-exported via `@testable import HealthLog`, and unqualified
// `Medication` becomes ambiguous in the test target.
private typealias HLMedication = HealthLog.Medication
private typealias HLMedicationSchedule = HealthLog.MedicationSchedule
private typealias HLTimeOfDay = HealthLog.TimeOfDay
private typealias HLWeekday = HealthLog.Weekday

@Suite("MedicationToFHIRStatement — v0.6.0 H.3 mapper")
struct MedicationToFHIRStatementTests {
    // MARK: - Fixtures

    private func makeMed(
        id: String = "med-1",
        name: String = "Aspirin",
        dose: String = "100 mg",
        times: [HLTimeOfDay] = [HLTimeOfDay(hour: 8, minute: 0)],
        weekdays: Set<HLWeekday>? = nil,
        intervalWeeks: Int = 1,
        archivedAt: Date? = nil
    ) -> HLMedication {
        HLMedication(
            id: id,
            name: name,
            dose: dose,
            schedule: HLMedicationSchedule(times: times, weekdays: weekdays, intervalWeeks: intervalWeeks),
            archivedAt: archivedAt
        )
    }

    // MARK: - Status + Subject

    @Test("Active medication (archivedAt == nil) → status .active, no effectivePeriod")
    func activeMedication() {
        let med = makeMed(archivedAt: nil)
        let statement = MedicationToFHIRStatement.map(med, patientID: "p-1")

        #expect(statement.status.value == .active)
        #expect(statement.effective == nil)
    }

    @Test("Archived medication → status .completed + effectivePeriod.end")
    func archivedMedication() {
        let archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let med = makeMed(archivedAt: archivedAt)
        let statement = MedicationToFHIRStatement.map(med, patientID: "p-1")

        #expect(statement.status.value == .completed)
        guard case let .period(period)? = statement.effective else {
            Issue.record("Expected effective = .period(...)")
            return
        }
        #expect(period.start == nil)
        #expect(period.end != nil)
    }

    @Test("subject reference is Patient/<id>")
    func subjectReferenceFormat() {
        let statement = MedicationToFHIRStatement.map(makeMed(), patientID: "abc-42")
        #expect(statement.subject.reference?.value?.string == "Patient/abc-42")
    }

    @Test("medication.codeableConcept.text = Medication.name")
    func medicationName() {
        let statement = MedicationToFHIRStatement.map(makeMed(name: "Metformin"), patientID: "p")
        guard case let .codeableConcept(concept) = statement.medication else {
            Issue.record("Expected medication = .codeableConcept(...)")
            return
        }
        #expect(concept.text?.value?.string == "Metformin")
    }

    @Test("identifier carries the Medication.id")
    func identifierFromMedicationID() throws {
        let statement = MedicationToFHIRStatement.map(makeMed(id: "med-xyz"), patientID: "p")
        let identifier = try #require(statement.identifier?.first)
        #expect(identifier.value?.value?.string == "med-xyz")
    }

    // MARK: - Timing — daily

    @Test("Daily med (intervalWeeks=1, weekdays=nil) → period 1d, frequency = times.count")
    func dailyTiming() throws {
        let med = makeMed(
            times: [HLTimeOfDay(hour: 8, minute: 0), HLTimeOfDay(hour: 20, minute: 0)],
            weekdays: nil,
            intervalWeeks: 1
        )
        let statement = MedicationToFHIRStatement.map(med, patientID: "p")
        let dosage = try #require(statement.dosage?.first)
        let timing = try #require(dosage.timing)
        let repeatComp = try #require(timing.repeat)

        #expect(repeatComp.dayOfWeek == nil)
        #expect(repeatComp.frequency?.value?.integer == 2)
        #expect(repeatComp.period?.value?.decimal == 1)
        #expect(repeatComp.periodUnit?.value?.string == "d")
    }

    @Test("Multi-dose-per-day → timeOfDay has all entries (08:00, 20:00)")
    func multiDosePerDay() throws {
        let med = makeMed(times: [HLTimeOfDay(hour: 8, minute: 0), HLTimeOfDay(hour: 20, minute: 0)])
        let statement = MedicationToFHIRStatement.map(med, patientID: "p")
        let dosage = try #require(statement.dosage?.first)
        let repeatComp = try #require(dosage.timing?.repeat)
        let times = try #require(repeatComp.timeOfDay).compactMap(\.value)

        #expect(times.count == 2)
        #expect(times[0].hour == 8 && times[0].minute == 0)
        #expect(times[1].hour == 20 && times[1].minute == 0)
    }

    // MARK: - Timing — weekly + bi-weekly

    @Test("Weekly med (weekdays = [mon, thu]) → dayOfWeek correctly mapped in Mon→Sun order")
    func weeklyDayOfWeek() throws {
        let med = makeMed(weekdays: [.mon, .thu], intervalWeeks: 1)
        let statement = MedicationToFHIRStatement.map(med, patientID: "p")
        let repeatComp = try #require(statement.dosage?.first?.timing?.repeat)
        let days = try #require(repeatComp.dayOfWeek).compactMap(\.value)

        #expect(days == [.mon, .thu])
    }

    @Test("Weekday sort follows FHIR Mon→Sun (sun is last even though raw=0)")
    func weekdaySortOrder() throws {
        let med = makeMed(weekdays: [.sun, .mon, .fri])
        let statement = MedicationToFHIRStatement.map(med, patientID: "p")
        let days = try #require(statement.dosage?.first?.timing?.repeat?.dayOfWeek).compactMap(\.value)
        #expect(days == [.mon, .fri, .sun])
    }

    @Test("Bi-weekly med (intervalWeeks=2) → period 14 days")
    func biWeeklyPeriod() throws {
        let med = makeMed(intervalWeeks: 2)
        let statement = MedicationToFHIRStatement.map(med, patientID: "p")
        let repeatComp = try #require(statement.dosage?.first?.timing?.repeat)
        #expect(repeatComp.period?.value?.decimal == 14)
        #expect(repeatComp.periodUnit?.value?.string == "d")
    }

    @Test("intervalWeeks=4 → period 28 days")
    func monthlyIshPeriod() throws {
        let med = makeMed(intervalWeeks: 4)
        let statement = MedicationToFHIRStatement.map(med, patientID: "p")
        let repeatComp = try #require(statement.dosage?.first?.timing?.repeat)
        #expect(repeatComp.period?.value?.decimal == 28)
    }

    // MARK: - Dose parser

    @Test("parseDose '5mg' → 5 mg")
    func parseDoseSimpleMg() throws {
        let q = try #require(MedicationToFHIRStatement.parseDose("5mg"))
        #expect(q.value?.value?.decimal == 5)
        #expect(q.code?.value?.string == "mg")
        #expect(q.unit?.value?.string == "mg")
    }

    @Test("parseDose '10 mg' (whitespace) → 10 mg")
    func parseDoseWhitespace() throws {
        let q = try #require(MedicationToFHIRStatement.parseDose("10 mg"))
        #expect(q.value?.value?.decimal == 10)
        #expect(q.code?.value?.string == "mg")
    }

    @Test("parseDose '5.5mg' → 5.5 mg")
    func parseDoseDecimal() throws {
        let q = try #require(MedicationToFHIRStatement.parseDose("5.5mg"))
        #expect(q.value?.value?.decimal == 5.5)
    }

    @Test("parseDose '5,5 mg' (German decimal) → 5.5 mg")
    func parseDoseGermanDecimal() throws {
        let q = try #require(MedicationToFHIRStatement.parseDose("5,5 mg"))
        #expect(q.value?.value?.decimal == 5.5)
    }

    @Test("parseDose '100 mcg' → 100 ug (UCUM-canonical)")
    func parseDoseMicrogram() throws {
        let q = try #require(MedicationToFHIRStatement.parseDose("100 mcg"))
        #expect(q.value?.value?.decimal == 100)
        #expect(q.code?.value?.string == "ug")
    }

    @Test("parseDose '1 tablet' → nil (no UCUM unit recognised)")
    func parseDoseUnknownUnit() {
        #expect(MedicationToFHIRStatement.parseDose("1 tablet") == nil)
    }

    @Test("parseDose 'two tablets' → nil (no numeric prefix)")
    func parseDoseNonNumeric() {
        #expect(MedicationToFHIRStatement.parseDose("two tablets") == nil)
    }

    @Test("parseDose '' → nil")
    func parseDoseEmpty() {
        #expect(MedicationToFHIRStatement.parseDose("") == nil)
    }

    // MARK: - Dosage text fallback

    @Test("Even when dose parses, dosage.text mirrors the human-readable string")
    func dosageTextAlwaysPresent() throws {
        let statement = MedicationToFHIRStatement.map(makeMed(dose: "10 mg"), patientID: "p")
        let dosage = try #require(statement.dosage?.first)
        #expect(dosage.text?.value?.string == "10 mg")
        let doseAndRate = try #require(dosage.doseAndRate?.first)
        guard case .quantity = doseAndRate.dose else {
            Issue.record("Expected dose = .quantity(...)")
            return
        }
    }

    @Test("Unparseable dose '1 tablet' → only text fallback, no doseAndRate")
    func dosageTextOnlyFallback() throws {
        let statement = MedicationToFHIRStatement.map(makeMed(dose: "1 tablet"), patientID: "p")
        let dosage = try #require(statement.dosage?.first)
        #expect(dosage.text?.value?.string == "1 tablet")
        #expect(dosage.doseAndRate == nil)
    }

    // MARK: - JSON round-trip

    @Test("MedicationStatement encodes + decodes cleanly via FHIRModels JSON coder")
    func jsonRoundTrip() throws {
        let med = makeMed(
            id: "rt-1",
            name: "Lisinopril",
            dose: "5 mg",
            times: [HLTimeOfDay(hour: 9, minute: 30)],
            weekdays: [.mon, .wed, .fri],
            intervalWeeks: 1
        )
        let statement = MedicationToFHIRStatement.map(med, patientID: "rt-pat")
        let data = try JSONEncoder().encode(statement)
        let decoded = try JSONDecoder().decode(MedicationStatement.self, from: data)

        #expect(decoded.status.value == .active)
        #expect(decoded.subject.reference?.value?.string == "Patient/rt-pat")
        #expect(decoded.identifier?.first?.value?.value?.string == "rt-1")
        guard case let .codeableConcept(concept) = decoded.medication else {
            Issue.record("Decoded medication is not codeableConcept")
            return
        }
        #expect(concept.text?.value?.string == "Lisinopril")
        let days = try #require(decoded.dosage?.first?.timing?.repeat?.dayOfWeek).compactMap(\.value)
        #expect(days == [.mon, .wed, .fri])
    }
}
