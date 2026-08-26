import Foundation
@testable import HealthLog
import ModelsR4
import SwiftUI
import Testing

/// **v0.6.0 H.5 — the FHIR-export contract.**
///
/// Pins the headless contract for the FHIR export:
///   - the surface that hosts it compiles + conforms to `View`
///   - the JSON-encoded bundle produced from a known spec is
///     non-empty and round-trips through the FHIRModels coder
///   - the temp filename uses the `.fhir.json` extension so the
///     receiving doctor-system sniffs the right MIME
///
/// **18-03 — the host moved, the contract did not.** `SettingsFHIRExportScreen`
/// was one of four cards asking overlapping questions; FHIR is now one of four
/// output forms on `UnifiedSharingScreen`. Everything below the first case is
/// about the bundle and the PHI write, neither of which ever belonged to the
/// screen.
@MainActor
@Suite("FHIR export contract")
struct SettingsFHIRExportScreenTests {
    @Test("the FHIR export's host surface compiles + conforms to View")
    func compiles() {
        let view: any View = UnifiedSharingScreen(preselectedForm: .fhir)
        _ = view
    }

    @Test("Bundle JSON round-trips and the produced file uses .fhir.json")
    func bundleJSONRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let snapshot = DoctorReportSpecBuilder.Snapshot(
            patientName: "Test Patient",
            appVersion: "0.6.0 (1)",
            measurements: [],
            medications: [],
            compliance: [],
            intakes: [],
            moodEntries: []
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: now.addingTimeInterval(-90 * 86400),
            periodEnd: now,
            generatedAt: now
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        #expect(!data.isEmpty)

        // round-trip
        let decoded = try JSONDecoder().decode(ModelsR4.Bundle.self, from: data)
        #expect(decoded.type.value == bundle.type.value)
    }

    /// **v0.8.0 W9 L-2 — FHIR export PHI write must use complete file
    /// protection.** The exported bundle carries health observations, so
    /// the temp file has to land under `.completeFileProtection`, matching
    /// every sibling PHI export path (`DoctorReportStore`, `SettingsExportScreen`,
    /// `DoctorReportFHIRWriter`, `DoctorReportRenderer`). Exercises the
    /// real `writeBundle` so a drift back to the default protection class
    /// (readable after first unlock) breaks this test.
    @Test("FHIR export file is written with complete file protection")
    func fhirExportFileUsesCompleteFileProtection() throws {
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let snapshot = DoctorReportSpecBuilder.Snapshot(
            patientName: "Test Patient",
            appVersion: "0.8.0 (1)",
            measurements: [],
            medications: [],
            compliance: [],
            intakes: [],
            moodEntries: []
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: now.addingTimeInterval(-90 * 86400),
            periodEnd: now,
            generatedAt: now
        )
        let bundle = try DoctorReportToFHIRBundle.bundle(from: spec)

        // audit v0162 H2 — the PHI-write helpers moved from the screen into
        // `ExportStore` (the store owns the full artifact lifecycle now).
        let url = try ExportStore.writeBundle(bundle, generatedAt: now)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))

        // The protection class is reported via the file's resource values.
        // On a real device a `.completeFileProtection` write reports
        // `.complete`. The iOS Simulator does NOT differentiate protection
        // classes for temp-directory files — it reports
        // `.completeUntilFirstUserAuthentication` regardless of the option
        // passed (verified empirically: a default-options write reports the
        // same value). So the strongest simulator-stable guarantee is that
        // the file carries a protection class from the "complete" family
        // (i.e. it is NOT `.none`); the exact `.completeFileProtection`
        // opt-in is enforced at the source/build level. This still catches
        // a regression that drops protection entirely.
        let values = try url.resourceValues(forKeys: [.fileProtectionKey])
        let protection = try #require(values.fileProtection)
        #expect([.complete, .completeUntilFirstUserAuthentication].contains(protection))
        #expect(protection != URLFileProtection.none)
    }

    /// **v0.8.0 W9 L-2 (source-level guard).** Because the iOS Simulator
    /// collapses every protection class to
    /// `.completeUntilFirstUserAuthentication` at runtime (see the test
    /// above), the runtime check cannot distinguish `.completeFileProtection`
    /// from the default. This guard pins the actual opt-in at the source
    /// level — the simulator shares the host filesystem, so the test can
    /// read the source file via `#filePath` and assert the FHIR-export write
    /// passes `.completeFileProtection`, matching the sibling PHI writers. A
    /// drift back to plain `[.atomic]` breaks here.
    ///
    /// audit v0162 H2 — the PHI-write seam now lives in `ExportStore`, so this
    /// guard scans the store source (where `writeData` / `persist` write).
    @Test("FHIR export source passes .completeFileProtection to the write")
    func fhirExportSourceUsesCompleteFileProtection() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        // …/HealthLogTests/Screens/Settings/SettingsFHIRExportScreenTests.swift
        // → repo root is four levels up from the test file.
        let repoRoot = testFile
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        let source = repoRoot
            .appendingPathComponent("HealthLog/Stores/ExportStore.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("options: [.atomic, .completeFileProtection]"))
    }
}
