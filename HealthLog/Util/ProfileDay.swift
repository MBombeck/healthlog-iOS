import Foundation

/// **#115 1.5 — one calendar for server day keys.**
///
/// The server cuts every day-scoped row (mood entries, cycle day logs, illness
/// day logs, medication courses, compliance buckets, sleep nights) in the
/// account's zone, `/api/auth/me` `timezone`. A day key the app sends, and the
/// day a server key names, must therefore be read in that zone, never in
/// `Calendar.current`: for anyone whose phone is set to another zone than the
/// account (travel, a second device, a zone the server resolved to its default)
/// the device calendar names a different day for the same instant.
///
/// Two representations meet here, and this type is the only bridge:
///
/// - **An instant → its day in the profile zone** (``key(for:timeZone:)``) —
///   for "which day did this happen on" and "what is today".
/// - **A server date-only key ↔ `Date`** (``anchor(forKey:)`` /
///   ``key(ofAnchor:)``). `JSONDecoder.hlDefault` decodes `YYYY-MM-DD` as UTC
///   midnight. That instant is an ANCHOR for a calendar date, not a moment in
///   time: reading it back through `Calendar.current` names the previous day
///   everywhere west of UTC. Anchors are compared and re-keyed in UTC only.
///
/// The zone comes from ``ProfileTimeZoneBox/shared``, which the settings store
/// feeds from `/me` and which mirrors the last answer for a launch that has not
/// loaded a profile yet (a background wake). Every entry point takes the zone
/// as a parameter so a test can pin it.
public enum ProfileDay {
    /// The account zone right now (device zone until the first `/me` answer
    /// ever arrived on this install).
    public static var timeZone: TimeZone {
        ProfileTimeZoneBox.shared.current
    }

    /// A Gregorian calendar in `timeZone`. POSIX-neutral: only the zone and the
    /// era arithmetic matter for day keys.
    public static func calendar(in timeZone: TimeZone = ProfileDay.timeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `YYYY-MM-DD` of the day `date` falls on in `timeZone`.
    public static func key(for date: Date = .now, timeZone: TimeZone = ProfileDay.timeZone) -> String {
        format(calendar(in: timeZone).dateComponents([.year, .month, .day], from: date))
    }

    /// Start of the day `date` falls on, in `timeZone`.
    public static func startOfDay(for date: Date = .now, timeZone: TimeZone = ProfileDay.timeZone) -> Date {
        calendar(in: timeZone).startOfDay(for: date)
    }

    /// Midnight, in `timeZone`, of the day a `YYYY-MM-DD` key names — the
    /// instant a date picker running in the profile zone shows as that day.
    /// `nil` for anything that is not a valid calendar date.
    public static func startOfDay(forKey key: String, timeZone: TimeZone = ProfileDay.timeZone) -> Date? {
        guard let anchor = anchor(forKey: key) else { return nil }
        let components = utcCalendar.dateComponents([.year, .month, .day], from: anchor)
        return calendar(in: timeZone).date(from: components)
    }

    /// The key `days` calendar days after `key` (negative = before). Pure date
    /// arithmetic on the anchor, so no zone can move it.
    public static func key(_ key: String, addingDays days: Int) -> String {
        guard let anchor = anchor(forKey: key),
              let moved = utcCalendar.date(byAdding: .day, value: days, to: anchor) else { return key }
        return Self.key(ofAnchor: moved)
    }

    // MARK: - Date-only anchors (UTC midnight)

    /// The UTC-midnight anchor for a `YYYY-MM-DD` key — the same instant
    /// `JSONDecoder.hlDefault` produces for a server date-only field. `nil` for
    /// anything that is not a valid calendar date.
    public static func anchor(forKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = utcCalendar.date(from: components),
              Self.key(ofAnchor: date) == format(components) else { return nil }
        return date
    }

    /// The `YYYY-MM-DD` a UTC-midnight anchor stands for (a decoded server
    /// date-only field, or ``anchor(forKey:)``). Read in UTC, so the device
    /// zone can never shift it.
    public static func key(ofAnchor anchor: Date) -> String {
        format(utcCalendar.dateComponents([.year, .month, .day], from: anchor))
    }

    /// The anchor of the day `date` falls on in `timeZone`: "today in the
    /// account" expressed in the same representation the server's date-only
    /// fields decode to.
    public static func anchor(for date: Date = .now, timeZone: TimeZone = ProfileDay.timeZone) -> Date {
        anchor(forKey: key(for: date, timeZone: timeZone)) ?? date
    }

    /// Gregorian calendar pinned to UTC — the calendar date-only anchors live in.
    public static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func format(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
