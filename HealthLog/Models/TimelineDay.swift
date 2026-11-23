import Foundation

/// Calendar days of the timeline as whole numbers.
///
/// The server speaks in local day keys (`YYYY-MM-DD`) of the record's own
/// zone. The timeline only ever lays days side by side, so a day becomes its
/// number of days since 1970-01-01 in the proleptic Gregorian calendar: no
/// time zone, no daylight saving, a week is always seven. The buckets follow
/// the server (`timeline-dates.ts`): weeks from Monday, months from the 1st,
/// quarters from January, April, July and October.
public enum TimelineDay {
    /// The day number of `key`, or `nil` for anything that is not a valid key.
    public static func number(_ key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard key.count == 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1 ... 12).contains(month), (1 ... daysIn(year: year, month: month)).contains(day) else { return nil }
        return number(year: year, month: month, day: day)
    }

    /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
    public static func number(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Year, month and day of a calendar day.
    public struct Parts: Equatable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
    }

    /// Year, month and day of a day number.
    public static func components(_ number: Int) -> Parts {
        let shiftedNumber = number + 719_468
        let era = (shiftedNumber >= 0 ? shiftedNumber : shiftedNumber - 146_096) / 146_097
        let dayOfEra = shiftedNumber - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return Parts(year: year, month: month, day: day)
    }

    /// The key of a day number.
    public static func key(_ number: Int) -> String {
        let parts = components(number)
        return String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// 0 for Monday through 6 for Sunday. 1970-01-01 was a Thursday.
    public static func weekday(_ number: Int) -> Int {
        ((number + 3) % 7 + 7) % 7
    }

    /// The first day of the bucket that holds `day`.
    public static func bucketStart(_ day: Int, _ bucket: TimelineBucket) -> Int {
        switch bucket {
        case .day:
            return day
        case .week:
            return day - weekday(day)
        case .month:
            let parts = components(day)
            return number(year: parts.year, month: parts.month, day: 1)
        case .quarter:
            let parts = components(day)
            return number(year: parts.year, month: parts.month - (parts.month - 1) % 3, day: 1)
        }
    }

    /// The first day of the bucket after the one starting at `start`.
    public static func bucketAfter(_ start: Int, _ bucket: TimelineBucket) -> Int {
        switch bucket {
        case .day:
            return start + 1
        case .week:
            return start + 7
        case .month, .quarter:
            let parts = components(start)
            let step = bucket == .month ? 1 : 3
            let month = parts.month + step
            return month > 12
                ? number(year: parts.year + 1, month: month - 12, day: 1)
                : number(year: parts.year, month: month, day: 1)
        }
    }

    /// A running index of buckets: two neighbouring buckets differ by one.
    public static func bucketIndex(_ day: Int, _ bucket: TimelineBucket) -> Int {
        switch bucket {
        case .day:
            return day
        case .week:
            return Int((Double(bucketStart(day, .week)) / 7).rounded(.down))
        case .month:
            let parts = components(day)
            return parts.year * 12 + parts.month - 1
        case .quarter:
            let parts = components(day)
            return parts.year * 4 + (parts.month - 1) / 3
        }
    }

    /// The first day of the month that holds `day`, and the first of the next.
    public static func monthStart(_ day: Int) -> Int {
        bucketStart(day, .month)
    }

    /// The day key of `date` in `calendar`: by default the account's day
    /// (``ProfileDay``), the zone the server cuts the timeline's days in, so
    /// "today" on the axis is the server's today also on a phone abroad.
    public static func key(of date: Date, calendar: Calendar = ProfileDay.calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Midday of a day number in `calendar`, for formatting a day as text.
    public static func date(_ number: Int, calendar: Calendar = .current) -> Date {
        let parts = components(number)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? .distantPast
    }
}
