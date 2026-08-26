import Foundation

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
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(formattingLocale)
        )
    }

    /// Static convenience: format `date`'s time-of-day with the *currently
    /// effective* preference (UserDefaults mirror). The pure med formatters
    /// call this so they need no store dependency.
    public static func time(_ date: Date, defaults: UserDefaults = .standard) -> String {
        current(defaults: defaults).formatTime(date, defaults: defaults)
    }
}
