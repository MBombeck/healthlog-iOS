// HealthKit-Symbole — bleibt aus dem SPM-Test-Build raus.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// #113 / public #7 — the two halves of the percent contract, tested together.
    ///
    /// Until 1.0.4 each side only tested its own half: the server fed a raw `0.97`
    /// into its mapper, the app asserted that `0.97` left the phone as `97`. Both
    /// passed, and every SpO2 and body-fat reading was rejected as
    /// `value_out_of_range` in between. This suite runs a real `HKQuantitySample`
    /// through the production wire converter and then through the server's
    /// conversion and plausibility range as the v1.39.0 fixture records them
    /// (`Fixtures/Server/v1.39.0/percent-fraction-contract.json`, taken from
    /// `apple-health-mapping.ts`, `validations/measurement.ts` and the OpenAPI
    /// `AppleHealthBatchEntry.unit` description at that tag).
    @Suite("Percent fraction wire contract (#113)")
    struct PercentFractionWireContractTests {
        struct Fixture: Decodable {
            struct Rule: Decodable {
                let fractionCeiling: Double
                let factor: Double
            }

            struct Range: Decodable {
                let min: Double
                let max: Double
            }

            struct TypeRow: Decodable {
                let hkIdentifier: String
                let measurementType: String
                let range: Range
            }

            struct Case: Decodable {
                let hkIdentifier: String
                let healthKitFraction: Double
                let wireValue: Double
                let storedValue: Double
            }

            let serverTag: String
            let openapiQuote: String
            let percentFromFraction: Rule
            let types: [TypeRow]
            let cases: [Case]
        }

        static func loadFixture(file: String = #filePath) throws -> Fixture {
            let repoRoot = URL(fileURLWithPath: file)
                .deletingLastPathComponent() // Contracts
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repository root
            let url = repoRoot
                .appendingPathComponent("HealthLogTests/Fixtures/Server/v1.39.0/percent-fraction-contract.json")
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        }

        /// The server's `percentFromFraction` at v1.39.0, as the fixture states it:
        /// a value above the fraction ceiling is already a percent and passes
        /// through, anything else is scaled.
        static func stored(_ wire: Double, rule: Fixture.Rule) -> Double {
            wire > rule.fractionCeiling ? wire : wire * rule.factor
        }

        private static func sample(_ identifier: String, fraction: Double) throws -> HKQuantitySample {
            let type = try #require(HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)))
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .percent(), doubleValue: fraction),
                start: Date(timeIntervalSince1970: 1_726_300_800),
                end: Date(timeIntervalSince1970: 1_726_300_800)
            )
        }

        @Test("the fixture is the v1.39.0 contract and names the 0.98 → 98 example")
        func fixtureIsTheV139Contract() throws {
            let fixture = try Self.loadFixture()
            #expect(fixture.serverTag == "v1.39.0")
            #expect(fixture.openapiQuote.contains("an oxygen saturation sent as `0.98` in `fraction` is stored as `98`"))
            #expect(Set(fixture.types.map(\.hkIdentifier)) == [
                HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                HKQuantityTypeIdentifier.bodyFatPercentage.rawValue
            ])
        }

        @Test("HealthKit 0.97 SpO2 goes on the wire as 0.97 and the server stores 97")
        func spo2PointNinetySevenIsStoredAsNinetySeven() throws {
            let fixture = try Self.loadFixture()
            let spo2 = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
            let entry = try #require(
                HealthKitWireConverter.entries(from: Self.sample(spo2, fraction: 0.97)).first
            )
            #expect(abs(entry.value - 0.97) < 0.000_001)
            #expect(HealthKitWireConverter.preferredUnit(for: spo2)?.scale == 1)

            let stored = Self.stored(entry.value, rule: fixture.percentFromFraction)
            #expect(abs(stored - 97) < 0.000_001)
            let range = try #require(fixture.types.first { $0.hkIdentifier == spo2 }?.range)
            #expect((range.min ... range.max).contains(stored))
        }

        @Test("every fixture case: wire value, stored value, inside the server range")
        func everyCaseLandsInRange() throws {
            let fixture = try Self.loadFixture()
            for testCase in fixture.cases {
                let entry = try #require(
                    HealthKitWireConverter.entries(
                        from: Self.sample(testCase.hkIdentifier, fraction: testCase.healthKitFraction)
                    ).first
                )
                #expect(abs(entry.value - testCase.wireValue) < 0.000_001, "\(testCase.hkIdentifier)")
                let stored = Self.stored(entry.value, rule: fixture.percentFromFraction)
                #expect(abs(stored - testCase.storedValue) < 0.000_001, "\(testCase.hkIdentifier)")
                let range = try #require(fixture.types.first { $0.hkIdentifier == testCase.hkIdentifier }?.range)
                #expect((range.min ... range.max).contains(stored), "\(testCase.hkIdentifier)")
            }
        }

        @Test("the raw fraction also lands in range on a server older than v1.38.25 (unconditional ×100)")
        func fractionIsSafeOnPreFixServers() throws {
            let fixture = try Self.loadFixture()
            for testCase in fixture.cases {
                let entry = try #require(
                    HealthKitWireConverter.entries(
                        from: Self.sample(testCase.hkIdentifier, fraction: testCase.healthKitFraction)
                    ).first
                )
                // v1.38.24 `convertToDbUnit: (v) => v * 100`. The 1.0.3 wire value
                // (already ×100) left this range; the raw fraction does not.
                let preFixStored = entry.value * fixture.percentFromFraction.factor
                let range = try #require(fixture.types.first { $0.hkIdentifier == testCase.hkIdentifier }?.range)
                #expect((range.min ... range.max).contains(preFixStored), "\(testCase.hkIdentifier)")
            }
        }
    }

#endif
