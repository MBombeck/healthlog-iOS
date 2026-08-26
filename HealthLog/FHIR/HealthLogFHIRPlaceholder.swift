//
//  HealthLogFHIRPlaceholder.swift
//  HealthLog
//
//  Created 2026-05-22 — v0.6.0 H.0 scaffolding-only.
//

// MARK: - v0.6.x FHIR emitter — roadmap placeholder

//
// This file is the on-disk anchor for the iOS-only `HealthLog/FHIR/`
// module that v0.6.x will fill with the Doctor-Report FHIR-bundle
// emitter. It exists solely so:
//
// 1. The `HealthLog/FHIR/` directory is non-empty and survives `xcodegen`
//    (XcodeGen prunes empty source-dirs from the generated `.xcodeproj`,
//    which would silently break the H.1 / H.2 / H.3 incremental commits
//    that each add a single file).
// 2. The umbrella `import SpeziFHIR` smoke (covered by
//    `HealthLogTests/FHIR/HealthLogFHIRPlaceholderTests.swift`) has a
//    target file in the same compilation unit to verify the SPM graph
//    resolves cleanly against our existing Spezi 1.10.x / SpeziHealthKit
//    1.4.2 / SpeziLLM 0.13.x / SpeziDevices 1.6.1 pins.
//
// **Why iOS-only and not `HealthLogCore`?**
// `HealthLogCore` is the plattformfrei SPM library (Models, APIClient,
// Repositories, Util). SpeziFHIR 0.10.0 declares `iOS .v17` (plus
// macOS/watchOS/visionOS) but transitively pulls SpeziHealthKit which
// requires HealthKit — a framework that is **not** available on macOS-
// catalyst-host XCTest hosts on CI. Per `v060-research.md`:
// > "SpeziFHIR is iOS-only → FHIR mappers live in `HealthLog`; expose
// >  only value-types (LOINC table, UCUM enum) in `HealthLogCore` for
// >  platform-free tests."
// H.1 will land the platform-free LOINC + UCUM enums inside
// `HealthLogCore/Sources/HealthLogCore/FHIR/`, leaving the
// SpeziFHIR-bound `Observation`/`Bundle` builders here.
//
// **Phase map (v0.6.x marathon — see `.planning/v056-marathon/v060-research.md`):**
// - H.0 (this commit): SpeziFHIR exact-pin 0.10.0 + skeleton + smoke.
// - H.1: LOINC + UCUM value-types in `HealthLogCore`; 18 MetricKind
//        cases mapped to LOINC codes (incl. BP panel 85354-9 + components
//        8480-6 / 8462-4 and glucose discriminator
//        random / fasting / postprandial).
// - H.2: `MeasurementFHIRMapper` consumes `DoctorReportSpec` and emits
//        `ModelsR4.Observation` per measurement.
// - H.3: `DoctorReportFHIRBundleBuilder` aggregates Observations into
//        a transaction `Bundle` (with `Patient` + `Composition` headers).
// - H.4: `HealthLogSpeziDelegate` registers `FHIRStore` Module so the
//        share-sheet can hand the Bundle to the system FHIR consumer
//        (Health app / Files / EHR app).
// - H.5: Doctor-Report sheet adds "Als FHIR-Bundle exportieren" CTA.
// - H.6: Settings → Export → FHIR-bundle parity polish + tests.
//
// **Owner:** HealthLog maintainer. **GH-Issue:** v060-H0-skeleton (see
// `.planning/v056-marathon/v060-H0-report.md`).

/// Namespace placeholder for the v0.6.x FHIR emitter.
///
/// Once H.1 lands the LOINC mapping table, this `enum` becomes the
/// non-instantiable namespace that re-exports the iOS-only mapper API
/// (`HealthLogFHIR.makeObservation(for:)`,
/// `HealthLogFHIR.makeBundle(for:)`). Until then it exists purely to
/// give downstream tests a stable symbol to reference so an accidental
/// SPM-resolution regression surfaces at compile-time, not at H.2.
enum HealthLogFHIR {
    /// Version of the SpeziFHIR umbrella we resolve against. Tracked
    /// here (rather than parsed from `Package.resolved`) so a silent
    /// upstream prefix-rotation is loud at the next test run.
    static let pinnedSpeziFHIRVersion = "0.10.0"
}
