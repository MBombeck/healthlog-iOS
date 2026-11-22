import Foundation
@testable import HealthLog
import Testing

/// The date and time forms screens used to build by hand. Every test names
/// the day it counts from, the language and the calendar, so the result does
/// not depend on the device or on the day the suite runs.
@Suite("Date spans, durations and clock times")
struct HLDateSpanFormatTests {
    private static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    private static let german = Locale(identifier: "de_DE")
    private static let english = Locale(identifier: "en_US")
    private static let dutch = Locale(identifier: "nl_NL")

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return berlin.date(from: components) ?? .distantPast
    }

    /// Thursday, 12 November 2026, noon.
    private static let now = day(2026, 11, 12)

    private static func relative(daysFromNow days: Int, locale: Locale) -> String {
        let date = berlin.date(byAdding: .day, value: days, to: now) ?? now
        return HLDateFormat.relative(date, now: now, locale: locale, calendar: berlin)
    }

    // MARK: - Relative day

    @Test("a day near today is named, a day further off is counted", arguments: [
        (0, "heute"), (-1, "gestern"), (1, "morgen"), (-3, "vor 3 Tagen"),
        (-7, "letzte Woche"), (-13, "letzte Woche"), (-14, "vor 2 Wochen"), (-800, "vor 2 Jahren")
    ])
    func relativeGerman(days: Int, expected: String) {
        #expect(Self.relative(daysFromNow: days, locale: Self.german) == expected)
    }

    @Test("the relative day follows the language", arguments: [
        (0, "today"), (-1, "yesterday"), (1, "tomorrow"), (-3, "3 days ago"), (-7, "last week"), (-365, "last year")
    ])
    func relativeEnglish(days: Int, expected: String) {
        #expect(Self.relative(daysFromNow: days, locale: Self.english) == expected)
    }

    @Test("Dutch names the days around today", arguments: [(0, "vandaag"), (-1, "gisteren"), (1, "morgen")])
    func relativeDutch(days: Int, expected: String) {
        #expect(Self.relative(daysFromNow: days, locale: Self.dutch) == expected)
    }

    @Test("it counts calendar days, not hours: an hour ago can be yesterday")
    func relativeCountsCalendarDays() {
        let justAfterMidnight = Self.day(2026, 11, 12, hour: 0, minute: 30)
        let lateLastEvening = Self.day(2026, 11, 11, hour: 23, minute: 30)
        let earlyThisMorning = Self.day(2026, 11, 12, hour: 0, minute: 5)
        #expect(HLDateFormat.relative(
            lateLastEvening, now: justAfterMidnight, locale: Self.german, calendar: Self.berlin
        ) == "gestern")
        #expect(HLDateFormat.relative(
            earlyThisMorning, now: Self.now, locale: Self.german, calendar: Self.berlin
        ) == "heute")
    }

    @Test("days within a week, weeks within five weeks, months within a year, then years")
    func relativeUnits() {
        #expect(HLDateFormat.relativeComponents(forDays: 0) == DateComponents(day: 0))
        #expect(HLDateFormat.relativeComponents(forDays: -6) == DateComponents(day: -6))
        #expect(HLDateFormat.relativeComponents(forDays: -7) == DateComponents(weekOfMonth: -1))
        #expect(HLDateFormat.relativeComponents(forDays: -13) == DateComponents(weekOfMonth: -1))
        #expect(HLDateFormat.relativeComponents(forDays: -34) == DateComponents(weekOfMonth: -4))
        #expect(HLDateFormat.relativeComponents(forDays: -35) == DateComponents(month: -1))
        #expect(HLDateFormat.relativeComponents(forDays: -364) == DateComponents(month: -12))
        #expect(HLDateFormat.relativeComponents(forDays: -365) == DateComponents(year: -1))
        #expect(HLDateFormat.relativeComponents(forDays: 40) == DateComponents(month: 1))
        #expect(HLDateFormat.relativeComponents(forDays: 800) == DateComponents(year: 2))
    }

    // MARK: - Weekday, month and year

    @Test("the weekday is written out or abbreviated, in the language asked for")
    func weekday() {
        let tuesday = Self.day(2026, 11, 3)
        #expect(HLDateFormat.weekday(tuesday, locale: Self.german, calendar: Self.berlin) == "Dienstag")
        #expect(HLDateFormat.weekday(tuesday, locale: Self.english, calendar: Self.berlin) == "Tuesday")
        #expect(HLDateFormat.weekday(tuesday, locale: Self.dutch, calendar: Self.berlin) == "dinsdag")

        let short = HLDateFormat.weekday(tuesday, abbreviated: true, locale: Self.english, calendar: Self.berlin)
        #expect(short == "Tue")
        let kurz = HLDateFormat.weekday(tuesday, abbreviated: true, locale: Self.german, calendar: Self.berlin)
        #expect(kurz.hasPrefix("Di"))
        #expect(kurz.count < "Dienstag".count)
    }

    @Test("the weekday belongs to the calendar's time zone, not the device's")
    func weekdayFollowsCalendar() {
        // Half past midnight in Berlin is still Monday evening in New York.
        let earlyTuesday = Self.day(2026, 11, 3, hour: 0, minute: 30)
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        #expect(HLDateFormat.weekday(earlyTuesday, locale: Self.english, calendar: Self.berlin) == "Tuesday")
        #expect(HLDateFormat.weekday(earlyTuesday, locale: Self.english, calendar: newYork) == "Monday")
    }

    @Test("month and year")
    func monthYear() {
        #expect(HLDateFormat.monthYear(Self.now, locale: Self.german, calendar: Self.berlin) == "November 2026")
        #expect(HLDateFormat.monthYear(Self.now, locale: Self.english, calendar: Self.berlin) == "November 2026")
        #expect(HLDateFormat.monthYear(Self.now, locale: Self.dutch, calendar: Self.berlin) == "november 2026")
    }

    // MARK: - Span of days

    private static func span(_ start: Date, _ end: Date, locale: Locale) -> String {
        HLDateFormat.range(start, end, now: now, locale: locale, calendar: berlin)
    }

    @Test("a span within one month names the month once where the day leads")
    func rangeWithinMonth() {
        let start = Self.day(2026, 11, 3)
        let end = Self.day(2026, 11, 9)
        #expect(Self.span(start, end, locale: Self.german) == HLNumberFormat.range("3.", "9. Nov."))
        #expect(Self.span(start, end, locale: Self.english) == HLNumberFormat.range("Nov 3", "Nov 9"))
    }

    @Test("a span across two months names both")
    func rangeAcrossMonths() {
        let span = Self.span(Self.day(2026, 10, 28), Self.day(2026, 11, 3), locale: Self.german)
        #expect(span == HLNumberFormat.range("28. Okt.", "3. Nov."))
    }

    @Test("a span within one day is that day")
    func rangeWithinDay() {
        let morning = Self.day(2026, 11, 3, hour: 8)
        let evening = Self.day(2026, 11, 3, hour: 21)
        #expect(Self.span(morning, evening, locale: Self.german) == "3. Nov.")
    }

    @Test("the year appears as soon as one end is not in the current year")
    func rangeWithYear() {
        let lastYear = Self.span(Self.day(2025, 11, 3), Self.day(2025, 11, 9), locale: Self.german)
        #expect(lastYear == HLNumberFormat.range("3.", "9. Nov. 2025"))

        let turnOfYear = Self.span(Self.day(2025, 12, 29), Self.day(2026, 1, 4), locale: Self.german)
        #expect(turnOfYear == HLNumberFormat.range("29. Dez. 2025", "4. Jan. 2026"))
    }

    @Test("the start loses only what the end repeats, and only where the day leads")
    func shortenedStart() {
        #expect(HLDateFormat.shortenedStart("3. Nov.", before: "9. Nov.") == "3.")
        #expect(HLDateFormat.shortenedStart("3. Nov. 2025", before: "9. Nov. 2025") == "3.")
        #expect(HLDateFormat.shortenedStart("28. Okt.", before: "3. Nov.") == "28. Okt.")
        #expect(HLDateFormat.shortenedStart("3. Nov. 2025", before: "9. Nov. 2026") == "3. Nov. 2025")
        #expect(HLDateFormat.shortenedStart("Nov 3", before: "Nov 9") == "Nov 3")
        #expect(HLDateFormat.shortenedStart("3.", before: "9.") == "3.")
    }

    // MARK: - Duration

    @Test("a duration reads in hours and minutes, in the language asked for", arguments: [
        (0.0, "de_DE", "0 Min."), (2700.0, "de_DE", "45 Min."), (7200.0, "de_DE", "2 Std."),
        (4800.0, "de_DE", "1 Std. 20 Min."),
        (0.0, "en_US", "0 min"), (7200.0, "en_US", "2 hr"), (4800.0, "en_US", "1 hr 20 min"),
        (7200.0, "nl_NL", "2 uur"), (4800.0, "nl_NL", "1 uur 20 min")
    ])
    func duration(seconds: Double, language: String, expected: String) {
        #expect(HLTimeFormat.duration(seconds, locale: Locale(identifier: language)) == expected)
    }

    @Test("a duration is rounded to the minute and never negative")
    func durationRounding() {
        #expect(HLTimeFormat.duration(89, locale: Self.english) == "1 min")
        #expect(HLTimeFormat.duration(90, locale: Self.english) == "2 min")
        #expect(HLTimeFormat.duration(3599, locale: Self.english) == "1 hr")
        #expect(HLTimeFormat.duration(-600, locale: Self.english) == "0 min")
    }

    // MARK: - Clock time

    @Test("a time of day without a date reads the same on every device")
    func clock() {
        #expect(HLTimeFormat.clock(minutesAfterMidnight: 485, locale: Self.german) == "08:05")
        #expect(HLTimeFormat.clock(minutesAfterMidnight: 0, locale: Self.german) == "00:00")
        #expect(HLTimeFormat.clock(minutesAfterMidnight: 1439, locale: Self.german) == "23:59")

        let american = HLTimeFormat.clock(minutesAfterMidnight: 485, locale: Self.english)
        #expect(american.hasPrefix("8:05"))
        #expect(american.hasSuffix("AM"))
    }

    @Test("minutes outside one day wrap around")
    func clockWraps() {
        #expect(HLTimeFormat.clock(minutesAfterMidnight: 1440 + 485, locale: Self.german) == "08:05")
        #expect(HLTimeFormat.clock(minutesAfterMidnight: -60, locale: Self.german) == "23:00")
    }

    @Test("the clock follows the 12- or 24-hour form the user chose")
    func clockFollowsSetting() throws {
        let name = "hl.test.timeformat.clock"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }

        suite.set(HLTimeFormat.twentyFourHour.rawValue, forKey: HLTimeFormat.defaultsKey)
        let twentyFour = HLTimeFormat.clock(minutesAfterMidnight: 13 * 60 + 5, defaults: suite)
        #expect(twentyFour.contains("13"))

        suite.set(HLTimeFormat.twelveHour.rawValue, forKey: HLTimeFormat.defaultsKey)
        let twelve = HLTimeFormat.clock(minutesAfterMidnight: 13 * 60 + 5, defaults: suite)
        #expect(!twelve.contains("13"))
        #expect(twelve.contains("1"))
    }
}
