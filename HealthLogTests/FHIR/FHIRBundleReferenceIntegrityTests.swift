//
//  FHIRBundleReferenceIntegrityTests.swift
//  HealthLogTests
//
//  #115 R4 — every reference in the app's FHIR document bundle resolves
//  inside the bundle, and every entry is reachable from the Composition.
//
//  The bundle is `type = document` and every entry carries
//  `fullUrl = urn:uuid:<id>`. Under FHIR R4 §2.36.4 ("Resolving references
//  in Bundles", bdl-7) a relative reference such as `Patient/<id>` resolves
//  against the base of the fullUrl it sits under, and a `urn:uuid` fullUrl
//  has no RESTful base. The HL7 validator therefore reported every one of
//  the app's `Patient/…`, `Observation/…`, `Condition/…` and
//  `MedicationStatement/…` references as unresolvable (242 errors on a full
//  export), and every entry as unreachable from the Composition. The server
//  (v1.39.6, `src/lib/fhir/build-bundle.ts` `withResolvedReferences`) writes
//  each internal reference as the target entry's `urn:uuid` fullUrl; the app
//  now does the same. Contained `#…` references stay local.
//
//  The checks run on the serialised JSON, not on the ModelsR4 graph, so a
//  reference that a future emitter adds anywhere is covered the day it lands.
//

import Foundation
@testable import HealthLog
import ModelsR4
import Testing

@Suite("R4 — FHIR bundle references resolve inside the document")
struct FHIRBundleReferenceIntegrityTests {
    // MARK: - Fixtures

    private static let cover = DoctorReportSpec.Cover(
        patientName: "Anna Schmidt",
        fullName: "Anna Maria Schmidt",
        insurerName: "AOK Nordost",
        insuranceNumber: "A123456780",
        insurerIkNumber: "109519005",
        periodStart: Date(timeIntervalSince1970: 1_700_000_000),
        periodEnd: Date(timeIntervalSince1970: 1_702_592_000),
        generatedAt: Date(timeIntervalSince1970: 1_702_600_000),
        appVersion: "1.1.0",
        locale: .de
    )

    private static func row(_ kind: MetricKind) -> DoctorReportSpec.VitalsSummary.Row {
        .init(
            kind: kind, mean: 50, median: 50, min: 40, max: 60, count: 3,
            secondaryMean: kind == .bloodPressure ? 80 : nil
        )
    }

    private static func lab(_ analyte: String, unit: String, linked: Bool) -> LabResultDTO {
        LabResultDTO(
            id: "lab-\(analyte)",
            biomarkerId: linked ? "bm-\(analyte)" : nil,
            panel: nil,
            analyte: analyte,
            value: 42,
            valueText: nil,
            unit: unit,
            referenceLow: 10,
            referenceHigh: 100,
            takenAt: "2023-12-01T08:30:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .inRange,
            createdAt: "2023-12-01T08:30:00Z",
            updatedAt: "2023-12-01T08:30:00Z"
        )
    }

    private static func episode(_ id: String, _ type: IllnessType, resolved: Bool) -> IllnessEpisodeDTO {
        IllnessEpisodeDTO(
            id: id, label: "Episode \(id)", type: type, lifecycle: .acute,
            onsetAt: "2023-11-15T00:00:00Z", resolvedAt: resolved ? "2023-11-20T00:00:00Z" : nil,
            parentConditionId: nil, note: nil,
            createdAt: "2023-11-15T00:00:00Z", updatedAt: "2023-11-15T00:00:00Z"
        )
    }

    /// Every resource kind the app's exporter can emit: Patient (with KVNR),
    /// Coverage (contained payor), a vitals row for every exportable kind,
    /// chart points, active + archived MedicationStatements, linked and
    /// unlinked lab Observations, Conditions with day-log Observations, and
    /// both DiagnosticReports.
    static func fullSpec() -> DoctorReportSpec {
        let rows = MetricKind.allCases.filter { !$0.isUnknown }.map(row)
        let points = (0 ..< 3).map {
            DoctorReportSpec.ChartsBlock.Point(at: cover.periodStart.addingTimeInterval(Double($0) * 86400), value: 60 + Double($0))
        }
        let bpPoints = points.map { DoctorReportSpec.ChartsBlock.Point(at: $0.at, value: 120, secondary: 80) }
        let dayLog = IllnessDayLogDTO(
            id: "dl-1", episodeId: "ep-1", date: "2023-11-16", functionalImpact: 2, feverC: 38.4,
            symptoms: [], note: nil, updatedAt: "2023-11-16T00:00:00Z"
        )
        return DoctorReportSpec(
            cover: cover,
            vitals: .init(rows: rows),
            charts: .init(series: [
                .init(kind: .restingHeartRate, points: points),
                .init(kind: .bloodPressure, points: bpPoints)
            ]),
            medications: .init(
                active: [.init(id: "med-1", name: "Lisinopril", dose: "5 mg", treatmentClass: nil, schedule: "1-0-0")],
                archived: [.init(id: "med-2", name: "Naproxen", dose: "400 mg", treatmentClass: nil, schedule: "bei Bedarf")]
            ),
            adherence: nil,
            mood: nil,
            labs: .init(results: [
                lab("LDL", unit: "mg/dL", linked: true),
                lab("HbA1c", unit: "%", linked: true),
                lab("Freitext-Wert", unit: "x", linked: false)
            ]),
            illnesses: .init(
                episodes: [episode("ep-1", .infection, resolved: true), episode("ep-2", .allergy, resolved: false)],
                dayLogsByEpisode: ["ep-1": [dayLog]]
            ),
            footer: .init(disclaimer: DoctorReportDisclaimer.de)
        )
    }

    static func spec(vitals: Bool, labs: Bool, illnesses: Bool, insurer: Bool) -> DoctorReportSpec {
        let full = fullSpec()
        let plainCover = DoctorReportSpec.Cover(
            patientName: cover.patientName, periodStart: cover.periodStart, periodEnd: cover.periodEnd,
            generatedAt: cover.generatedAt, appVersion: cover.appVersion, locale: cover.locale
        )
        return DoctorReportSpec(
            cover: insurer ? cover : plainCover,
            vitals: vitals ? full.vitals : nil,
            charts: nil,
            medications: nil,
            adherence: nil,
            mood: nil,
            labs: labs ? full.labs : nil,
            illnesses: illnesses ? full.illnesses : nil,
            footer: full.footer
        )
    }

    // MARK: - JSON walk

    private struct Entry {
        let fullUrl: String
        let resourceType: String
        let resource: [String: Any]
    }

    private static func entries(_ spec: DoctorReportSpec) throws -> [Entry] {
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let data = try JSONEncoder().encode(bundle)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["type"] as? String == "document")
        let raw = try #require(root["entry"] as? [[String: Any]])
        return try raw.map { item in
            let resource = try #require(item["resource"] as? [String: Any])
            return try Entry(
                fullUrl: #require(item["fullUrl"] as? String),
                resourceType: #require(resource["resourceType"] as? String),
                resource: resource
            )
        }
    }

    /// Every `reference` string anywhere below `value`.
    private static func references(in value: Any, into out: inout [String]) {
        if let array = value as? [Any] {
            for item in array {
                references(in: item, into: &out)
            }
        } else if let object = value as? [String: Any] {
            for (key, child) in object {
                if key == "reference", let string = child as? String {
                    out.append(string)
                } else {
                    references(in: child, into: &out)
                }
            }
        }
    }

    private static func references(of resource: [String: Any]) -> [String] {
        var out: [String] = []
        references(in: resource, into: &out)
        return out
    }

    private static func containedIDs(of resource: [String: Any]) -> Set<String> {
        let contained = resource["contained"] as? [[String: Any]] ?? []
        return Set(contained.compactMap { ($0["id"] as? String).map { "#\($0)" } })
    }

    private static func isUUIDURN(_ value: String) -> Bool {
        value.wholeMatch(of: /urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil
    }

    // MARK: - Tests

    @Test("Every entry has a distinct urn:uuid fullUrl over a lowercase UUID")
    func fullUrlsAreDistinctUUIDURNs() throws {
        let entries = try Self.entries(Self.fullSpec())
        for entry in entries {
            #expect(Self.isUUIDURN(entry.fullUrl), "fullUrl \(entry.fullUrl)")
            #expect(entry.fullUrl == "urn:uuid:\(entry.resource["id"] as? String ?? "")")
        }
        #expect(Set(entries.map(\.fullUrl)).count == entries.count)
    }

    @Test("The full export carries every resource kind the app emits")
    func fullExportCoversEveryKind() throws {
        let kinds = try Set(Self.entries(Self.fullSpec()).map(\.resourceType))
        #expect(kinds == [
            "Composition", "Patient", "Coverage", "Observation", "MedicationStatement",
            "Condition", "DiagnosticReport"
        ])
    }

    @Test(
        "Every reference resolves to an entry fullUrl or a contained resource",
        arguments: [
            (true, true, true, true),
            (false, false, false, false),
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, true)
        ]
    )
    func everyReferenceResolves(vitals: Bool, labs: Bool, illnesses: Bool, insurer: Bool) throws {
        for spec in [Self.fullSpec(), Self.spec(vitals: vitals, labs: labs, illnesses: illnesses, insurer: insurer)] {
            let entries = try Self.entries(spec)
            let fullUrls = Set(entries.map(\.fullUrl))
            var checked = 0
            for entry in entries {
                let local = Self.containedIDs(of: entry.resource)
                for reference in Self.references(of: entry.resource) {
                    checked += 1
                    let resolves = reference.hasPrefix("#") ? local.contains(reference) : fullUrls.contains(reference)
                    #expect(resolves, "\(entry.resourceType): unresolvable reference \(reference)")
                }
            }
            #expect(checked >= 2) // at least Composition.subject + Composition.author
        }
    }

    @Test("Composition subject and author name the Patient entry")
    func compositionNamesThePatient() throws {
        let entries = try Self.entries(Self.fullSpec())
        let composition = try #require(entries.first)
        #expect(composition.resourceType == "Composition")
        let patient = try #require(entries.first { $0.resourceType == "Patient" })
        let subject = composition.resource["subject"] as? [String: Any]
        let author = (composition.resource["author"] as? [[String: Any]])?.first
        #expect(subject?["reference"] as? String == patient.fullUrl)
        #expect(author?["reference"] as? String == patient.fullUrl)
    }

    /// The validator walks the document graph from the Composition; an entry
    /// nothing reaches is "not reachable from the Composition". Coverage and
    /// both DiagnosticReports used to be such orphans.
    @Test(
        "Every entry is reachable from the Composition",
        arguments: [(true, true, true, true), (true, false, false, false), (false, true, false, false), (false, false, true, true)]
    )
    func everyEntryReachable(vitals: Bool, labs: Bool, illnesses: Bool, insurer: Bool) throws {
        for spec in [Self.fullSpec(), Self.spec(vitals: vitals, labs: labs, illnesses: illnesses, insurer: insurer)] {
            let entries = try Self.entries(spec)
            let byURL = Dictionary(uniqueKeysWithValues: entries.map { ($0.fullUrl, $0) })
            let start = try #require(entries.first?.fullUrl)
            var reached: Set<String> = [start]
            var queue = [start]
            while let next = queue.popLast() {
                for reference in Self.references(of: byURL[next]?.resource ?? [:]) where byURL[reference] != nil {
                    if reached.insert(reference).inserted { queue.append(reference) }
                }
            }
            for entry in entries {
                #expect(reached.contains(entry.fullUrl), "\(entry.resourceType) \(entry.fullUrl) is not reachable")
            }
        }
    }

    @Test("No relative Type/id reference remains in the document")
    func noRelativeReferences() throws {
        let entries = try Self.entries(Self.fullSpec())
        let all = entries.flatMap { Self.references(of: $0.resource) }
        let relative = all.filter { !$0.hasPrefix("urn:uuid:") && !$0.hasPrefix("#") }
        #expect(relative.isEmpty, "relative references: \(relative)")
        #expect(all.contains("#org"))
    }
}
