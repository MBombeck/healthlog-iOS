//
//  DoctorReportFHIRWriter.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  Created 2026-05-22 — v0.6.0 H.6 helper that JSON-encodes the FHIR R4
//  Document Bundle assembled by `DoctorReportToFHIRBundle.bundle(from:)`
//  and writes it to a deterministic `.fhir.json` file in the system
//  temp directory. Mirrors the lifecycle of the unified sharing surface's
//  on-device emitter (H.5) so the local Doctor-Report flow (H.6) can
//  co-emit PDF + FHIR from a single `generate(...)` call.
//
//  Why a standalone helper instead of inlining the writer in
//  `LocalDoctorReportStore`?
//  -----------------------------------------------------------------
//  `import ModelsR4` exports a top-level `Observation` type that
//  shadows the `Observation` framework (which provides the `@Observable`
//  macro). `LocalDoctorReportStore` is `@Observable` so it cannot
//  `import ModelsR4` without breaking its own annotation. Keeping the
//  FHIR-touching code in this dedicated helper file isolates the
//  ModelsR4 import surface from the store + screen layer.
//

import Foundation
import ModelsR4

/// Disambiguates the FHIR `Bundle` from `Foundation.Bundle` inside this
/// file — `ModelsR4` exports a `Bundle` type that otherwise shadows
/// the Foundation one.
private typealias FHIRBundle = ModelsR4.Bundle

/// JSON-emit helper for the local Doctor-Report co-emit pipeline (H.6).
///
/// Pure, stateless. Calls `DoctorReportToFHIRBundle.bundle(from:)`,
/// pretty-prints the result, and writes a temp file named
/// `healthlog-fhir-YYYYMMDD-HHmmss.fhir.json`. Caller owns the file
/// lifecycle.
enum DoctorReportFHIRWriter {
    /// Write the FHIR R4 Document Bundle JSON for `spec` to the system
    /// temp directory and return the resulting URL.
    ///
    /// - Parameters:
    ///   - spec: same `DoctorReportSpec` the PDF renderer consumes —
    ///     guarantees PDF + FHIR describe the identical period and rows.
    ///   - generatedAt: report-generation timestamp; used to build the
    ///     deterministic filename stamp.
    /// - Throws: `DoctorReportToFHIRBundle.bundle(from:)` (today: never)
    ///   or any `JSONEncoder`/`Data.write` error.
    static func write(spec: DoctorReportSpec, generatedAt: Date) throws -> URL {
        let bundle: FHIRBundle = try DoctorReportToFHIRBundle.bundle(from: spec)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: generatedAt)
        // Include a short UUID suffix so two consecutive writes with the
        // same `generatedAt` (e.g. test fixtures with a frozen clock)
        // land on distinct paths — otherwise the store's cleanup of the
        // previous file would delete the newly-written one.
        let unique = UUID().uuidString.prefix(8).lowercased()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("healthlog-fhir-\(stamp)-\(unique)")
            .appendingPathExtension("fhir.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
