import Foundation
import os

/// **M3 (AUDIT-PARITY-v11612) — time-format preference (auto / 24h / 12h).**
///
/// Mirrors the server's `User.timeFormat` Prisma enum
/// (`src/lib/format-locale.ts` `TimeFormatPreference`): `AUTO` defers to the
/// device locale's own hour cycle (en → AM/PM, de → 24h), `H12` forces a
/// 12-hour AM/PM clock, `H24` forces a 24-hour clock. The server is
/// authoritative — the value is fetched from `GET /api/user/profile` and
/// pushed back via `PATCH` — but every *rendered* clock in the app reads it
/// through this ONE helper so the preference applies everywhere identically.
///
/// **Why a UserDefaults mirror?** Most time-rendering helpers on the medication
/// surfaces are `nonisolated static` (pure formatters the contract tests
/// exercise off the MainActor — see `ActiveMedicationRow.relativeDateTime`).
/// Threading the live `SettingsStore` through every one of them would invert
/// the dependency direction. Instead `SettingsStore` mirrors the
/// server-resolved value into a single UserDefaults key whenever the profile
/// loads, and the formatters read it synchronously here. UserDefaults usage is
/// inside the "UI-prefs" allowlist per PROJECT_GUIDE.md (no Health-data, no tokens —
/// purely a display preference).
public enum HLTimeFormat: String, CaseIterable, Sendable {
    /// Follow the device locale's own hour cycle.
    case auto = "AUTO"
    /// Force a 12-hour AM/PM clock.
    case twelveHour = "H12"
    /// Force a 24-hour clock.
    case twentyFourHour = "H24"

    /// UserDefaults key the `SettingsStore` mirror writes and the pure
    /// formatters read. Namespaced like the other `hl.settings.*` UI-prefs.
    public static let defaultsKey = "hl.settings.timeFormat"

    /// The currently effective preference, read from the UserDefaults mirror.
    /// Defaults to `.auto` when unset (fresh install / pre-mirror) so the
    /// device locale governs until the server profile lands.
    public static func current(defaults: UserDefaults = .standard) -> HLTimeFormat {
        HLTimeFormat(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .auto
    }

    /// Localised label for the Settings picker.
    public var label: String {
        switch self {
        case .auto: String(localized: "settings.time_format.auto")
        case .twelveHour: String(localized: "settings.time_format.h12")
        case .twentyFourHour: String(localized: "settings.time_format.h24")
        }
    }

    /// The `Locale` to hand a `Date.FormatStyle` so the hour cycle honours the
    /// preference. `AUTO` returns `.current` (the device locale governs). The
    /// forced cases append a Unicode `-u-hc-` subtag to the current locale's
    /// identifier so only the hour cycle is pinned while the rest of the
    /// locale (day / month order, separators) stays the device's own. `h23`
    /// is the 24-hour cycle whose midnight is `00:00` (never `24:00`); `h12`
    /// is the AM/PM cycle.
    public var formattingLocale: Locale {
        switch self {
        case .auto:
            .current
        case .twelveHour:
            Self.localeForcing(.oneToTwelve)
        case .twentyFourHour:
            Self.localeForcing(.zeroToTwentyThree)
        }
    }

    /// Builds a locale identical to the device locale except for a pinned
    /// hour cycle, so only the AM/PM-vs-24h read changes while day / month
    /// order and separators stay the device's own.
    private static func localeForcing(_ cycle: Locale.HourCycle) -> Locale {
        var components = Locale.Components(locale: .current)
        components.hourCycle = cycle
        return Locale(components: components)
    }

    /// Format a `Date`'s time-of-day (hour + minute) honouring the preference.
    /// Routes through `Date.FormatStyle` with the resolved
    /// ``formattingLocale`` so the AM/PM vs 24h read follows the server pick.
    public func formatTime(_ date: Date, defaults: UserDefaults = .standard) -> String {
        Self.shortTime(date, locale: formattingLocale, timeZone: .current)
    }

    /// The time of day in the system's own short form: `DateFormatter` with
    /// `timeStyle = .short`, which is what the status-bar clock shows (08:00 in
    /// German and Dutch, 8:00 AM in American English). `Date.FormatStyle`'s
    /// `.shortened` drops the leading zero in those locales ("8:00"), so the
    /// app read differently from the phone it runs on.
    public static func shortTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        clockText(date, style: .short, locale: locale, timeZone: timeZone)
    }

    /// The time of day with its seconds, for a log in which two events fall
    /// into one minute: 08:00:05 in German and Dutch, 8:00:05 AM in American
    /// English. The system's own medium form, so hour and minute read as in
    /// ``shortTime(_:locale:timeZone:)``.
    public static func timeWithSeconds(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        clockText(date, style: .medium, locale: locale, timeZone: timeZone)
    }

    /// The same in the 12- or 24-hour form the user chose.
    public static func timeWithSeconds(_ date: Date, defaults: UserDefaults = .standard) -> String {
        timeWithSeconds(date, locale: current(defaults: defaults).formattingLocale, timeZone: .current)
    }

    private static func clockText(
        _ date: Date,
        style: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let key = "\(style.rawValue)|" + locale.identifier + "|" + timeZone.identifier
        return formatters.withLockUnchecked { cache in
            let formatter: DateFormatter
            if let cached = cache[key] {
                formatter = cached
            } else {
                formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = timeZone
                formatter.dateStyle = .none
                formatter.timeStyle = style
                cache[key] = formatter
            }
            return formatter.string(from: date)
        }
    }

    /// One formatter per form, locale and zone. `DateFormatter` is not
    /// `Sendable`, so it is only ever touched inside the lock; the callers are
    /// `nonisolated`.
    private static let formatters = OSAllocatedUnfairLock(uncheckedState: [String: DateFormatter]())

    /// Static convenience: format `date`'s time-of-day with the *currently
    /// effective* preference (UserDefaults mirror). The pure med formatters
    /// call this so they need no store dependency.
    public static func time(_ date: Date, defaults: UserDefaults = .standard) -> String {
        current(defaults: defaults).formatTime(date, defaults: defaults)
    }
}

public extension HLTimeFormat {
    /// A length of time in hours and minutes: "1 hr 20 min", "45 min".
    ///
    /// Rounded to the minute. Minutes are left out on the full hour; a length
    /// under a minute reads as zero minutes, not as nothing.
    static func duration(_ interval: TimeInterval, locale: Locale = .current) -> String {
        durationParts(interval, locale: locale).joined(separator: " ")
    }

    /// The hours and the minutes of ``duration(_:locale:)`` on their own, so a
    /// narrow cell can stack them on two lines in the same words.
    static func durationParts(_ interval: TimeInterval, locale: Locale = .current) -> [String] {
        let totalMinutes = Int((max(0, interval) / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        // Each unit is formatted alone and the two are joined by a space:
        // formatted together, German puts a comma between them.
        var parts: [String] = []
        if hours > 0 {
            parts.append(Duration.seconds(hours * 3600).formatted(
                .units(allowed: [.hours], width: .abbreviated).locale(locale)
            ))
        }
        if minutes > 0 || hours == 0 {
            parts.append(Duration.seconds(minutes * 60).formatted(
                .units(allowed: [.minutes], width: .abbreviated).locale(locale)
            ))
        }
        return parts
    }

    /// A time of day that belongs to no date, such as a daily intake time,
    /// given as minutes after midnight. Values outside one day wrap around.
    static func clock(minutesAfterMidnight minutes: Int, locale: Locale) -> String {
        let minutesPerDay = 24 * 60
        let wrapped = ((minutes % minutesPerDay) + minutesPerDay) % minutesPerDay
        // Counted in GMT from a fixed day, so no time zone and no change of
        // the clocks can move the result.
        return shortTime(
            Date(timeIntervalSinceReferenceDate: TimeInterval(wrapped * 60)),
            locale: locale,
            timeZone: .gmt
        )
    }

    /// The same in the 12- or 24-hour form the user chose.
    static func clock(minutesAfterMidnight minutes: Int, defaults: UserDefaults = .standard) -> String {
        clock(minutesAfterMidnight: minutes, locale: current(defaults: defaults).formattingLocale)
    }
}
