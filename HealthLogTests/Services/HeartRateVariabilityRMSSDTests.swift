#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// 1.2 / V4 (healthlog-iOS#14, HealthLog#1110, ios-dev#123): HRV as RMSSD
    /// from iOS 27 on, resolved at run time because the app builds against the
    /// iOS 26 SDK.
    ///
    /// The simulator these run on is iOS 26, where the type does not resolve,
    /// so every "on iOS 27" property is pinned through the seam that takes
    /// the platform fact as a parameter, and every "on this system" property
    /// is asserted against whatever the running system resolves.
    @Suite("HRV RMSSD (iOS 27)")
    struct HeartRateVariabilityRMSSDTests {
        private static let rmssd = HeartRateVariabilityRMSSD.identifier
        private static let sdnn = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue

        // MARK: - Identity and server mapping

        @Test("the identifier is Apple's constant name and maps to HRV_RMSSD from server v1.42")
        func identifierAndServerContract() {
            #expect(Self.rmssd == "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD")
            #expect(HeartRateVariabilityRMSSD.serverMeasurementType == "HRV_RMSSD")
            #expect(HeartRateVariabilityRMSSD.minimumServerVersion == "1.42.0")
            // The server type is the one the app already decodes and names.
            let decoded = ServerMeasurementType(rawValue: HeartRateVariabilityRMSSD.serverMeasurementType)
            #expect(decoded == .hrvRMSSD)
            #expect(decoded?.metricKind == .hrvRMSSD)
            #expect(MetricKind.hrvRMSSD.availabilitySummaryKey == HeartRateVariabilityRMSSD.serverMeasurementType)
            #expect(MetricKind.hrvRMSSD.unit == "ms")
            // SDNN stays its own kind on its own server type.
            #expect(MetricKind.hrv.availabilitySummaryKey == "HEART_RATE_VARIABILITY")
        }

        // MARK: - Resolution

        @Test("before iOS 27 the type never resolves, whatever HealthKit would answer")
        func olderSystemNeverResolves() {
            let resolved = HeartRateVariabilityRMSSD.resolve(osSupported: false) { _ in
                HKQuantityType(.heartRateVariabilitySDNN)
            }
            #expect(resolved == nil)
        }

        @Test("on iOS 27 the raw identifier is what HealthKit is asked for")
        func supportedSystemAsksForTheRawIdentifier() {
            var asked: [String] = []
            let standIn = HKQuantityType(.bloodAlcoholContent)
            let resolved = HeartRateVariabilityRMSSD.resolve(osSupported: true) { identifier in
                asked.append(identifier.rawValue)
                return standIn
            }
            #expect(asked == [Self.rmssd])
            #expect(resolved == standIn)
            // And a system that is new enough but does not know the type
            // resolves to nothing rather than to something else.
            #expect(HeartRateVariabilityRMSSD.resolve(osSupported: true) { _ in nil } == nil)
        }

        @Test("on this system the type resolves exactly when the OS supports it")
        func runningSystemAgrees() {
            if !HeartRateVariabilityRMSSD.isOSSupported {
                #expect(HeartRateVariabilityRMSSD.sampleType == nil)
            }
            if let type = HeartRateVariabilityRMSSD.sampleType {
                #expect(type.identifier == Self.rmssd)
            }
        }

        // MARK: - Read authorization set

        @Test("the read set holds RMSSD only when it resolves, and SDNN always")
        func readSetFollowsAvailability() {
            let standIn = HKQuantityType(.bloodAlcoholContent)
            let older = HealthKitService.defaultReadTypes(rmssd: nil)
            let ios27 = HealthKitService.defaultReadTypes(rmssd: standIn)
            #expect(ios27.count == older.count + 1)
            #expect(ios27.contains(standIn))
            #expect(!older.contains(standIn))
            #expect(older.contains(HKQuantityType(.heartRateVariabilitySDNN)))
            #expect(ios27.contains(HKQuantityType(.heartRateVariabilitySDNN)))

            let live = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            #expect(live.contains(Self.rmssd) == (HeartRateVariabilityRMSSD.sampleType != nil))
            if HeartRateVariabilityRMSSD.sampleType == nil {
                // Older systems: exactly the set they asked for before.
                #expect(HealthKitService.defaultReadTypes == older)
            }
        }

        @Test("RMSSD is read-only: the write set never gains it")
        func writeSetUnchanged() {
            let writes = Set(HealthKitService.defaultWriteTypes.map(\.identifier))
            #expect(!writes.contains(Self.rmssd))
            #expect(writes.contains(Self.sdnn))
        }

        @Test("the transparency list names it HRV (RMSSD)")
        func transparencyName() {
            #expect(HealthAccessTypeNaming.localizationKey(for: Self.rmssd) != nil)
            #expect(HealthAccessTypeNaming.displayName(for: Self.rmssd) == "HRV (RMSSD)")
        }

        // MARK: - Wire

        @Test("the wire carries milliseconds, unscaled, exactly like SDNN")
        func wireUnitIsMilliseconds() throws {
            let rmssd = try #require(HealthKitWireConverter.preferredUnit(for: Self.rmssd))
            #expect(rmssd.wireSymbol == "ms")
            #expect(rmssd.scale == 1)
            #expect(rmssd.hkUnit == .secondUnit(with: .milli))
            let sdnn = try #require(HealthKitWireConverter.preferredUnit(for: Self.sdnn))
            #expect(sdnn == HealthKitWireConverter.WireUnit(hkUnit: .secondUnit(with: .milli), wireSymbol: "ms", scale: 1))
        }

        @Test("delivery follows SDNN, and diagnostics map it only where it is read")
        func deliveryAndDiagnostics() {
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: Self.rmssd))
            #expect(HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: Self.sdnn))
            #expect(HKSyncDiagnostics.metricKind(for: Self.sdnn) == .hrv)
            let expected: MetricKind? = HeartRateVariabilityRMSSD.sampleType == nil ? nil : .hrvRMSSD
            #expect(HKSyncDiagnostics.metricKind(for: Self.rmssd) == expected)
        }
    }

    // MARK: - Server gate

    /// A server before v1.42 would answer `skipped(unmappable_identifier)`.
    /// The type is not collected until the server is known to store it, so
    /// such a server never produces a skip, a parked row or a warning.
    @Suite("HRV RMSSD server gate")
    struct HealthKitServerTypeGateTests {
        private static func makeDefaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "hl.tests.v4.gate.\(UUID().uuidString)"))
        }

        @Test("unknown and older servers do not get RMSSD; v1.42 and later do")
        func versionThreshold() throws {
            let defaults = try Self.makeDefaults()
            let rmssd = HeartRateVariabilityRMSSD.identifier
            #expect(!HealthKitServerTypeGate.serverAccepts(rmssd, defaults: defaults))
            for (version, accepts) in [
                ("1.41.2", false), ("1.41.99", false), ("v1.42.0", true),
                ("1.42.0", true), ("1.42.3-rc.1", true), ("1.43.0", true), ("garbage", false)
            ] {
                HealthKitServerTypeGate.record(ServerVersionInfo(version: version), defaults: defaults)
                #expect(HealthKitServerTypeGate.serverAccepts(rmssd, defaults: defaults) == accepts, "\(version)")
            }
            HealthKitServerTypeGate.forget(defaults: defaults)
            #expect(!HealthKitServerTypeGate.serverAccepts(rmssd, defaults: defaults))
        }

        @Test("every other type, SDNN included, is never gated")
        func otherTypesPass() throws {
            let defaults = try Self.makeDefaults()
            for identifier in HealthLogSampleTypeRegistry.baseIdentifiers {
                #expect(HealthKitServerTypeGate.serverAccepts(identifier, defaults: defaults), "\(identifier)")
            }
            HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.30.0"), defaults: defaults)
            #expect(HealthKitServerTypeGate.serverAccepts(HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue, defaults: defaults))
        }

        @Test("a pass neither queries nor observes RMSSD before v1.42, and does from v1.42 on")
        func passWaitsForTheServer() throws {
            let defaults = try Self.makeDefaults()
            let rmssd = HeartRateVariabilityRMSSD.identifier
            let sdnn = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
            let ios27 = HealthLogSampleTypeRegistry.baseIdentifiers
                .union(HealthLogSampleTypeRegistry.osGatedIdentifiers(rmssdAvailable: true))
                .sorted()
            let gate = { (identifier: String) in HealthKitServerTypeGate.serverAccepts(identifier, defaults: defaults) }

            HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.41.2"), defaults: defaults)
            let old = AppOwnedHealthCollectionCoordinator.serverCollectable(ios27, serverAccepts: gate)
            #expect(!old.contains(rmssd))
            #expect(old.contains(sdnn))
            #expect(old.count == 35)

            HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.42.0"), defaults: defaults)
            let new = AppOwnedHealthCollectionCoordinator.serverCollectable(ios27, serverAccepts: gate)
            #expect(new == ios27)
            #expect(new.count == 36)
        }

        @Test("on this system the pass collects the registry minus what the server cannot store")
        func livePassIsTheRegistry() {
            let live = AppOwnedHealthCollectionCoordinator.serverCollectable(
                AppOwnedHealthCollectionCoordinator.collectedTypeIdentifiers
            )
            #expect(Set(live).isSubset(of: HealthLogSampleTypeRegistry.knownIdentifiers))
            #expect(Set(HealthLogSampleTypeRegistry.baseIdentifiers).isSubset(of: Set(live)))
        }
    }
#endif
