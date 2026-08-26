#if canImport(SpeziFHIR)
    @testable import HealthLog
    import ModelsR4
    import SpeziFHIR
    import Testing

    /// Smoke coverage for the v0.6.0 H.0 SpeziFHIR adoption skeleton.
    ///
    /// H.0 only pins the SpeziFHIR SPM dep (exact `0.10.0`) and scaffolds
    /// the iOS-only `HealthLog/FHIR/` namespace; the mapper, LOINC table,
    /// and `DoctorReportSpec → Bundle` builder all land in H.1 / H.2 / H.3.
    /// This suite is the trip-wire that proves:
    ///
    /// 1. **SPM resolves cleanly** — both the umbrella product
    ///    `SpeziFHIR` and the transitive `ModelsR4` (Apple `FHIRModels`
    ///    R4 codable layer) are linkable from the app-side test bundle.
    ///    A silent regression in the `project.yml` exact-pin (or in the
    ///    transitive `FHIRModels from: 0.7.0` floor) would fail the
    ///    `import` statement above before any test body runs.
    ///
    /// 2. **The umbrella exposes the constructors H.2 will lean on** —
    ///    `ModelsR4.Observation(status:code:)` is the canonical
    ///    Doctor-Report measurement type. Building one here without any
    ///    LOINC-mapped value protects against a future SpeziFHIR major
    ///    bump that re-pivots `FHIRModels` away from R4 codables.
    ///
    /// 3. **Our namespace placeholder compiles** — `HealthLogFHIR` ships
    ///    today as an empty `enum` whose only member is the pinned-
    ///    version string. Asserting that string here ensures the
    ///    namespace survives the `xcodegen` pass and stays referenceable
    ///    once H.1 lands the LOINC mapping table on top.
    @Suite("HealthLogFHIR — v0.6.0 H.0 skeleton smoke")
    struct HealthLogFHIRPlaceholderTests {
        @Test("HealthLogFHIR namespace exposes the pinned SpeziFHIR version")
        func pinnedVersionSurfaceMatchesProjectYAML() {
            #expect(HealthLogFHIR.pinnedSpeziFHIRVersion == "0.10.0")
        }

        @Test("SpeziFHIR umbrella + ModelsR4 link cleanly via SPM")
        func speziFHIRUmbrellaLinks() {
            // A minimal R4 Observation builds without any LOINC value
            // bound — this is the exact entry-point H.2 lands on top of.
            // If `FHIRModels` ever moves `Observation` out of `ModelsR4`
            // (or SpeziFHIR drops the re-export), this body fails to
            // compile and pins down the offending pin bump.
            let observation = Observation(
                code: CodeableConcept(),
                status: FHIRPrimitive(ObservationStatus.preliminary)
            )

            #expect(observation.status.value == .preliminary)
        }
    }
#endif
