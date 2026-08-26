import Foundation

/// **Parity Build 4 · 4.7 — the ONE night-date authority for the sleep screens.**
///
/// ## The bug this replaces
///
/// ``SleepHypnogramScreen`` used to derive its night date TWICE, in two
/// different time zones:
///
///   - the navigation header formatted the wake-day anchor with a
///     UTC-pinned `Date.FormatStyle`, and
///   - the summary card below it rendered `session.start` — the bedtime
///     INSTANT — in the device's local zone.
///
/// Those are not the same date. A night that begins at 23:40 local and ends
/// the next morning has a bedtime instant on one calendar day and a wake day
/// on the next, so the header and the card directly under it printed two
/// different dates for one night. A user far from UTC saw the split on most
/// nights, not just around midnight.
///
/// ## The rule
///
/// **A night is named after its LOCAL wake day.** The user's night is a local
/// concept — they went to bed on their Tuesday evening and call the result
/// "Wednesday's sleep" regardless of where the UTC day boundary happened to
/// fall. Both surfaces now resolve their date through this one type, from the
/// same `YYYY-MM-DD` wake-day key, so they cannot drift apart again.
///
/// ## Why the anchor is rebuilt at local midnight
///
/// The wake-day key is calendar DIGITS, not an instant — the server keys
/// nights on the wake day in the user's own timezone. `SleepNightRepository`
/// parses those digits to midnight **UTC**, which is the correct opaque anchor
/// for day arithmetic (`←`/`→` navigation stays in UTC key space precisely so
/// the device zone can never shift a key). But rendering that UTC instant with
/// a LOCAL formatter is what would reintroduce the off-by-one: at UTC-7,
/// midnight-UTC on the 19th is 17:00 on the 18th. So for DISPLAY the digits
/// are re-anchored to local midnight, and only then formatted locally. The
/// printed date is therefore the wake day itself in every timezone.
enum SleepNightDay {
    /// Re-anchors a `YYYY-MM-DD` wake-day key to LOCAL midnight.
    ///
    /// - Returns: `nil` for a malformed key — callers omit the date rather
    ///   than printing a guess.
    static func localAnchor(forDayKey dayKey: String, calendar: Calendar = .current) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // Midday would also work and is DST-proof, but `.date(from:)` on a
        // gregorian calendar resolves a non-existent local midnight (spring
        // DST transitions in a few zones) forward on its own, so the digits
        // still land on the intended calendar day.
        return calendar.date(from: components)
    }

    /// The wake-day key of a decoded session.
    ///
    /// `SleepSession.night` decodes as the midnight-UTC anchor of the server's
    /// day key, so reading the digits back out must use the same UTC formatter
    /// the repository wrote them with — see the type doc for why this is not a
    /// contradiction of the "pick local" rule.
    static func dayKey(for session: SleepSession) -> String {
        SleepNightRepository.utcDayKey(for: session.night)
    }

    /// The date to PRINT for a session — its local wake day.
    ///
    /// This is what the summary card renders; the navigation header resolves
    /// the identical value from the same key, which is the whole point.
    static func displayDate(for session: SleepSession, calendar: Calendar = .current) -> Date? {
        localAnchor(forDayKey: dayKey(for: session), calendar: calendar)
    }

    /// Wake-day label style — LOCAL zone, paired with a local-midnight anchor.
    ///
    /// - Parameter timeZone: injectable for tests; production always passes
    ///   the device zone.
    static func labelStyle(timeZone: TimeZone = .current) -> Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone)
    }

    /// The rendered wake-day label for a key — the single string both the
    /// header and the summary card show.
    ///
    /// Exposed (rather than each call site composing anchor + style) so the
    /// regression test can assert the exact text one call away from what the
    /// screen paints.
    static func label(
        forDayKey dayKey: String,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let anchor = localAnchor(forDayKey: dayKey, calendar: calendar) else { return nil }
        return anchor.formatted(labelStyle(timeZone: timeZone).locale(locale))
    }
}

/// Shared `Xh Ym` duration rendering for every sleep surface.
///
/// Extracted from ``SleepHypnogramScreen``'s private helper so the rhythm
/// cards, the composition chart and the hypnogram all print a duration the
/// same way — the audit (`09-…md:141`) already flagged sleep duration
/// formatting as drifted between platforms, and a second in-app spelling
/// would have made that worse.
enum SleepDurationFormat {
    /// `"7 h 12 min"` / `"45 min"`, or an em-dash for absent / non-positive.
    static func hoursMinutes(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "—" }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return String(localized: "sleep.duration.hm \(hours) \(mins)")
        }
        return String(localized: "sleep.duration.m \(mins)")
    }

    /// Minutes-of-day (0…1439) as a wall-clock time, e.g. `"04:15"`.
    ///
    /// The chronotype measures are clock POSITIONS, not instants — the server
    /// sends a minute offset into the user's own day. Rendering them through a
    /// `Date` would drag a timezone into a number that has none, so the
    /// formatting is done on the digits directly, via a fixed local-midnight
    /// anchor so the locale still decides 24 h vs AM/PM.
    static func clockTime(minutesOfDay: Int, calendar: Calendar = .current) -> String {
        let normalized = ((minutesOfDay % 1440) + 1440) % 1440
        var components = DateComponents()
        components.hour = normalized / 60
        components.minute = normalized % 60
        // Anchor on an arbitrary fixed day — only the time part is rendered.
        components.year = 2000
        components.month = 1
        components.day = 1
        guard let date = calendar.date(from: components) else { return "—" }
        return date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: calendar.locale ?? .current,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }
}
