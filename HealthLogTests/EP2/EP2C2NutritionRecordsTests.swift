import Foundation
@testable import HealthLog
import Testing

/// The nutrient page reads its dense day series honestly: empty days are not
/// intakes, so they leave the history, the bars and the statistic.
@Suite("EP2C2 nutrient detail series")
struct EP2C2NutrientDetailSeriesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        return calendar
    }

    private let days = [
        NutrientDayPointDTO(day: "2026-11-10", amount: 12),
        NutrientDayPointDTO(day: "2026-11-11", amount: 0),
        NutrientDayPointDTO(day: "2026-11-12", amount: 4),
        NutrientDayPointDTO(day: "2026-11-13", amount: 0),
        NutrientDayPointDTO(day: "2026-11-14", amount: 8)
    ]

    @Test("history lists only days with data, newest first")
    func historyDropsEmptyDays() {
        let history = NutrientDetailSeries.history(days, calendar: calendar)
        #expect(history.map(\.id) == ["2026-11-14", "2026-11-12", "2026-11-10"])
    }

    @Test("bars run oldest first and sit on the day, the scrub point at midday")
    func chartDaysOrderAndMidday() throws {
        let bars = NutrientDetailSeries.chartDays(days, calendar: calendar)
        #expect(bars.map(\.amount) == [12, 4, 8])
        let first = try #require(bars.first)
        #expect(calendar.component(.hour, from: first.day) == 0)
        #expect(calendar.component(.hour, from: first.midday) == 12)
        #expect(calendar.component(.day, from: first.day) == 10)
    }

    @Test("statistic counts days with data only")
    func statsIgnoreEmptyDays() throws {
        let stats = try #require(NutrientDetailSeries.stats(days))
        #expect(stats.min == 4)
        #expect(stats.max == 12)
        #expect(stats.mean == 8)
        #expect(stats.median == 8)
    }

    @Test("median of an even count is the middle pair's mean")
    func evenMedian() throws {
        let even = [
            NutrientDayPointDTO(day: "2026-11-01", amount: 2),
            NutrientDayPointDTO(day: "2026-11-02", amount: 6)
        ]
        #expect(try #require(NutrientDetailSeries.stats(even)).median == 4)
    }

    @Test("a window without data has no statistic and no history")
    func emptyWindow() {
        let empty = [NutrientDayPointDTO(day: "2026-11-01", amount: 0)]
        #expect(NutrientDetailSeries.stats(empty) == nil)
        #expect(NutrientDetailSeries.history(empty, calendar: calendar).isEmpty)
    }

    @Test("an unreadable day key is skipped, not misplaced")
    func unreadableKey() {
        #expect(NutrientDetailSeries.date(fromDayKey: "gestern", calendar: calendar) == nil)
        let odd = [NutrientDayPointDTO(day: "gestern", amount: 3)]
        #expect(NutrientDetailSeries.chartDays(odd, calendar: calendar).isEmpty)
    }

    @Test("precision follows the list: small fractions keep two decimals")
    func precision() {
        #expect(NutrientDetailSeries.fractionDigits(for: 1.25) == 0 ... 2)
        #expect(NutrientDetailSeries.fractionDigits(for: 88) == 0 ... 0)
        #expect(NutrientDetailSeries.fractionDigits(for: 12.5) == 0 ... 0)
    }
}

/// A record card opens its metric page; sharing moved to the context menu
/// and stays the tap only where no metric page exists.
@MainActor
@Suite("EP2C2 record card tap")
struct EP2C2RecordCardTapTests {
    private func record(kind: MetricKind?) -> PersonalRecord {
        let dto = PersonalRecordDTO(
            id: "ep2c2.record",
            userId: "u1",
            metricType: "WEIGHT",
            metricSlot: nil,
            direction: .min,
            value: 72,
            unit: "kg",
            achievedAt: Date(timeIntervalSince1970: 1_780_000_000),
            sourceMeasurementId: nil,
            source: "MANUAL",
            externalId: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        return PersonalRecord(
            id: dto.id, base: dto, kind: kind, sparklineValues: [], peakIndex: nil,
            previousValue: nil, bucket: .month, impressiveness: 0.5
        )
    }

    @Test("a record with a kind opens the metric page")
    func opensMetric() {
        #expect(RecordCard.tapAction(for: record(kind: .weight)) == .openMetric(.weight))
    }

    @Test("a record without a showable kind still shares on tap")
    func sharesWithoutKind() {
        #expect(RecordCard.tapAction(for: record(kind: nil)) == .share)
        #expect(RecordCard.tapAction(for: record(kind: .unknown)) == .share)
    }
}

/// The workout tiles draw the distance through `HLValueText`; the number and
/// unit must say what the old label said.
@Suite("EP2C2 workout distance reading")
struct EP2C2WorkoutDistanceTests {
    @Test("metres under a kilometre, kilometres with one decimal above")
    func metric() {
        let short = WorkoutFormatter.distanceReading(metres: 820.4, system: .metric)
        #expect(short.value == 820)
        #expect(short.unit == .meters)
        #expect(short.fractionDigits == 0 ... 0)
        let long = WorkoutFormatter.distanceReading(metres: 12345, system: .metric)
        #expect(long.value == 12.345)
        #expect(long.unit == .kilometers)
        #expect(long.fractionDigits == 1 ... 1)
    }

    @Test("an imperial account reads miles like the list label")
    func imperial() {
        let reading = WorkoutFormatter.distanceReading(metres: 5000, system: .imperial)
        #expect(reading.unit == .custom("mi"))
        #expect(reading.fractionDigits == 2 ... 2)
        let label = WorkoutFormatter.distanceLabel(metres: 5000, locale: Locale(identifier: "en_US"), system: .imperial)
        let text = HLValueFormat.number(reading.value, fractionDigits: reading.fractionDigits, locale: Locale(identifier: "en_US"))
        #expect(label.hasPrefix(text))
    }
}
