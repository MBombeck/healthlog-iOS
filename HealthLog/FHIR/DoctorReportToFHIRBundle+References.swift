//
//  DoctorReportToFHIRBundle+References.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  #115 R4 — references inside the document Bundle resolve inside it.
//
//  Every entry carries `fullUrl = urn:uuid:<resource.id>`. Under FHIR R4
//  bdl-7 / §2.36.4 a relative reference (`Patient/<id>`) resolves against the
//  RESTful base of the fullUrl it sits under, and a `urn:uuid` has none: the
//  HL7 validator reported every such reference as unresolvable and every entry
//  as unreachable from the Composition. A reference to another entry is
//  therefore that entry's own `urn:uuid` fullUrl, which is exactly what the
//  server's exporter emits (v1.39.6, `src/lib/fhir/build-bundle.ts`,
//  `withResolvedReferences`). Contained `#…` references stay local.
//
//  Kept out of `DoctorReportToFHIRBundle.swift`, whose length is frozen in the
//  SwiftLint baseline.
//

import Foundation
import ModelsR4

extension DoctorReportToFHIRBundle {
    /// Reference to the bundle entry that carries the resource `id`: its
    /// `urn:uuid:<id>` fullUrl (see ``makeEntry(fullURL:resource:)``).
    static func entryReference(_ id: String) -> Reference {
        Reference(reference: FHIRString("urn:uuid:\(id)").asPrimitive())
    }

    /// Same, read off a resource's id primitive.
    static func entryReference(_ id: FHIRPrimitive<FHIRString>?) -> Reference {
        entryReference(id?.value?.string ?? "")
    }

    static let insuranceSectionTitle = "Insurance"

    /// Make the entries no section names reachable from the Composition, as
    /// the server does: the vitals DiagnosticReport rides in "Vital signs",
    /// the lab DiagnosticReport in "Laboratory", and the Coverage gets its own
    /// "Insurance" section. A document entry that nothing in the Composition's
    /// graph reaches is one the validator rejects ("not reachable from the
    /// Composition") and a receiver may never show.
    static func linkUnsectionedEntries(
        into composition: Composition,
        coverageID: String?,
        vitalsReportID: String?,
        labReportID: String?
    ) {
        var sections = composition.section ?? []
        func append(_ id: String?, toSection title: String) {
            guard let id,
                  let section = sections.first(where: { $0.title?.value?.string == title }) else { return }
            section.entry = (section.entry ?? []) + [entryReference(id)]
        }
        append(vitalsReportID, toSection: "Vital signs")
        append(labReportID, toSection: "Laboratory")
        if let coverageID {
            let insurance = CompositionSection()
            insurance.title = FHIRString(insuranceSectionTitle).asPrimitive()
            insurance.text = makeNarrative(html: "<p>Statutory health insurance (payor) of the patient.</p>")
            insurance.entry = [entryReference(coverageID)]
            sections.append(insurance)
        }
        composition.section = sections.isEmpty ? nil : sections
    }
}
