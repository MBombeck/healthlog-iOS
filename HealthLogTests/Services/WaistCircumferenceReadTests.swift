#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **B5 (1.4) — waist circumference from Apple Health.**
    ///
    /// The server maps `HKQuantityTypeIdentifierWaistCircumference` to
    /// `WAIST_CIRCUMFERENCE` since v1.25.0, with `hkUnit: "m"` and a ×100
    /// conversion to centimetres (`APPLE_HEALTH_TYPE_MAP`,
    /// `src/lib/measurements/apple-health-mapping.ts`, read at v1.43.10). The
    /// app knew the measurement but never read it from Apple Health. It is now
    /// one more server-bound sample type: in the registry, in the read sheet,
    /// on the permission list, sent in metres. It is read only; HealthLog does
    /// not write waist readings into Apple Health.
    @Suite("B5 — waist circumference read from Apple Health")
    struct WaistCircumferenceReadTests {
        private static let identifier = HKQuantityTypeIdentifier.waistCircumference.rawValue

        @Test("waist is a server-bound sample type and is in the read sheet, not the write sheet")
        func registryAndSheets() {
            #expect(HealthLogSampleTypeRegistry.contains(Self.identifier))
            #expect(HealthLogSampleTypeRegistry.baseIdentifiers.contains(Self.identifier))
            let read = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            #expect(read.contains(Self.identifier))
            let write = Set(HealthKitService.defaultWriteTypes.map(\.identifier))
            #expect(!write.contains(Self.identifier))
        }

        @Test("a waist sample goes on the wire in metres, as the server's mapping expects")
        func wireUnitIsMetres() throws {
            let sample = HKQuantitySample(
                type: HKQuantityType(.waistCircumference),
                quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: 86),
                start: Date(timeIntervalSince1970: 1_790_000_000),
                end: Date(timeIntervalSince1970: 1_790_000_000)
            )
            let entry = try #require(HealthKitWireConverter.entries(from: sample).first)
            #expect(entry.hkIdentifier == Self.identifier)
            #expect(entry.unit == "m")
            #expect(abs(entry.value - 0.86) < 0.000_001)
        }

        @Test("the permission list names it, and the replay shortcut knows its server type")
        func namedAndMapped() {
            #expect(HealthAccessTypeNaming.localizationKey(for: Self.identifier) != nil)
            #expect(HealthSampleReplayFloor.serverType[Self.identifier] == "WAIST_CIRCUMFERENCE")
            #expect(HealthKitServerTypeGate.serverAccepts(Self.identifier))
        }
    }
#endif
