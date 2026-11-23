import Foundation

/// Tiny shared formatter for the labs surface. The wire `takenAt` / `createdAt`
/// are ISO-8601 strings (`LabsDTO` keeps them raw to avoid coupling decode to a
/// `Date` strategy). These helpers parse + present them; a malformed string
/// degrades to the raw value rather than crashing. Parsing reuses the app's
/// shared `ISO8601DateFormatter.fractional` / `.plain` (declared in
/// `APIClient.swift`) so there's exactly one formatter pair.
///
/// **The server's lab-day rule** (`isLabDateOnly` in `src/lib/labs/reading-day.ts`,
/// server commit a25658c85). A scanned or document reading states a date only;
/// the server stores it at noon UTC, older rows at UTC midnight. Such a
/// `takenAt` names a calendar date, not an instant, and is never moved into the
/// device's zone: west of UTC it would print and file on the day before. A
/// reading entered by hand carries the real instant of the draw and is shown in
/// the device's zone as before. ``labDate(_:)``, ``labDateTime(_:)`` and
/// ``readingDate(_:)`` apply the rule; ``parse(_:)``, ``mediumDate(_:)`` and
/// ``mediumDateTime(_:)`` stay the raw instant for the custom metrics.
enum LabsDateFormat {
    private static let dayMilliseconds: Int64 = 86_400_000
    private static let noonMilliseconds: Int64 = 43_200_000

    /// Parse an ISO-8601 wire string (with or without fractional seconds).
    static func parse(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }

    /// True when `date` sits exactly on 00:00:00.000 or 12:00:00.000 UTC: the
    /// server's date-only anchor rather than the instant of a draw.
    static func isDateOnly(_ date: Date) -> Bool {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let ofDay = ((milliseconds % dayMilliseconds) + dayMilliseconds) % dayMilliseconds
        return ofDay == 0 || ofDay == noonMilliseconds
    }

    /// True when the wire string is a date-only reading.
    static func isDateOnly(_ raw: String) -> Bool {
        parse(raw).map(isDateOnly) ?? false
    }

    /// The moment the labs surface places a reading at: for a date-only
    /// reading noon of that same calendar date in `calendar`'s zone, so it
    /// prints, sorts into and plots on the date the server files it under;
    /// otherwise the instant itself.
    static func readingDate(_ raw: String, calendar: Calendar = .current) -> Date? {
        guard let instant = parse(raw) else { return nil }
        return readingDate(instant, calendar: calendar)
    }

    static func readingDate(_ instant: Date, calendar: Calendar = .current) -> Date {
        guard isDateOnly(instant) else { return instant }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var parts = utc.dateComponents([.year, .month, .day], from: instant)
        parts.hour = 12
        return calendar.date(from: parts) ?? instant
    }

    /// Medium date (e.g. "17 Jun 2026"). Falls back to the raw string. Routes
    /// through ``HLDateFormat`` so the field order honours the user's
    /// server-backed date-format preference. The instant in the device's zone;
    /// custom metrics share it. A lab reading goes through ``labDate(_:)``.
    static func mediumDate(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return HLDateFormat.date(date, style: .abbreviated)
    }

    /// Medium date + short time (e.g. "17 Jun 2026, 08:30"). Falls back to raw.
    /// Routes the date through ``HLDateFormat`` (preference-aware field order).
    static func mediumDateTime(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return HLDateFormat.dateTime(date, style: .abbreviated)
    }

    /// A lab reading's medium date under the lab-day rule: a date-only
    /// reading keeps its calendar date in every zone.
    static func labDate(_ raw: String) -> String {
        guard let date = readingDate(raw) else { return raw }
        return HLDateFormat.date(date, style: .abbreviated)
    }

    /// A lab reading's date and time. A date-only reading has no time of
    /// day, so it shows its date alone.
    static func labDateTime(_ raw: String) -> String {
        guard let instant = parse(raw) else { return raw }
        guard !isDateOnly(instant) else { return labDate(raw) }
        return HLDateFormat.dateTime(instant, style: .abbreviated)
    }
}
