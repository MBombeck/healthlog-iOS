#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **HK-NEW (1.5, #149) — the six Apple Health types the server maps
    /// since v1.44.0.**
    ///
    /// Pinned against `src/lib/measurements/apple-health-mapping.ts` at
    /// HealthLog `v1.47.0`: identifier, wire value and unit, `externalId`, and
    /// the server type each one lands on. A server before v1.44 is sent and
    /// asked nothing; a server that publishes `acceptedTypes` decides itself.
    @Suite("HK-NEW — server v1.44 Apple Health types")
    struct HealthKitServer144TypesTests {
        private static let start = Date(timeIntervalSince1970: 1_790_000_000)

        private static func defaults(version: String?) throws -> UserDefaults {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.hknew.\(UUID().uuidString)"))
            if let version {
                HealthKitServerTypeGate.record(ServerVersionInfo(version: version), defaults: defaults)
            }
            return defaults
        }

        // MARK: - (a) wire format per type

        @Test("exercise minutes: minutes, own uuid, the server's identifier")
        func exerciseMinutes() throws {
            let sample = HKQuantitySample(
                type: HKQuantityType(.appleExerciseTime),
                quantity: HKQuantity(unit: .minute(), doubleValue: 32),
                start: Self.start,
                end: Self.start.addingTimeInterval(32 * 60)
            )
            let entry = try #require(HealthKitWireConverter.entries(from: sample).first)
            #expect(entry.hkIdentifier == "HKQuantityTypeIdentifierAppleExerciseTime")
            #expect(entry.unit == "min")
            #expect(entry.value == 32)
            #expect(entry.externalId == sample.uuid.uuidString)
            #expect(HealthSampleReplayFloor.serverType[entry.hkIdentifier] == "EXERCISE_MINUTES")
        }

        @Test("stand minutes: minutes, the server's identifier")
        func standMinutes() throws {
            let sample = HKQuantitySample(
                type: HKQuantityType(.appleStandTime),
                quantity: HKQuantity(unit: .second(), doubleValue: 300),
                start: Self.start,
                end: Self.start.addingTimeInterval(300)
            )
            let entry = try #require(HealthKitWireConverter.entries(from: sample).first)
            #expect(entry.hkIdentifier == "HKQuantityTypeIdentifierAppleStandTime")
            #expect(entry.unit == "min")
            #expect(entry.value == 5)
            #expect(entry.externalId == sample.uuid.uuidString)
            #expect(HealthSampleReplayFloor.serverType[entry.hkIdentifier] == "STAND_MINUTES")
        }

        @Test("stand hour: a stood hour is one row with value 1, an idle hour is never a row")
        func standHour() throws {
            let stood = HKCategorySample(
                type: HKCategoryType(.appleStandHour),
                value: HKCategoryValueAppleStandHour.stood.rawValue,
                start: Self.start,
                end: Self.start.addingTimeInterval(3600)
            )
            let entry = try #require(HealthKitWireConverter.entries(from: stood).first)
            #expect(entry.hkIdentifier == "HKCategoryTypeIdentifierAppleStandHour")
            #expect(entry.value == 1)
            #expect(entry.unit == "count")
            #expect(entry.externalId == stood.uuid.uuidString)
            #expect(HealthSampleReplayFloor.serverType[entry.hkIdentifier] == "STAND_HOURS")

            let idle = HKCategorySample(
                type: HKCategoryType(.appleStandHour),
                value: HKCategoryValueAppleStandHour.idle.rawValue,
                start: Self.start,
                end: Self.start.addingTimeInterval(3600)
            )
            #expect(HealthKitWireConverter.entries(from: idle).isEmpty)
        }

        @Test("mindful session: the length in minutes from start and end")
        func mindfulSession() throws {
            let sample = HKCategorySample(
                type: HKCategoryType(.mindfulSession),
                value: HKCategoryValue.notApplicable.rawValue,
                start: Self.start,
                end: Self.start.addingTimeInterval(10 * 60)
            )
            let entry = try #require(HealthKitWireConverter.entries(from: sample).first)
            #expect(entry.hkIdentifier == "HKCategoryTypeIdentifierMindfulSession")
            #expect(entry.unit == "min")
            #expect(abs(entry.value - 10) < 0.000_001)
            #expect(entry.externalId == sample.uuid.uuidString)
            #expect(HealthSampleReplayFloor.serverType[entry.hkIdentifier] == "MINDFUL_MINUTES")
        }

        @Test("AFib burden: the raw fraction, never pre-scaled (the server refuses anything above 1)")
        func afibBurden() throws {
            let sample = HKQuantitySample(
                type: HKQuantityType(.atrialFibrillationBurden),
                quantity: HKQuantity(unit: .percent(), doubleValue: 0.02),
                start: Self.start,
                end: Self.start.addingTimeInterval(7 * 86400)
            )
            let entry = try #require(HealthKitWireConverter.entries(from: sample).first)
            #expect(entry.hkIdentifier == "HKQuantityTypeIdentifierAtrialFibrillationBurden")
            #expect(entry.unit == "%")
            #expect(abs(entry.value - 0.02) < 0.000_001)
            #expect(entry.value <= 1, "the server scales ×100 and refuses a value above 1")
            #expect(entry.externalId == sample.uuid.uuidString)
            #expect(HealthSampleReplayFloor.serverType[entry.hkIdentifier] == "AFIB_BURDEN")
        }

        @Test("State of Mind: valence as is, under the server's spelling of the identifier")
        func stateOfMind() throws {
            let sample = HKStateOfMind(
                date: Self.start,
                kind: .momentaryEmotion,
                valence: -0.4,
                labels: [.anxious],
                associations: [.work]
            )
            let entry = try #require(StateOfMindValencePolicy.entry(
                for: sample,
                appBundleIdentifier: "com.example.another.app",
                moodImportOn: false
            ))
            #expect(entry.hkIdentifier == "HKDataTypeIdentifierStateOfMind")
            #expect(entry.hkIdentifier != HKObjectType.stateOfMindType().identifier)
            #expect(entry.unit == "valence")
            #expect(abs(entry.value - -0.4) < 0.000_001)
            #expect(entry.externalId == sample.uuid.uuidString)
            #expect(HealthSampleReplayFloor.serverType[HKObjectType.stateOfMindType().identifier] == "STATE_OF_MIND_VALENCE")
        }

        @Test("the run-time State of Mind identifier is the registry key, and the resolver knows it")
        func stateOfMindIdentifiers() throws {
            #expect(HKObjectType.stateOfMindType().identifier == HealthKitServer144Types.stateOfMindRuntimeIdentifier)
            let resolved = try #require(HealthKitSampleTypeResolver.sampleType(for: HealthKitServer144Types.stateOfMindRuntimeIdentifier))
            #expect(resolved == HKObjectType.stateOfMindType())
            #expect(HealthKitSampleTypeResolver.sampleType(for: "HKDataTypeNotAThing") == nil)
            #expect(HKSyncDiagnostics.metricKind(for: HealthKitServer144Types.stateOfMindWireIdentifier) == .stateOfMindValence)
            #expect(HKSyncDiagnostics.metricKind(for: HealthKitServer144Types.stateOfMindRuntimeIdentifier) == .stateOfMindValence)
        }

        // MARK: - Collection, sheets and catalogue

        @Test("all six are server-bound, the five new reads are in the onboarding sheet, none is written")
        func registryAndSheets() {
            #expect(HealthLogSampleTypeRegistry.baseIdentifiers.isSuperset(of: HealthKitServer144Types.registryIdentifiers))
            #expect(HealthLogSampleTypeRegistry.baseExpectedCount == HealthLogSampleTypeRegistry.baseIdentifiers.count)
            let read = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            #expect(read.isSuperset(of: HealthKitServer144Types.registryIdentifiers))
            let write = Set(HealthKitService.defaultWriteTypes.map(\.identifier))
            #expect(write.isDisjoint(with: HealthKitServer144Types.lateReadIdentifiers))
            for identifier in HealthKitServer144Types.lateReadIdentifiers {
                #expect(HealthAccessTypeNaming.localizationKey(for: identifier) != nil, "\(identifier)")
                #expect(HKSyncDiagnostics.metricKind(for: identifier) != nil, "\(identifier)")
            }
        }

        @Test("the two ring minutes go the day-total way like daylight, with no hour rows")
        func ringMinutesAreDayTotals() {
            for identifier in HealthKitServer144Types.cumulativeIdentifiers {
                #expect(HealthKitCumulativeTypeConfig.cumulativeIdentifiers.contains(identifier))
                let config = HealthKitCumulativeTypeConfig.defaults.first { $0.identifier == identifier }
                #expect(config?.wireUnit == "minutes")
                #expect(!HealthKitHourlyStatRow.identifiers.contains(identifier))
            }
        }

        @Test("each server type decodes onto its own kind, with a title, unit and symbol")
        func catalogue() {
            let pairs: [(String, MetricKind)] = [
                ("EXERCISE_MINUTES", .exerciseMinutes),
                ("STAND_MINUTES", .standMinutes),
                ("STAND_HOURS", .standHours),
                ("MINDFUL_MINUTES", .mindfulMinutes),
                ("STATE_OF_MIND_VALENCE", .stateOfMindValence),
                ("AFIB_BURDEN", .afibBurden)
            ]
            for (wire, kind) in pairs {
                #expect(ServerMeasurementType(rawValue: wire)?.metricKind == kind, "\(wire)")
                #expect(kind.availabilitySummaryKey == wire)
                let descriptor = MetricKindDescriptor.descriptor(for: kind)
                #expect(descriptor.kind == kind)
                #expect(!descriptor.sfSymbol.isEmpty)
            }
            #expect(MetricKind.exerciseMinutes.isCumulative)
            #expect(MetricKind.standHours.isCumulative)
            #expect(!MetricKind.afibBurden.isCumulative)
            #expect(!MetricKind.stateOfMindValence.isCumulative)
        }

        @Test("mindful minutes, the valence and AFib burden never reach a coach prompt")
        func modelFence() {
            #expect(!MetricKind.coachCases.contains(.mindfulMinutes))
            #expect(!MetricKind.coachCases.contains(.stateOfMindValence))
            #expect(!MetricKind.coachCases.contains(.afibBurden))
            #expect(MetricKind.coachCases.contains(.exerciseMinutes))
            #expect(MetricKind.coachCases.contains(.steps))
        }

        // MARK: - Server version, "Server 1.43 gets nothing"

        @Test("server 1.43 or unknown: none of the six is collected; 1.44 and later: all six")
        func serverVersionGate() throws {
            for version in [nil, "1.43.10"] {
                let defaults = try Self.defaults(version: version)
                for identifier in HealthKitServer144Types.registryIdentifiers {
                    #expect(
                        !HealthKitServerTypeGate.serverAccepts(identifier, defaults: defaults),
                        "\(identifier) @ \(version ?? "unknown")"
                    )
                }
                #expect(HealthKitServerTypeGate.serverAccepts(HKQuantityTypeIdentifier.stepCount.rawValue, defaults: defaults))
            }
            for version in ["1.44.0", "1.47.0"] {
                let defaults = try Self.defaults(version: version)
                for identifier in HealthKitServer144Types.registryIdentifiers {
                    #expect(HealthKitServerTypeGate.serverAccepts(identifier, defaults: defaults), "\(identifier) @ \(version)")
                }
            }
        }

        @Test("server 1.43: the collector leaves them out and the day totals skip the ring minutes")
        func collectorAndDayTotalsFollowTheGate() throws {
            let old = try Self.defaults(version: "1.43.10")
            let collected = AppOwnedHealthCollectionCoordinator.serverCollectable(
                HealthLogSampleTypeRegistry.baseIdentifiers.sorted()
            ) { HealthKitServerTypeGate.serverAccepts($0, defaults: old) }
            #expect(Set(collected).isDisjoint(with: HealthKitServer144Types.registryIdentifiers))
            #expect(collected.contains(HKQuantityTypeIdentifier.stepCount.rawValue))
            let configs = HealthKitCumulativeTypeConfig.serverCollectable { HealthKitServerTypeGate.serverAccepts($0, defaults: old) }
            #expect(Set(configs.map(\.identifier)).isDisjoint(with: HealthKitServer144Types.cumulativeIdentifiers))
            #expect(configs.count == HealthKitCumulativeTypeConfig.defaults.count - 2)

            let new = try Self.defaults(version: "1.44.0")
            let all = HealthKitCumulativeTypeConfig.serverCollectable { HealthKitServerTypeGate.serverAccepts($0, defaults: new) }
            #expect(all.count == HealthKitCumulativeTypeConfig.defaults.count)
        }

        // MARK: - (d) acceptedTypes present and absent

        @Test("without acceptedTypes the table decides; deferred types are never accepted")
        func withoutAcceptedTypes() throws {
            let defaults = try Self.defaults(version: "1.47.0")
            HealthKitAcceptedTypes.record(nil, defaults: defaults)
            #expect(HealthKitAcceptedTypes.recorded(defaults: defaults) == nil)
            #expect(HealthKitServerTypeGate.serverAccepts(HealthKitServer144Types.afibBurden, defaults: defaults))
            for identifier in HealthKitAcceptedTypes.deferredIdentifiers {
                #expect(!HealthKitServerTypeGate.serverAccepts(identifier, defaults: defaults), "\(identifier)")
            }
            // Deferred types are not asked for and not collected.
            let read = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            #expect(read.isDisjoint(with: HealthKitAcceptedTypes.deferredIdentifiers))
            #expect(HealthLogSampleTypeRegistry.knownIdentifiers.isDisjoint(with: HealthKitAcceptedTypes.deferredIdentifiers))
        }

        @Test("with acceptedTypes the server decides, State of Mind by its wire spelling, whatever the version")
        func withAcceptedTypes() throws {
            let defaults = try Self.defaults(version: "1.43.0")
            HealthKitAcceptedTypes.record([
                "HKQuantityTypeIdentifierStepCount",
                "HKQuantityTypeIdentifierAppleExerciseTime",
                "HKDataTypeIdentifierStateOfMind"
            ], defaults: defaults)
            #expect(HealthKitServerTypeGate.serverAccepts(HealthKitServer144Types.exerciseTime, defaults: defaults))
            #expect(HealthKitServerTypeGate.serverAccepts(HealthKitServer144Types.stateOfMindRuntimeIdentifier, defaults: defaults))
            #expect(!HealthKitServerTypeGate.serverAccepts(HealthKitServer144Types.afibBurden, defaults: defaults))
            #expect(!HealthKitServerTypeGate.serverAccepts(HKQuantityTypeIdentifier.bodyMass.rawValue, defaults: defaults))

            // Pointing the app at another server forgets the list with the version.
            HealthKitServerTypeGate.forget(defaults: defaults)
            #expect(HealthKitAcceptedTypes.recorded(defaults: defaults) == nil)
        }

        @Test("the GET field decodes when present and is nil when absent; PATCH never sends it")
        func configDecoding() throws {
            let decoder = JSONDecoder()
            let without = try decoder.decode(
                HealthKitSyncConfig.self,
                from: Data(#"{"entries":[]}"#.utf8)
            )
            #expect(without.acceptedTypes == nil)
            let with = try decoder.decode(
                HealthKitSyncConfig.self,
                from: Data(#"{"entries":[],"acceptedTypes":["HKQuantityTypeIdentifierAppleStandTime"]}"#.utf8)
            )
            #expect(with.acceptedTypes == ["HKQuantityTypeIdentifierAppleStandTime"])
            let malformed = try decoder.decode(
                HealthKitSyncConfig.self,
                from: Data(#"{"entries":[],"acceptedTypes":"all"}"#.utf8)
            )
            #expect(malformed.acceptedTypes == nil)
            let encoded = try #require(String(data: JSONEncoder().encode(with), encoding: .utf8))
            #expect(!encoded.contains("acceptedTypes"))
            #expect(HealthKitSyncConfig(entries: [], lastSyncedAt: nil).keepingReadFields(of: with).acceptedTypes == with.acceptedTypes)

            let defaults = try Self.defaults(version: nil)
            _ = HealthKitAcceptedTypes.recording(with, defaults: defaults)
            #expect(HealthKitAcceptedTypes.recorded(defaults: defaults) == ["HKQuantityTypeIdentifierAppleStandTime"])
            _ = HealthKitAcceptedTypes.recording(without, defaults: defaults)
            #expect(HealthKitAcceptedTypes.recorded(defaults: defaults) == nil)
        }
    }
#endif
