import Foundation
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

@testable import HealthLog

#if canImport(HealthKit)

    /// Unit-tests fuer die pure-compute Hilfen + die Locked-Format-Guarantees.
    /// Die HK-Query-Pfade (`runStatisticsCollection`) testen wir in den
    /// Integration-Tests gegen einen `HKHealthStore` — hier nur das was
    /// ohne HK-Runtime laufen kann.
    @Suite("HealthKitStatisticsService — Locked externalId + dayKey")
    struct HealthKitStatisticsServiceTests {
        // MARK: - HealthKitDailyStatRow.externalId

        @Test("externalId locked format — StepCount")
        func externalIdStepCount() {
            let row = HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: Date(timeIntervalSince1970: 0),
                dayKey: "2026-05-16",
                value: 8345,
                unit: "steps"
            )
            #expect(row.externalId == "stats:HKQuantityTypeIdentifierStepCount:2026-05-16")
        }

        @Test("externalId locked format — all 5 cumulative types match server table")
        func externalIdAllCumulativeTypes() {
            let day = "2026-05-16"
            let cases: [(id: String, expected: String)] = [
                ("HKQuantityTypeIdentifierStepCount", "stats:HKQuantityTypeIdentifierStepCount:2026-05-16"),
                (
                    "HKQuantityTypeIdentifierActiveEnergyBurned",
                    "stats:HKQuantityTypeIdentifierActiveEnergyBurned:2026-05-16"
                ),
                ("HKQuantityTypeIdentifierFlightsClimbed", "stats:HKQuantityTypeIdentifierFlightsClimbed:2026-05-16"),
                (
                    "HKQuantityTypeIdentifierDistanceWalkingRunning",
                    "stats:HKQuantityTypeIdentifierDistanceWalkingRunning:2026-05-16"
                ),
                ("HKQuantityTypeIdentifierTimeInDaylight", "stats:HKQuantityTypeIdentifierTimeInDaylight:2026-05-16")
            ]
            for testCase in cases {
                let row = HealthKitDailyStatRow(
                    hkIdentifier: testCase.id,
                    dayStart: Date(),
                    dayKey: day,
                    value: 1,
                    unit: "count"
                )
                #expect(row.externalId == testCase.expected, "externalId drift for \(testCase.id)")
            }
        }

        // MARK: - dayKey

        @Test("dayKey returns yyyy-MM-dd in calendar's TZ")
        func dayKeyBerlin() throws {
            var cal = Calendar(identifier: .gregorian)
            // swiftlint:disable:next force_unwrapping
            cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            // 2026-05-16 14:30 in Europe/Berlin (CEST = UTC+2 → 12:30 UTC)
            // swiftlint:disable:next force_unwrapping
            let date = try #require(ISO8601DateFormatter.fractional.date(from: "2026-05-16T12:30:00.000Z"))
            #expect(HealthKitStatisticsService.dayKey(for: date, calendar: cal) == "2026-05-16")
        }

        @Test("dayKey rolls to next day when crossing user-TZ midnight")
        func dayKeyMidnightRollover() throws {
            var cal = Calendar(identifier: .gregorian)
            // swiftlint:disable:next force_unwrapping
            cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            // 23:30 Berlin on 2026-05-16 = 21:30 UTC same day.
            // swiftlint:disable:next force_unwrapping
            let beforeMidnight = try #require(ISO8601DateFormatter.fractional.date(from: "2026-05-16T21:30:00.000Z"))
            // 00:30 Berlin on 2026-05-17 = 22:30 UTC on 2026-05-16.
            // swiftlint:disable:next force_unwrapping
            let afterMidnight = try #require(ISO8601DateFormatter.fractional.date(from: "2026-05-16T22:30:00.000Z"))
            #expect(HealthKitStatisticsService.dayKey(for: beforeMidnight, calendar: cal) == "2026-05-16")
            #expect(HealthKitStatisticsService.dayKey(for: afterMidnight, calendar: cal) == "2026-05-17")
        }

        @Test("dayKey is locale-stable (en_US_POSIX) independent of user locale")
        func dayKeyLocaleStable() throws {
            var cal = Calendar(identifier: .gregorian)
            // swiftlint:disable:next force_unwrapping
            cal.timeZone = try #require(TimeZone(identifier: "UTC"))
            cal.locale = Locale(identifier: "ar_SA") // Arabic locale, would otherwise risk non-Latin digits.
            // swiftlint:disable:next force_unwrapping
            let date = try #require(ISO8601DateFormatter.fractional.date(from: "2026-05-16T08:00:00.000Z"))
            // Locale on Calendar is irrelevant for the formatter (POSIX is hard-pinned).
            #expect(HealthKitStatisticsService.dayKey(for: date, calendar: cal) == "2026-05-16")
        }

        // MARK: - CumulativeTypeConfig

        @Test("Default configs cover all 5 locked cumulative HK types")
        func defaultsCoverLocked5() {
            let identifiers = HealthKitCumulativeTypeConfig.defaults.map(\.identifier)
            let expected: Set = [
                "HKQuantityTypeIdentifierStepCount",
                "HKQuantityTypeIdentifierActiveEnergyBurned",
                "HKQuantityTypeIdentifierFlightsClimbed",
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
                "HKQuantityTypeIdentifierTimeInDaylight"
            ]
            #expect(Set(identifiers) == expected)
            #expect(identifiers.count == 5)
        }

        @Test("Default wire-units match server unitMap (steps/kcal/flights/m/minutes)")
        func defaultsMatchServerUnitMap() {
            let map: [String: String] = HealthKitCumulativeTypeConfig.defaults.reduce(into: [:]) { acc, config in
                acc[config.identifier] = config.wireUnit
            }
            #expect(map["HKQuantityTypeIdentifierStepCount"] == "steps")
            #expect(map["HKQuantityTypeIdentifierActiveEnergyBurned"] == "kcal")
            #expect(map["HKQuantityTypeIdentifierFlightsClimbed"] == "flights")
            #expect(map["HKQuantityTypeIdentifierDistanceWalkingRunning"] == "m")
            #expect(map["HKQuantityTypeIdentifierTimeInDaylight"] == "minutes")
        }

        @Test("cumulativeIdentifiers Set matches defaults — drift guard")
        func cumulativeIdentifiersMatchDefaults() {
            let setFromDefaults = Set(HealthKitCumulativeTypeConfig.defaults.map(\.identifier))
            #expect(setFromDefaults == HealthKitCumulativeTypeConfig.cumulativeIdentifiers)
        }

        // MARK: - HealthKitDailyStatRow Equatable

        @Test("HealthKitDailyStatRow Equatable identity")
        func rowEquatable() {
            let date = Date(timeIntervalSince1970: 1_716_000_000)
            let row1 = HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: date,
                dayKey: "2026-05-16",
                value: 8345,
                unit: "steps"
            )
            let row2 = HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: date,
                dayKey: "2026-05-16",
                value: 8345,
                unit: "steps"
            )
            let row3 = HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: date,
                dayKey: "2026-05-16",
                value: 9000, // different value
                unit: "steps"
            )
            #expect(row1 == row2)
            #expect(row1 != row3)
        }
    }

#endif
