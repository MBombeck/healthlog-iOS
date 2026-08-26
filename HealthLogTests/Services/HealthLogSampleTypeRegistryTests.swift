#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// Phase 07 Wave 2 — the registry is the definition of "server-bound sample
    /// type", so it gets a contract rather than a comment.
    ///
    /// Before this plan the registry's own doc comment said "the 23 entries" while
    /// the literal held 35, and nothing failed. That is exactly the failure mode a
    /// hand-maintained whitelist has: it drifts silently, and the drift is invisible
    /// because the only consumer was a migrator that skipped what it did not
    /// recognise. Now the set decides what the app collects, what arms a change
    /// subscription, and how many owner-scoped cursor partitions exist — so its
    /// cardinality, its uniqueness, and its resolvability are all asserted here.
    @Suite("HealthLog sample type registry")
    struct HealthLogSampleTypeRegistryTests {
        @Test("the registry holds exactly the declared number of server-bound types")
        func cardinalityMatchesTheDeclaredContract() {
            #expect(HealthLogSampleTypeRegistry.expectedCount == 35)
            #expect(HealthLogSampleTypeRegistry.knownIdentifiers.count == HealthLogSampleTypeRegistry.expectedCount)
        }

        @Test("every identifier is unique and non-blank")
        func identifiersAreUniqueAndWellFormed() {
            let identifiers = HealthLogSampleTypeRegistry.knownIdentifiers
            // A `Set` cannot hold a duplicate, so uniqueness is proved against the
            // trimmed forms: two entries differing only by whitespace would be two
            // set members and one HealthKit type.
            let trimmed = Set(identifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            #expect(trimmed.count == identifiers.count)
            #expect(!trimmed.contains(""))
            for identifier in identifiers {
                #expect(identifier.hasPrefix("HK"), "not a HealthKit identifier: \(identifier)")
            }
        }

        @Test("every identifier resolves to a real HealthKit sample type")
        func everyIdentifierResolves() {
            for identifier in HealthLogSampleTypeRegistry.knownIdentifiers {
                #expect(
                    HealthKitSampleTypeResolver.sampleType(for: identifier) != nil,
                    "registry identifier does not resolve: \(identifier)"
                )
            }
        }

        @Test("membership is exact in both directions")
        func membershipIsExact() {
            #expect(HealthLogSampleTypeRegistry.contains(HKQuantityTypeIdentifier.heartRate.rawValue))
            #expect(HealthLogSampleTypeRegistry.contains(HKCategoryTypeIdentifier.sleepAnalysis.rawValue))
            #expect(HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierTimeInDaylight"))
            // Types the app deliberately does not collect per sample.
            #expect(!HealthLogSampleTypeRegistry.contains(HKQuantityTypeIdentifier.bloodAlcoholContent.rawValue))
            #expect(!HealthLogSampleTypeRegistry.contains(HKWorkoutTypeIdentifier))
            #expect(!HealthLogSampleTypeRegistry.contains(""))
        }

        @Test("the collected set and the observed subset are both derived from the registry")
        func collectionSetsAreDerivedFromTheRegistry() {
            #expect(
                Set(AppOwnedHealthCollectionCoordinator.collectedTypeIdentifiers)
                    == HealthLogSampleTypeRegistry.knownIdentifiers
            )
            let observed = Set(AppOwnedHealthCollectionCoordinator.observedTypeIdentifiers)
            #expect(observed.isSubset(of: HealthLogSampleTypeRegistry.knownIdentifiers))
            // The observed subset is the background-delivery set and nothing else:
            // arming a subscription for a low-urgency type would reintroduce the
            // wake cost the W2 battery posture removed.
            for identifier in HealthLogSampleTypeRegistry.knownIdentifiers {
                let armed = observed.contains(identifier)
                #expect(
                    armed == HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: identifier),
                    "observer arming disagrees with the background-delivery policy: \(identifier)"
                )
            }
            #expect(!observed.isEmpty)
        }

        @Test("PROJECT_GUIDE states the same count and no longer calls Spezi the receiver")
        func projectGuideMatchesTheRegistry() throws {
            let guide = try Self.source("PROJECT_GUIDE.md")
            #expect(guide.contains("\(HealthLogSampleTypeRegistry.expectedCount)"))
            #expect(!guide.contains("sole receiver"))
        }

        private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
            let root = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }
    }
#endif
