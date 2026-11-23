import Foundation

/// A time of day written the way the person's clock reads: 08:00 in German and
/// Dutch, 8:00 AM in American English, or what the account's time-format
/// choice forces (``HLTimeFormat``). Same system format as the status bar.
///
/// The hour and minute are a wall-clock time, not an instant, so they are
/// formatted on a fixed day in a fixed zone: no daylight-saving gap can move
/// them.
enum ClockTimeText {
    static func text(
        hour: Int,
        minute: Int = 0,
        locale: Locale = HLTimeFormat.current().formattingLocale
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)
        let date = calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
        return HLTimeFormat.shortTime(date, locale: locale, timeZone: .gmt)
    }

    /// A list of times of day, earliest first, joined for one line.
    static func list(
        _ times: [TimeOfDay],
        locale: Locale = HLTimeFormat.current().formattingLocale
    ) -> String {
        times
            .sorted()
            .map { text(hour: $0.hour, minute: $0.minute, locale: locale) }
            .joined(separator: ", ")
    }
}

extension ClockTimeText {
    /// **#191 point 7 — a stored `HH:mm` in the person's hour cycle.** The
    /// server keeps dose times and windows as 24-hour wall-clock strings
    /// ("08:00", "20:30"); shown raw they ignored a 12-hour setting while the
    /// instants beside them followed it. Anything that is not `H:mm`/`HH:mm`
    /// is shown as it came.
    static func wire(
        _ hhmm: String,
        locale: Locale = HLTimeFormat.current().formattingLocale
    ) -> String {
        guard let (hour, minute) = parse(hhmm) else { return hhmm }
        return text(hour: hour, minute: minute, locale: locale)
    }

    /// `(hour, minute)` of a 24-hour `H:mm`/`HH:mm` (seconds tolerated).
    nonisolated static func parse(_ hhmm: String) -> (Int, Int)? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, parts[0].count <= 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return (hour, minute)
    }
}
