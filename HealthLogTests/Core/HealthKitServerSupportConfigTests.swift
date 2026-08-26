// W2 — server-support contract config.
// Pins the single source of truth for which HK identifiers the server can
// persist today, the re-enable flag default, and the gate semantics that both
// the registration gate (`HealthLogSpeziDelegate`) and the anchor-decision
// defense (`HealthKitService.uploadAndDecide`) rely on.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    @testable import HealthLog
    import Testing

    @Suite("HealthKitServerSupportConfig — deferred-types contract")
    struct HealthKitServerSupportConfigTests {
        @Test("Gate is now empty — every authorized HK type persists (server v1.6.0)")
        func deferredIdentifierSetIsEmpty() {
            // v0.8.4 W-WALK — the last two operator-requested gait types
            // (walkingStepLength + walkingSpeed) landed server-side in v1.6.0,
            // so the deferred set is now empty: no authorized HK identifier is
            // gated. The two-layer defense stays wired for future gating.
            let unsupported = HealthKitServerSupportConfig.serverUnsupportedIdentifiers
            #expect(unsupported.isEmpty)
        }

        @Test("The two W-WALK gait types are now ungated (server v1.6.0)")
        func gaitTypesAreUngated() {
            // walkingStepLength + walkingSpeed were re-enabled when the server
            // landed their `apple-health-mapping` rows. They must collect +
            // upload + persist normally now.
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierWalkingStepLength"))
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierWalkingSpeed"))
        }

        @Test("The four server v1.5.5 types are still ungated")
        func newlyMappedTypesAreUngated() {
            // respiratoryRate, bodyMassIndex, walkingAsymmetry,
            // walkingDoubleSupport were re-enabled when the server landed
            // their mappings. They must collect + upload normally now.
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierRespiratoryRate"))
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierBodyMassIndex"))
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierWalkingAsymmetryPercentage"))
            #expect(!HealthKitServerSupportConfig
                .isServerUnsupported("HKQuantityTypeIdentifierWalkingDoubleSupportPercentage"))
        }

        @Test("isServerUnsupported gates nothing now — common types stay ungated")
        func gatesNothing() {
            // A server-supported type is never gated.
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierHeartRate"))
            #expect(!HealthKitServerSupportConfig.isServerUnsupported("HKQuantityTypeIdentifierStepCount"))
        }

        @Test("Skip-reason constants match the server batch-route contract")
        func skipReasonConstantsMatchServer() {
            #expect(HealthKitServerSupportConfig.reasonUnmappableIdentifier == "unmappable_identifier")
            #expect(HealthKitServerSupportConfig.reasonValueOutOfRange == "value_out_of_range")
        }
    }

#endif
