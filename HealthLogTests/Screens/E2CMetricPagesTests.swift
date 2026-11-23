import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

/// Metric pages, charts, the history list and the records page as stage E2
/// left them: the chart follows the chosen period, the value axis ends on a
/// grid line, sleep reads in hours and minutes, the history is one card per
/// week, a record change of nothing has no arrow.
@Suite("E2C metric pages")
@MainActor
struct E2CMetricPagesTests {
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        cal.firstWeekday = 2
        return cal
    }

    /// Sunday 2026-11-15 09:00 Berlin.
    private static var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9)) ?? .distantPast
    }

    private static func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now) ?? now
    }

    // MARK: - Date axis

    @Test("the date axis spans the chosen period, not only the readings in it")
    func xDomainFollowsThePeriod() throws {
        let dates = [Self.daysAgo(2), Self.daysAgo(1), Self.daysAgo(0)]
        let month = try #require(MetricChartScale.xDomain(for: .month, dates: dates, now: Self.now, calendar: Self.calendar))
        let monthStart = try #require(Self.calendar.date(byAdding: .day, value: -29, to: Self.calendar.startOfDay(for: Self.now)))
        #expect(month.lowerBound == monthStart)
        #expect(month.upperBound == Self.now)
        let week = try #require(MetricChartScale.xDomain(for: .week, dates: dates, now: Self.now, calendar: Self.calendar))
        #expect(week.lowerBound > month.lowerBound, "W and M must not draw the same axis")
        let sixMonths = try #require(MetricChartScale.xDomain(for: .sixMonths, dates: dates, now: Self.now, calendar: Self.calendar))
        #expect(sixMonths.lowerBound < month.lowerBound)
    }

    @Test("All spans the readings up to now; a reading before the period widens it")
    func xDomainAllAndOutliers() throws {
        let old = Self.daysAgo(400)
        let all = try #require(MetricChartScale.xDomain(for: .all, dates: [old, Self.daysAgo(1)], now: Self.now, calendar: Self.calendar))
        #expect(all.lowerBound == old)
        #expect(all.upperBound == Self.now)
        let later = Self.now.addingTimeInterval(3600)
        let day = try #require(MetricChartScale.xDomain(for: .day, dates: [later], now: Self.now, calendar: Self.calendar))
        #expect(day.upperBound == later, "a reading after now is never cut off")
    }

    // MARK: - Value axis

    @Test("blood pressure ends on a grid line one step above the highest value")
    func yDomainLeavesAStepOfRoom() {
        let domain = MetricChartScale.yDomain(values: [75, 81, 118, 126])
        #expect(domain == 60 ... 140)
    }

    @Test("a percentage never reads past 100, and nothing starts below zero")
    func yDomainCapsPercent() {
        let spo2 = MetricChartScale.yDomain(values: [95, 97, 99], capsAtHundred: true)
        #expect(spo2.upperBound == 100)
        #expect(spo2.lowerBound <= 95)
        #expect(MetricChartScale.yDomain(values: [0.2, 1.4]).lowerBound >= 0)
        #expect(MetricChartScale.capsAtHundred(unit: "%"))
        #expect(!MetricChartScale.capsAtHundred(unit: "kg"))
    }

    @Test("a flat series still gets a domain around its value")
    func yDomainFlat() {
        let domain = MetricChartScale.yDomain(values: [72, 72])
        #expect(domain.contains(72))
        #expect(domain.lowerBound < domain.upperBound)
    }

    @Test("grid steps are 1, 2, 2.5 or 5 times a power of ten")
    func gridSteps() {
        #expect(MetricChartScale.gridStep(span: 51, magnitude: 126) == 20)
        #expect(MetricChartScale.gridStep(span: 1.2, magnitude: 73) == 0.5)
        #expect(MetricChartScale.gridStep(span: 4, magnitude: 99) == 1)
    }

    // MARK: - Durations

    @Test("sleep reads in hours and minutes and labels its axis with the hour word")
    func sleepIsADuration() {
        let text = MetricDurationFormat.text(hours: 7.2, locale: Locale(identifier: "de_DE"))
        #expect(text.contains("7") && text.contains("12"))
        #expect(!text.contains(","), "never a decimal hour")
        #expect(MetricDurationFormat.text(64, kind: .pulse) == nil)
        #expect(MetricDurationFormat.unit("h", kind: .sleep).isEmpty)
        #expect(MetricDurationFormat.unit("bpm", kind: .pulse) == "bpm")
        #expect(MetricDurationFormat.axisUnit("h", kind: .sleep) == String(localized: "unit.hours.short"))
        #expect(HeroDeltaChip.label(delta: 0.5, unit: "h", kind: .sleep) == MetricDurationFormat.text(hours: 0.5))
        #expect(MetricDurationFormat.clock(hours: 6.7833) == "6:47")
        #expect(MetricDurationFormat.clock(64, kind: .pulse) == nil)
    }

    @Test("the year row shows its change as signed text, not a second capsule")
    func yearRowSigned() {
        #expect(YearOverYearRow.signed(0.4, unit: "kg").hasPrefix("+"))
        #expect(YearOverYearRow.signed(-1.2, unit: "kg").hasPrefix("\u{2212}"))
        #expect(YearOverYearRow.signed(1, unit: "").hasSuffix("1"))
    }

    // MARK: - History list

    private static func reading(daysAgo days: Int, hour: Int = 7) -> Measurement {
        let day = daysAgo(days)
        let at = calendar.date(bySettingHour: hour, minute: 30, second: 0, of: day) ?? day
        return Measurement(id: "m-\(days)-\(hour)", kind: .weight, recordedAt: at, value: .scalar(72), note: nil, source: .manual)
    }

    @Test("the readings of a week share one card; a day never gets its own")
    func weekCards() {
        // Sun 15, Sat 14, Fri 13 (this week), Sun 8 (last week).
        let sections = MeasurementBucketing.sections(
            for: [Self.reading(daysAgo: 0), Self.reading(daysAgo: 1), Self.reading(daysAgo: 2), Self.reading(daysAgo: 7)],
            now: Self.now,
            calendar: Self.calendar
        )
        let groups = MeasurementBucketing.groups(sections, calendar: Self.calendar)
        #expect(groups.count == 2)
        #expect(groups.first?.sections.count == 3)
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test("week summaries of a month share a card under the month")
    func summaryCards() throws {
        let weekA = try #require(Self.calendar.dateInterval(of: .weekOfYear, for: Self.daysAgo(21))?.start)
        let weekB = try #require(Self.calendar.dateInterval(of: .weekOfYear, for: Self.daysAgo(28))?.start)
        let sections: [MeasurementSection] = [
            .weeklySummary(weekStart: weekA, items: [Self.reading(daysAgo: 21)]),
            .weeklySummary(weekStart: weekB, items: [Self.reading(daysAgo: 28)])
        ]
        let groups = MeasurementBucketing.groups(sections, calendar: Self.calendar)
        #expect(groups.count == 1)
        if case .month = groups.first?.header {} else {
            Issue.record("week summaries group under their month")
        }
        #expect(MeasurementBucketing.summaryTitle(of: sections[0], now: Self.now, calendar: Self.calendar)
            == MeasurementBucketing.weekHeader(start: weekA, calendar: Self.calendar))
    }

    @Test("a reading's title in a week card names the day and the time")
    func rowTitle() {
        // "Today" is the calendar's own today, so the reading is taken now.
        let title = MeasurementBucketing.rowTitle(.now, now: .now)
        #expect(title.hasPrefix(String(localized: "Today")))
        #expect(title.contains(", "))
    }

    @Test("a summary states the span of its values once, with one unit")
    func summarySpan() {
        #expect(MeasurementSummaryRow.span("72,0", "72,0", unit: "kg") == "72,0 kg")
        let span = MeasurementSummaryRow.span("72,0", "73,0", unit: "kg")
        #expect(span.hasPrefix("72,0") && span.hasSuffix("73,0 kg"))
        #expect(!span.contains("Min"))
    }

    // MARK: - Records

    private static func record(externalId: String?, achievedAt: Date = now) -> PersonalRecordDTO {
        PersonalRecordDTO(
            id: "r",
            userId: "u",
            metricType: "ACTIVITY_STEPS",
            metricSlot: nil,
            direction: .max,
            value: 12,
            unit: "days",
            achievedAt: achievedAt,
            sourceMeasurementId: nil,
            source: "HEALTHLOG_CLIENT",
            externalId: externalId,
            createdAt: achievedAt
        )
    }

    @Test("a streak holds since its first day, any other record since its day")
    func heroSince() throws {
        let start = try #require(HeroRecordCard.streakStart("streak:2026-11-03..2026-11-14"))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: start)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 3)
        #expect(HeroRecordCard.sinceDate(of: Self.record(externalId: "streak:2026-11-03..2026-11-14")) == start)
        #expect(HeroRecordCard.sinceDate(of: Self.record(externalId: nil)) == Self.now)
        #expect(HeroRecordCard.streakStart("abc") == nil)
    }

    @Test("a change of nothing has no arrow and no colour")
    func recordDeltaStyle() {
        let flat = RecordCard.deltaStyle(delta: PersonalRecord.Delta(absolute: 0.1, percent: 0.002))
        #expect(flat.symbol == nil)
        #expect(flat.tone == .neutral)
        let gain = RecordCard.deltaStyle(delta: PersonalRecord.Delta(absolute: 5, percent: 0.12))
        #expect(gain.symbol == "arrow.up")
        let loss = RecordCard.deltaStyle(delta: PersonalRecord.Delta(absolute: -5, percent: nil))
        #expect(loss.symbol == "arrow.down")
    }

    @Test("records stand in rows of the column count, the last one shorter")
    func recordRows() {
        let dto = Self.record(externalId: nil)
        let records = (0 ..< 5).map { index in
            PersonalRecord(
                id: "r\(index)",
                base: dto,
                kind: .steps,
                sparklineValues: [],
                peakIndex: nil,
                previousValue: nil,
                bucket: .month,
                impressiveness: 0
            )
        }
        let rows = PersonalRecordsScreen.rows(records, columns: 2)
        #expect(rows.map(\.count) == [2, 2, 1])
        #expect(PersonalRecordsScreen.rows(records, columns: 1).count == 5)
    }
}
