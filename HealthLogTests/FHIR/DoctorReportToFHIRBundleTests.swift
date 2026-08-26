//
//  DoctorReportToFHIRBundleTests.swift
//  HealthLogTests
//
//  Created 2026-05-22 — v0.6.0 H.4 coverage for `DoctorReportToFHIRBundle`.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

@Suite("DoctorReportToFHIRBundle — v0.6.0 H.4 assembler")
struct DoctorReportToFHIRBundleTests {
    // MARK: - Fixtures

    private func makeCover(name: String = "Anna Schmidt") -> DoctorReportSpec.Cover {
        DoctorReportSpec.Cover(
            patientName: name,
            periodStart: Date(timeIntervalSince1970: 1_700_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
            generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
            appVersion: "0.6.0",
            locale: .de
        )
    }

    private func makeVitals() -> DoctorReportSpec.VitalsSummary {
        DoctorReportSpec.VitalsSummary(rows: [
            .init(kind: .weight, mean: 82.5, median: 82.4, min: 80.0, max: 85.0, count: 7),
            .init(kind: .pulse, mean: 64, median: 63, min: 55, max: 78, count: 12),
            .init(
                kind: .bloodPressure,
                mean: 128,
                median: 125,
                min: 110,
                max: 145,
                count: 8,
                secondaryMean: 82
            )
        ])
    }

    private func makeMedications() -> DoctorReportSpec.MedicationsBlock {
        DoctorReportSpec.MedicationsBlock(
            active: [
                .init(
                    id: "med-aspirin",
                    name: "Aspirin",
                    dose: "100 mg",
                    treatmentClass: "Antiplatelet",
                    schedule: "once daily"
                ),
                .init(
                    id: "med-lisinopril",
                    name: "Lisinopril",
                    dose: "5 mg",
                    treatmentClass: "ACE inhibitor",
                    schedule: "twice daily"
                )
            ],
            archived: [
                .init(
                    id: "med-old",
                    name: "Old Med",
                    dose: "10 mg",
                    treatmentClass: nil,
                    schedule: "as needed"
                )
            ]
        )
    }

    private func makeSpec(
        vitals: DoctorReportSpec.VitalsSummary? = nil,
        medications: DoctorReportSpec.MedicationsBlock? = nil,
        charts: DoctorReportSpec.ChartsBlock? = nil
    ) -> DoctorReportSpec {
        DoctorReportSpec(
            cover: makeCover(),
            vitals: vitals,
            charts: charts,
            medications: medications,
            adherence: nil,
            mood: nil,
            footer: .init(disclaimer: DoctorReportDisclaimer.de)
        )
    }

    // MARK: - Bundle type + structure

    @Test("Bundle.type is .document (FHIR R4 atomic clinician snapshot)")
    func bundleTypeIsDocument() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        #expect(bundle.type.value == .document)
    }

    @Test("First entry is Composition (mandatory for .document bundles)")
    func firstEntryIsComposition() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let first = try #require(entries.first)
        guard case .composition = first.resource else {
            Issue.record("Expected first entry to be Composition, got \(String(describing: first.resource))")
            return
        }
    }

    @Test("Bundle contains exactly one Patient entry")
    func bundleContainsPatient() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let patients = entries.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }
        #expect(patients.count == 1)
        let patient = try #require(patients.first)
        let name = try #require(patient.name?.first)
        #expect(name.family?.value?.string == "Schmidt")
    }

    @Test("Observation count matches vitals rows (no charts)")
    func observationCountMatchesVitalsRows() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let observations = entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        #expect(observations.count == 3) // weight + pulse + BP
    }

    @Test("MedicationStatement count matches active + archived rows")
    func medicationStatementCountMatches() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let stmts = entries.compactMap { entry -> MedicationStatement? in
            if case let .medicationStatement(s) = entry.resource { return s }
            return nil
        }
        #expect(stmts.count == 3) // 2 active + 1 archived

        let archivedCount = stmts.filter { $0.status.value == .completed }.count
        let activeCount = stmts.filter { $0.status.value == .active }.count
        #expect(archivedCount == 1)
        #expect(activeCount == 2)
    }

    // MARK: - Cross-reference resolution

    @Test("Every Observation.subject points to the Patient in the same Bundle")
    func observationsReferenceBundlePatient() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let patient = try #require(entries.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }.first)
        let patientID = try #require(patient.id?.value?.string)
        let expectedRef = "Patient/\(patientID)"

        let observations = entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        for obs in observations {
            let ref = try #require(obs.subject?.reference?.value?.string)
            #expect(ref == expectedRef)
        }
    }

    @Test("DiagnosticReport.result contains every Observation reference + period")
    func diagnosticReportRoutesObservations() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let report = try #require(entries.compactMap { entry -> DiagnosticReport? in
            if case let .diagnosticReport(r) = entry.resource { return r }
            return nil
        }.first)

        let observations = entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        let result = try #require(report.result)
        #expect(result.count == observations.count)

        // Period set to cover.periodStart .. periodEnd
        guard case let .period(period) = report.effective else {
            Issue.record("Expected DiagnosticReport.effective = .period(...)")
            return
        }
        #expect(period.start != nil)
        #expect(period.end != nil)
    }

    @Test("Composition has Vital signs + Medications sections with correct entry counts")
    func compositionSectionsLayout() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let composition = try #require(entries.compactMap { entry -> Composition? in
            if case let .composition(c) = entry.resource { return c }
            return nil
        }.first)

        let sections = try #require(composition.section)
        #expect(sections.count == 2)

        let vitalsSection = try #require(sections.first { $0.title?.value?.string == "Vital signs" })
        #expect(vitalsSection.entry?.count == 3)

        let medsSection = try #require(sections.first { $0.title?.value?.string == "Medications" })
        #expect(medsSection.entry?.count == 3)

        // Composition.subject points at the bundled Patient
        let patient = try #require(entries.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }.first)
        let patientID = try #require(patient.id?.value?.string)
        #expect(composition.subject?.reference?.value?.string == "Patient/\(patientID)")
        #expect(composition.author.first?.reference?.value?.string == "Patient/\(patientID)")
    }

    // MARK: - Fresh Patient ID + Bundle identifier

    @Test("Each Bundle gets a fresh Patient ID + Bundle.identifier URN")
    func freshPatientPerBundle() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle1 = try DoctorReportToFHIRBundle.bundle(from: spec)
        let bundle2 = try DoctorReportToFHIRBundle.bundle(from: spec)

        let patient1 = try #require(bundle1.entry?.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }.first)
        let patient2 = try #require(bundle2.entry?.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }.first)
        #expect(patient1.id?.value?.string != patient2.id?.value?.string)

        // Bundle.identifier set and unique
        let id1 = try #require(bundle1.identifier?.value?.value?.string)
        let id2 = try #require(bundle2.identifier?.value?.value?.string)
        #expect(id1 != id2)
        #expect(id1.hasPrefix("urn:uuid:"))
    }

    @Test("Bundle entries carry fullUrl = urn:uuid:<resource.id>")
    func entriesCarryFullURL() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        for entry in entries {
            let fullURL = try #require(entry.fullUrl?.value?.url.absoluteString)
            #expect(fullURL.hasPrefix("urn:uuid:"))
        }
    }

    // MARK: - Empty spec

    @Test("Empty spec (no vitals, no medications, no charts) → Composition + Patient + DiagnosticReport")
    func emptySpec() throws {
        let spec = makeSpec(vitals: nil, medications: nil, charts: nil)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        // Composition + Patient + DiagnosticReport (always present)
        #expect(entries.count == 3)

        // No Observations, no MedicationStatements
        let observations = entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        let stmts = entries.compactMap { entry -> MedicationStatement? in
            if case let .medicationStatement(s) = entry.resource { return s }
            return nil
        }
        #expect(observations.isEmpty)
        #expect(stmts.isEmpty)

        // Composition has no sections (both empty)
        let composition = try #require(entries.compactMap { entry -> Composition? in
            if case let .composition(c) = entry.resource { return c }
            return nil
        }.first)
        #expect(composition.section?.isEmpty ?? true)
    }

    // MARK: - JSON round-trip

    @Test("JSON encode + decode preserves Bundle integrity (type, entry counts, references)")
    func jsonRoundTrip() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let originalEntryCount = bundle.entry?.count ?? 0

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Bundle.self, from: data)

        #expect(decoded.type.value == .document)
        #expect(decoded.entry?.count == originalEntryCount)

        // First entry round-trips to Composition
        let firstEntry = try #require(decoded.entry?.first)
        guard case .composition = firstEntry.resource else {
            Issue.record("Round-tripped first entry is not Composition")
            return
        }

        // Patient + Observations + MedicationStatements all survive
        let entries = try #require(decoded.entry)
        let patients = entries.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }
        let observations = entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        let stmts = entries.compactMap { entry -> MedicationStatement? in
            if case let .medicationStatement(s) = entry.resource { return s }
            return nil
        }
        #expect(patients.count == 1)
        #expect(observations.count == 3)
        #expect(stmts.count == 3)
    }

    // MARK: - Charts → per-point Observations

    @Test("Charts block adds one Observation per Point on top of vitals rows")
    func chartsAddPerPointObservations() throws {
        let charts = DoctorReportSpec.ChartsBlock(series: [
            .init(kind: .weight, points: [
                .init(at: Date(timeIntervalSince1970: 1_700_000_000), value: 82.5),
                .init(at: Date(timeIntervalSince1970: 1_700_086_400), value: 82.7)
            ])
        ])
        let spec = makeSpec(vitals: makeVitals(), medications: nil, charts: charts)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let observations = try #require(bundle.entry).compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
        // 3 vitals rows + 2 chart points = 5
        #expect(observations.count == 5)
    }
}

// MARK: - v0.11 FHIR-R4 conformance fixes

@Suite("DoctorReportToFHIRBundle — v0.11 FHIR-R4 conformance fixes")
struct DoctorReportToFHIRBundleConformanceTests {
    // MARK: - Fixtures

    private func makeCover(
        insurerName: String? = nil,
        insuranceNumber: String? = nil,
        insurerIkNumber: String? = nil
    ) -> DoctorReportSpec.Cover {
        DoctorReportSpec.Cover(
            patientName: "Anna Schmidt",
            insurerName: insurerName,
            insuranceNumber: insuranceNumber,
            insurerIkNumber: insurerIkNumber,
            periodStart: Date(timeIntervalSince1970: 1_700_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
            generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
            appVersion: "0.11.0",
            locale: .de
        )
    }

    private func makeVitals() -> DoctorReportSpec.VitalsSummary {
        DoctorReportSpec.VitalsSummary(rows: [
            .init(kind: .weight, mean: 82.5, median: 82.4, min: 80.0, max: 85.0, count: 7),
            .init(kind: .pulse, mean: 64, median: 63, min: 55, max: 78, count: 12),
            .init(
                kind: .bloodPressure, mean: 128, median: 125, min: 110, max: 145,
                count: 8, secondaryMean: 82
            )
        ])
    }

    private func makeMedications() -> DoctorReportSpec.MedicationsBlock {
        DoctorReportSpec.MedicationsBlock(
            active: [
                .init(id: "med-1", name: "Aspirin", dose: "100 mg", treatmentClass: nil, schedule: "once daily")
            ],
            archived: []
        )
    }

    private func makeSpec(
        cover: DoctorReportSpec.Cover? = nil,
        vitals: DoctorReportSpec.VitalsSummary? = nil,
        medications: DoctorReportSpec.MedicationsBlock? = nil,
        charts: DoctorReportSpec.ChartsBlock? = nil
    ) -> DoctorReportSpec {
        DoctorReportSpec(
            cover: cover ?? makeCover(),
            vitals: vitals,
            charts: charts,
            medications: medications,
            adherence: nil,
            mood: nil,
            footer: .init(disclaimer: DoctorReportDisclaimer.de)
        )
    }

    private func observations(in bundle: ModelsR4.Bundle) throws -> [Observation] {
        let entries = try #require(bundle.entry)
        return entries.compactMap { entry -> Observation? in
            if case let .observation(o) = entry.resource { return o }
            return nil
        }
    }

    private func patient(in bundle: ModelsR4.Bundle) throws -> Patient {
        let entries = try #require(bundle.entry)
        let patients = entries.compactMap { entry -> Patient? in
            if case let .patient(p) = entry.resource { return p }
            return nil
        }
        return try #require(patients.first)
    }

    private func coverages(in bundle: ModelsR4.Bundle) throws -> [Coverage] {
        let entries = try #require(bundle.entry)
        return entries.compactMap { entry -> Coverage? in
            if case let .coverage(c) = entry.resource { return c }
            return nil
        }
    }

    // MARK: - Tests

    @Test("Every Observation carries a category (audit B1)")
    func everyObservationHasCategory() throws {
        let charts = DoctorReportSpec.ChartsBlock(series: [
            .init(kind: .pulse, points: [
                .init(at: Date(timeIntervalSince1970: 1_700_000_000), value: 70)
            ])
        ])
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications(), charts: charts)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        for obs in try observations(in: bundle) {
            let coding = try #require(obs.category?.first?.coding?.first)
            #expect(coding.system?.value?.url.absoluteString
                == "http://terminology.hl7.org/CodeSystem/observation-category")
            #expect(coding.code?.value?.string != nil)
        }
    }

    @Test("Every Observation carries an effective date — none is dateless (audit B6)")
    func everyObservationHasEffective() throws {
        let charts = DoctorReportSpec.ChartsBlock(series: [
            .init(kind: .weight, points: [
                .init(at: Date(timeIntervalSince1970: 1_700_000_000), value: 82.5)
            ])
        ])
        let spec = makeSpec(vitals: makeVitals(), medications: nil, charts: charts)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        for obs in try observations(in: bundle) {
            switch obs.effective {
            case .dateTime, .period:
                break // OK
            default:
                Issue.record("Observation has no effectiveDateTime / effectivePeriod")
            }
        }
    }

    @Test("Summary BP row without diastolic emits only the systolic component — never a fabricated 0 (audit B4)")
    func summaryBPOmitsAbsentDiastolic() throws {
        let vitals = DoctorReportSpec.VitalsSummary(rows: [
            .init(kind: .bloodPressure, mean: 130, median: 128, min: 110, max: 150, count: 5, secondaryMean: nil)
        ])
        let spec = makeSpec(vitals: vitals, medications: nil)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let allObs = try observations(in: bundle)
        let bpObs = try #require(allObs.first { $0.component != nil })
        let components = try #require(bpObs.component)
        #expect(components.count == 1)
        #expect(components.first?.code.coding?.first?.code?.value?.string == "8480-6") // systolic only
    }

    @Test("Chart BP point without secondary emits only the systolic component (audit B4)")
    func chartBPOmitsAbsentDiastolic() throws {
        let charts = DoctorReportSpec.ChartsBlock(series: [
            .init(kind: .bloodPressure, points: [
                .init(at: Date(timeIntervalSince1970: 1_700_000_000), value: 132, secondary: nil)
            ])
        ])
        let spec = makeSpec(vitals: nil, medications: nil, charts: charts)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let allObs = try observations(in: bundle)
        let bpObs = try #require(allObs.first { $0.component != nil })
        #expect(bpObs.component?.count == 1)
    }

    @Test("BP with diastolic still emits both components")
    func bpWithDiastolicEmitsBoth() throws {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: makeSpec(vitals: makeVitals(), medications: nil))
        let allObs = try observations(in: bundle)
        let bpObs = try #require(allObs.first { $0.component != nil })
        #expect(bpObs.component?.count == 2)
    }

    @Test("Composition carries a generated narrative + section narratives (audit D2)")
    func compositionHasNarrative() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: makeMedications())
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let entries = try #require(bundle.entry)
        let composition = try #require(entries.compactMap { entry -> Composition? in
            if case let .composition(c) = entry.resource { return c }
            return nil
        }.first)

        let narrative = try #require(composition.text)
        #expect(narrative.status.value == .generated)
        let div = try #require(narrative.div.value?.string)
        #expect(div.contains("xmlns=\"http://www.w3.org/1999/xhtml\""))
        #expect(div.hasPrefix("<div"))

        // Each section carries its own narrative.
        for section in try #require(composition.section) {
            let sectionText = try #require(section.text)
            #expect(sectionText.status.value == .generated)
            #expect(sectionText.div.value?.string.contains("xhtml") == true)
        }
    }

    @Test("No insurer → no Patient.identifier with a bare assigner (audit A2)")
    func noInsurerNoBareAssigner() throws {
        // KVNR absent + insurer present: previously emitted a malformed
        // Identifier (no system, no value, only assigner.display). Now omitted.
        let spec = makeSpec(cover: makeCover(insurerName: "AOK Bayern", insuranceNumber: nil))
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        // No KVNR → no identifier at all (no malformed assigner-only Identifier).
        let resolvedPatient = try patient(in: bundle)
        #expect(resolvedPatient.identifier == nil)
    }

    @Test("KVNR + insurer → identifier with system + value + assigner.display (audit A2)")
    func kvnrWithInsurerWellFormed() throws {
        let spec = makeSpec(cover: makeCover(insurerName: "AOK Bayern", insuranceNumber: "A123456789"))
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let resolvedPatient = try patient(in: bundle)
        let identifier = try #require(resolvedPatient.identifier?.first)
        #expect(identifier.system?.value?.url.absoluteString == "http://fhir.de/sid/gkv/kvid-10")
        #expect(identifier.value?.value?.string == "A123456789")
        #expect(identifier.assigner?.display?.value?.string == "AOK Bayern")
    }

    @Test("No summary Observation carries the old 00000-0 LOINC placeholder (audit B5)")
    func summaryFallbackAvoidsFakeLOINC() throws {
        let spec = makeSpec(vitals: makeVitals(), medications: nil)
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        for obs in try observations(in: bundle) {
            #expect(obs.code.coding?.first?.code?.value?.string != "00000-0")
        }
    }

    // MARK: - Coverage (v0.11.0 — insurer IKNR, server v1.8.6 confirmed)

    @Test("With IKNR → Coverage(active) + contained Organization w/ arge-ik/iknr identifier + name")
    func coverageWithIKNR() throws {
        let spec = makeSpec(cover: makeCover(
            insurerName: "AOK Bayern",
            insuranceNumber: "A123456789",
            insurerIkNumber: "108310400"
        ))
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let coverage = try #require(try coverages(in: bundle).first)

        #expect(coverage.status.value == .active)
        // subscriberId == KVNR
        #expect(coverage.subscriberId?.value?.string == "A123456789")
        // beneficiary references the bundle's Patient
        let resolvedPatient = try patient(in: bundle)
        let patientID = try #require(resolvedPatient.id?.value?.string)
        #expect(coverage.beneficiary.reference?.value?.string == "Patient/\(patientID)")
        // payor → contained Organization via local #org ref
        #expect(coverage.payor.first?.reference?.value?.string == "#org")
        let contained = try #require(coverage.contained)
        var organization: Organization?
        if case let .organization(o) = contained.first { organization = o }
        let org = try #require(organization)
        #expect(org.name?.value?.string == "AOK Bayern")
        let orgIdentifier = try #require(org.identifier?.first)
        #expect(orgIdentifier.system?.value?.url.absoluteString == "http://fhir.de/sid/arge-ik/iknr")
        #expect(orgIdentifier.value?.value?.string == "108310400")
    }

    @Test("Without IKNR → Coverage still emitted, name-only Organization (no identifier)")
    func coverageWithoutIKNR() throws {
        let spec = makeSpec(cover: makeCover(
            insurerName: "AOK Bayern",
            insuranceNumber: "A123456789",
            insurerIkNumber: nil
        ))
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let coverage = try #require(try coverages(in: bundle).first)

        #expect(coverage.status.value == .active)
        #expect(coverage.subscriberId?.value?.string == "A123456789")
        let contained = try #require(coverage.contained)
        var organization: Organization?
        if case let .organization(o) = contained.first { organization = o }
        let org = try #require(organization)
        #expect(org.name?.value?.string == "AOK Bayern")
        // Adaptive fallback: name-only Organization, no identifier.
        #expect(org.identifier == nil)
    }

    @Test("No insurer + no KVNR → no Coverage emitted (no payor signal)")
    func noCoverageWithoutPayorSignal() throws {
        let spec = makeSpec(cover: makeCover(insurerName: nil, insuranceNumber: nil, insurerIkNumber: nil))
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        #expect(try coverages(in: bundle).isEmpty)
    }

    @Test("Coverage does not disturb Patient.identifier KVNR (kvid-10 unchanged)")
    func coverageLeavesPatientKVNRUnchanged() throws {
        let spec = makeSpec(cover: makeCover(
            insurerName: "AOK Bayern",
            insuranceNumber: "A123456789",
            insurerIkNumber: "108310400"
        ))
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let resolvedPatient = try patient(in: bundle)
        let identifier = try #require(resolvedPatient.identifier?.first)
        #expect(identifier.system?.value?.url.absoluteString == "http://fhir.de/sid/gkv/kvid-10")
        #expect(identifier.value?.value?.string == "A123456789")
    }
}
