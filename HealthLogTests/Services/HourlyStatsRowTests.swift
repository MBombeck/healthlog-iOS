import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// The hourly row as the server's v1.43 contract
    /// names it (`release/v1.43.0`, `intraday-hour-buckets.ts`,
    /// `routes/measurements.ts`): `stats:<HK>:<YYYY-MM-DD>T<HH>` in the
    /// account's zone, the hour's sum in the day form's unit, `startDate` the
    /// start of the local hour, `endDate` one hour later.
    @Suite("X4 hourly stats: row shape and id format")
    struct HourlyStatsRowTests {
        static let steps = "HKQuantityTypeIdentifierStepCount"

        static func calendar(_ identifier: String) throws -> Calendar {
            try HourlyFakeReader.calendar(#require(TimeZone(identifier: identifier)))
        }

        /// Hourly buckets from `start` for `count` hours, `value` where `hasData`.
        static func buckets(
            from start: Date,
            count: Int,
            value: (Int) -> Double?
        ) -> [(start: Date, value: Double?)] {
            (0 ..< count).map { (start.addingTimeInterval(Double($0) * 3600), value($0)) }
        }

        @Test("the id is the server's hour form: day and zero-padded hour")
        func idFormat() {
            #expect(
                HealthKitHourlyStatRow.externalId(hkIdentifier: Self.steps, dayKey: "2026-10-09", hour: 7)
                    == "stats:HKQuantityTypeIdentifierStepCount:2026-10-09T07"
            )
            #expect(
                HealthKitHourlyStatRow.externalId(hkIdentifier: Self.steps, dayKey: "2026-10-09", hour: 0)
                    == "stats:HKQuantityTypeIdentifierStepCount:2026-10-09T00"
            )
            #expect(
                HealthKitHourlyStatRow.externalId(hkIdentifier: Self.steps, dayKey: "2026-10-09", hour: 23)
                    == "stats:HKQuantityTypeIdentifierStepCount:2026-10-09T23"
            )
            // The server's parser (`HOUR_FORM`), verbatim.
            let id = HealthKitHourlyStatRow.externalId(hkIdentifier: Self.steps, dayKey: "2026-01-02", hour: 5)
            #expect(id.range(of: #"^stats:([A-Za-z0-9]+):(\d{4}-\d{2}-\d{2})T(\d{2})$"#, options: .regularExpression) != nil)
        }

        @Test("only the four types the server takes, in the day form's unit (no daylight)")
        func typesAndUnits() {
            #expect(HealthKitHourlyStatRow.identifiers == [
                "HKQuantityTypeIdentifierStepCount",
                "HKQuantityTypeIdentifierActiveEnergyBurned",
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
                "HKQuantityTypeIdentifierFlightsClimbed"
            ])
            let units = Dictionary(uniqueKeysWithValues: HealthKitHourlyStatRow.configs.map { ($0.identifier, $0.wireUnit) })
            #expect(units == [
                "HKQuantityTypeIdentifierStepCount": "steps",
                "HKQuantityTypeIdentifierActiveEnergyBurned": "kcal",
                "HKQuantityTypeIdentifierDistanceWalkingRunning": "m",
                "HKQuantityTypeIdentifierFlightsClimbed": "flights"
            ])
        }

        @Test("the hour is cut in the account's zone, not UTC")
        func hoursInAccountZone() throws {
            let berlin = try Self.calendar("Europe/Berlin")
            // 2026-10-09 00:00 Berlin (CEST) = 2026-10-08 22:00 UTC.
            let start = try #require(berlin.date(from: DateComponents(year: 2026, month: 10, day: 9)))
            let rows = HealthKitHourlyStatRow.rows(
                identifier: Self.steps,
                wireUnit: "steps",
                buckets: Self.buckets(from: start, count: 24) { $0 == 9 ? 512 : nil },
                calendar: berlin
            )
            let nine = try #require(rows.first { $0.value == 512 })
            #expect(nine.externalId == "stats:HKQuantityTypeIdentifierStepCount:2026-10-09T09")
            #expect(nine.hourStart == Date(timeIntervalSince1970: 1_791_529_200)) // 07:00 UTC
            let entry = nine.entry
            #expect(entry.startDate == nine.hourStart)
            #expect(entry.endDate == nine.hourStart.addingTimeInterval(3600))
            #expect(entry.unit == "steps")
            #expect(entry.value == 512)
        }

        @Test("a day with data posts every hour, an empty one as 0; a day without data posts nothing")
        func zeroFillOnlyOnDaysWithData() throws {
            let utc = try Self.calendar("UTC")
            let start = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 7)))
            // Day 1: one hour of steps. Day 2: nothing at all.
            let rows = HealthKitHourlyStatRow.rows(
                identifier: Self.steps,
                wireUnit: "steps",
                buckets: Self.buckets(from: start, count: 48) { $0 == 13 ? 40 : nil },
                calendar: utc
            )
            #expect(rows.count == 24)
            #expect(Set(rows.map(\.dayKey)) == ["2026-10-07"])
            #expect(rows.filter { $0.value == 0 }.count == 23)
            #expect(rows.map(\.hour) == Array(0 ..< 24))
        }

        @Test("a bucket that does not start on a whole local hour is dropped (server: misaligned)")
        func misalignedBucketsAreDropped() throws {
            let kolkata = try Self.calendar("Asia/Kolkata")
            // UTC whole hours are :30 in India.
            let start = Date(timeIntervalSince1970: 1_791_504_000)
            let rows = HealthKitHourlyStatRow.rows(
                identifier: Self.steps,
                wireUnit: "steps",
                buckets: Self.buckets(from: start, count: 5) { _ in 10 },
                calendar: kolkata
            )
            #expect(rows.isEmpty)
        }

        @Test("the autumn hour that happens twice keeps both starts under one key")
        func fallBackDayHasTwoStartsForOneKey() throws {
            let berlin = try Self.calendar("Europe/Berlin")
            let start = try #require(berlin.date(from: DateComponents(year: 2026, month: 10, day: 25)))
            let rows = HealthKitHourlyStatRow.rows(
                identifier: Self.steps,
                wireUnit: "steps",
                buckets: Self.buckets(from: start, count: 25) { _ in 5 },
                calendar: berlin
            )
            #expect(rows.count == 25)
            let twos = rows.filter { $0.externalId.hasSuffix("2026-10-25T02") }
            #expect(twos.count == 2)
            #expect(Set(twos.map(\.hourStart)).count == 2)

            // One of them changed: both travel, so the server sums the slot.
            var ledger = HourlyStatsLedger()
            ledger.remember(rows)
            let later = rows.map { row in
                row.hourStart == twos[1].hourStart
                    ? HealthKitHourlyStatRow(
                        hkIdentifier: row.hkIdentifier, hourStart: row.hourStart, dayKey: row.dayKey,
                        hour: row.hour, value: 9, unit: row.unit
                    )
                    : row
            }
            let changed = ledger.changedRows(later)
            #expect(changed.count == 2)
            #expect(Set(changed.map(\.externalId)) == ["stats:HKQuantityTypeIdentifierStepCount:2026-10-25T02"])
        }

        @Test("the spring day has 23 hours and no T02")
        func springForwardDaySkipsTheMissingHour() throws {
            let berlin = try Self.calendar("Europe/Berlin")
            let start = try #require(berlin.date(from: DateComponents(year: 2026, month: 3, day: 29)))
            let rows = HealthKitHourlyStatRow.rows(
                identifier: Self.steps,
                wireUnit: "steps",
                buckets: Self.buckets(from: start, count: 23) { _ in 5 },
                calendar: berlin
            )
            #expect(rows.count == 23)
            #expect(!rows.contains { $0.externalId.hasSuffix("T02") })
        }

        @Test("a batch plan keeps days whole and under the server's 500 rows")
        func planKeepsDaysWhole() {
            var plan = HourlyBackfillPlan()
            let day = { (key: String) in
                (0 ..< 96).map { index in
                    HealthKitHourlyStatRow(
                        hkIdentifier: Self.steps,
                        hourStart: Date(timeIntervalSince1970: Double(index) * 3600),
                        dayKey: key, hour: index % 24, value: 1, unit: "steps"
                    )
                }
            }
            for index in 0 ..< 7 {
                plan.add(day: "d\(index)", rows: day("d\(index)"))
            }
            plan.add(day: "empty", rows: [])
            #expect(plan.batches.map(\.days) == [["d0", "d1", "d2", "d3", "d4"], ["d5", "d6"]])
            #expect(plan.batches.allSatisfy { $0.rows.count <= 500 })
            #expect(plan.daysWithoutRows == ["empty"])
        }

        @Test("a zone change starts the ledger over; the same zone keeps it")
        func zoneChangeResetsLedger() {
            var ledger = HourlyStatsLedger()
            ledger.adopt(timeZoneIdentifier: "Europe/Berlin")
            ledger.completedDays = ["2026-10-01"]
            ledger.accepted = ["2026-10-09": ["x@1": 1]]
            ledger.adopt(timeZoneIdentifier: "Europe/Berlin")
            #expect(ledger.completedDays == ["2026-10-01"])
            ledger.adopt(timeZoneIdentifier: "America/New_York")
            #expect(ledger.completedDays.isEmpty)
            #expect(ledger.accepted.isEmpty)
            #expect(ledger.timeZoneIdentifier == "America/New_York")
        }
    }

#endif
