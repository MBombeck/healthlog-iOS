import Foundation
import os

/// The date forms screens used to build by hand: a relative day, a weekday, a
/// month with its year, a span of days.
///
/// `now`, `locale` and `calendar` have defaults and exist for tests; screens
/// call these with the date alone.
public extension HLDateFormat {
    /// How far a day lies from today, in words: "today", "yesterday",
    /// "3 days ago", "last week", "in 2 months".
    ///
    /// It counts calendar days, not hours: yesterday evening is "yesterday"
    /// even when it is fewer than 24 hours ago.
    static func relative(
        _ date: Date,
        now: Date = .now,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let components = relativeComponents(forDays: days)
        return relativeFormatters.withLockUnchecked { cache in
            let formatter: RelativeDateTimeFormatter
            if let cached = cache[locale.identifier] {
                formatter = cached
            } else {
                formatter = RelativeDateTimeFormatter()
                formatter.locale = locale
                formatter.dateTimeStyle = .named
                formatter.unitsStyle = .full
                cache[locale.identifier] = formatter
            }
            return formatter.localizedString(from: components)
        }
    }

    /// One formatter per language: a long list asks for the same words in
    /// every row. `RelativeDateTimeFormatter` is not `Sendable`, so the lock
    /// guards both the table and the use of a formatter.
    private static let relativeFormatters = OSAllocatedUnfairLock(
        uncheckedState: [String: RelativeDateTimeFormatter]()
    )

    /// The unit a distance in days is spoken in. Days within a week, weeks
    /// within five weeks, months within a year, then years; the coarser unit
    /// rounds down, so 13 days ago is still "last week".
    static func relativeComponents(forDays days: Int) -> DateComponents {
        let distance = abs(days)
        let sign = days < 0 ? -1 : 1
        switch distance {
        case 0 ..< 7:
            return DateComponents(day: days)
        case 7 ..< 35:
            return DateComponents(weekOfMonth: sign * (distance / 7))
        case 35 ..< 365:
            return DateComponents(month: sign * max(1, distance / 30))
        default:
            return DateComponents(year: sign * (distance / 365))
        }
    }

    /// The weekday of a date, written out or abbreviated.
    static func weekday(
        _ date: Date,
        abbreviated: Bool = false,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(style(locale: locale, calendar: calendar).weekday(abbreviated ? .abbreviated : .wide))
    }

    /// Weekday written out, day and month: "Donnerstag, 12. Nov.", the line
    /// under the dashboard's greeting.
    static func weekdayDayMonth(
        _ date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(style(locale: locale, calendar: calendar).weekday(.wide).day().month())
    }

    /// Month and year: "November 2026".
    static func monthYear(
        _ date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(style(locale: locale, calendar: calendar).month(.wide).year())
    }

    /// The month alone, written out ("Oktober") or abbreviated ("Okt."), with
    /// the year when `withYear` ("Jan. 2026"): the timeline's axis and its
    /// quarter titles.
    static func month(
        _ date: Date,
        abbreviated: Bool,
        withYear: Bool = false,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let month = style(locale: locale, calendar: calendar).month(abbreviated ? .abbreviated : .wide)
        return date.formatted(withYear ? month.year() : month)
    }

    /// The year alone: "2026".
    static func year(
        _ date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        date.formatted(style(locale: locale, calendar: calendar).year())
    }

    /// A span of days in words: "3 to 9 Nov", "28 Oct to 3 Nov".
    ///
    /// Both ends are day and abbreviated month. Both carry the year as soon as
    /// one of them is not in the current year. Where the day leads and the
    /// rest of both ends is the same, the start keeps only its day. A span
    /// within one day is that day.
    static func range(
        _ start: Date,
        _ end: Date,
        now: Date = .now,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let currentYear = calendar.component(.year, from: now)
        let withinCurrentYear = [start, end].allSatisfy { calendar.component(.year, from: $0) == currentYear }
        let dayMonth = style(locale: locale, calendar: calendar).day().month(.abbreviated)
        let form = withinCurrentYear ? dayMonth : dayMonth.year()
        let upper = end.formatted(form)
        if calendar.isDate(start, inSameDayAs: end) { return upper }
        return HLNumberFormat.range(shortenedStart(start.formatted(form), before: upper), upper)
    }

    /// Drops from the start what the end says anyway: "3. Nov." before
    /// "9. Nov." becomes "3.". Only where the day comes first; "Nov 3 to 9"
    /// would read as a time.
    internal static func shortenedStart(_ start: String, before end: String) -> String {
        let startParts = start.split(separator: " ")
        let endParts = end.split(separator: " ")
        guard startParts.count > 1,
              startParts.count == endParts.count,
              startParts[0].first?.isNumber == true,
              startParts.dropFirst().elementsEqual(endParts.dropFirst()) else { return start }
        return String(startParts[0])
    }

    /// An empty style in the given locale and calendar; the callers add the
    /// fields they show.
    private static func style(locale: Locale, calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}
