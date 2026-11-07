#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **REG (1.5) — public #12, #13, #14 (BernhardBuckel): the pulse was gone
    /// after the switch to 10-minute buckets, types the server maps were never
    /// asked for, RMSSD.**
    ///
    /// #13 against the server's own list: the keys of `APPLE_HEALTH_TYPE_MAP` at
    /// server v1.47.0, checked in as a fixture. The server looks a batch row up
    /// by exactly that string, so the test compares the NAME ON THE WIRE, not
    /// the type: every type the server maps is asked for under a name it
    /// knows, and every type the app sends goes out under one.
    ///
    /// REG found the case this exists for: the environmental audio exposure
    /// event is `HKCategoryTypeIdentifierAudioExposureEvent` at run time (the
    /// constant kept its pre-iOS-14 string), the server maps
    /// `…EnvironmentalAudioExposureEvent`, and every such event was skipped as
    /// `unmappable_identifier`. State of Mind has the same shape and was
    /// already translated. Both now go through one table,
    /// `HealthKitServer144Types.wireNames`.
    ///
    /// RMSSD joins the set only where the system has it (iOS 27); the
    /// server-version gate before anything is sent is
    /// `HealthKitServerTypeGateTests`. #12 (buckets after the switch) and #14
    /// (RMSSD) are linked in the index: `HRBucketNoNeitherDayTests`,
    /// `HeartRateVariabilityRMSSDTests`.
    @Suite("REG public #13: every type goes out under a name the server maps")
    struct Regression_public_13 {
        private struct Fixture: Decodable {
            let source: String
            let identifiers: [String]
        }

        private static func serverNames(file: String = #filePath) throws -> Set<String> {
            let url = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/server-v1.47.0-apple-health-type-map.json")
            let names = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).identifiers
            #expect(names.count == 50, "the fixture is the v1.47.0 list; refresh it with the server tag")
            return Set(names)
        }

        /// Only on a system older than iOS 27, where the type does not exist.
        private static let rmssd = "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"

        /// The wire names of everything in the first Health sheet.
        private static var askedWireNames: Set<String> {
            Set(HealthKitService.defaultReadTypes.map { HealthKitServer144Types.wireIdentifier(forRegistry: $0.identifier) })
        }

        @Test("every type the server maps is asked for, under the name the server maps")
        func readSetCoversServerMap() throws {
            var missing = try Self.serverNames().subtracting(Self.askedWireNames)
            if HeartRateVariabilityRMSSD.sampleType == nil { missing.remove(Self.rmssd) }
            #expect(missing.isEmpty, "mapped by the server, never asked for under that name: \(missing.sorted())")
        }

        @Test("every type read for the measurement batch goes out under a name the server maps")
        func everyWireNameIsAServerKey() throws {
            // Workouts and ECGs have routes of their own (`/api/workouts/batch`,
            // `/api/ecg`) and never reach the measurement batch.
            let ownRoutes: Set<String> = [HKObjectType.workoutType().identifier, HKObjectType.electrocardiogramType().identifier]
            let unknown = try Self.askedWireNames.subtracting(ownRoutes).subtracting(Self.serverNames())
            #expect(unknown.isEmpty, "sent under a name the server does not map: \(unknown.sorted())")
        }

        @Test("the heart-event path sends the environmental audio exposure event under the server's name")
        func audioExposureEventWireName() throws {
            let type = HKCategoryType(.environmentalAudioExposureEvent)
            // The run-time string is the old one; that is the whole defect.
            #expect(type.identifier == "HKCategoryTypeIdentifierAudioExposureEvent")
            let start = Date(timeIntervalSince1970: 1_762_300_000)
            let sample = HKCategorySample(
                type: type,
                value: HKCategoryValueEnvironmentalAudioExposureEvent.momentaryLimit.rawValue,
                start: start,
                end: start.addingTimeInterval(180)
            )
            let entry = try #require(HeartHealthEventImporter.entry(from: sample))
            #expect(entry.hkIdentifier == "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent")
            #expect(try Self.serverNames().contains(entry.hkIdentifier))
            // Diagnostics still name the row: the wire name maps back.
            #expect(HealthKitServer144Types.registryIdentifier(forWire: entry.hkIdentifier) == type.identifier)
        }

        @Test("on iOS 27 RMSSD is asked for with the rest; before, the set is unchanged")
        func rmssdFollowsTheSystem() {
            let without = Set(HealthKitService.defaultReadTypes(rmssd: nil).map(\.identifier))
            #expect(!without.contains(Self.rmssd))
            if let rmssd = HeartRateVariabilityRMSSD.sampleType {
                let with = Set(HealthKitService.defaultReadTypes(rmssd: rmssd).map(\.identifier))
                #expect(with == without.union([Self.rmssd]))
            }
        }
    }
#endif
