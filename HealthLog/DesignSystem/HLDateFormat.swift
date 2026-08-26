import Foundation

/// **A360-1 H1 / A360-4 QoL-3 — date-format preference (auto / DMY / MDY / YMD).**
///
/// Mirrors the server's `User.dateFormat` Prisma enum
/// (`src/lib/format-locale.ts` `DateFormatPreference`): `AUTO` defers to the
/// device locale's own field order (en-US → MM/dd/yyyy, de-DE → dd.MM.yyyy),
/// `DMY` pins day-month-year, `MDY` pins month-day-year, `YMD` pins ISO
/// yyyy-MM-dd. The server is authoritative — the value is fetched from
/// `GET /api/user/profile` and pushed back via `PATCH` — but every *rendered*
/// date in the app reads it through this ONE helper so the preference applies
/// everywhere identically.
///
/// This is the date sibling of ``HLTimeFormat`` and follows the same
/// UserDefaults-mirror pattern: most date-rendering helpers on the labs /
/// illness / share-link surfaces are pure formatters (the contract tests
/// exercise them off the MainActor), so threading the live `SettingsStore`
/// through every one would invert the dependency direction. Instead
/// `SettingsStore` mirrors the server-resolved value into a single UserDefaults
/// key whenever the profile loads, and the formatters read it synchronously
/// here. UserDefaults usage is inside the "UI-prefs" allowlist per PROJECT_GUIDE.md
/// (no Health-data, no tokens — purely a display preference).
///
/// **Field-order via a pinned locale.** The numeric field order is a property
/// of the BCP-47 locale, not a `Date.FormatStyle` option, so the non-AUTO
/// cases pin a canonical locale whose default numeric date order matches the
/// requested preference — exactly the server's `dateOrderLocale` mapping
/// (DMY → de-DE `dd.MM.yyyy`, MDY → en-US `MM/dd/yyyy`, YMD → en-CA/ISO
/// `yyyy-MM-dd`). AUTO keeps the device's own locale.
public enum HLDateFormat: String, CaseIterable, Sendable {
    /// Follow the device locale's own field order.
    case auto = "AUTO"
    /// Pin day-month-year (dd.MM.yyyy).
    case dayMonthYear = "DMY"
    /// Pin month-day-year (MM/dd/yyyy).
    case monthDayYear = "MDY"
    /// Pin ISO year-month-day (yyyy-MM-dd).
    case yearMonthDay = "YMD"

    /// UserDefaults key the `SettingsStore` mirror writes and the pure
    /// formatters read. Namespaced like the other `hl.settings.*` UI-prefs.
    public static let defaultsKey = "hl.settings.dateFormat"

    /// The currently effective preference, read from the UserDefaults mirror.
    /// Defaults to `.auto` when unset (fresh install / pre-mirror) so the
    /// device locale governs until the server profile lands.
    public static func current(defaults: UserDefaults = .standard) -> HLDateFormat {
        HLDateFormat(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .auto
    }

    /// Localised label for the Settings picker.
    public var label: String {
        switch self {
        case .auto: String(localized: "settings.date_format.auto")
        case .dayMonthYear: String(localized: "settings.date_format.dmy")
        case .monthDayYear: String(localized: "settings.date_format.mdy")
        case .yearMonthDay: String(localized: "settings.date_format.ymd")
        }
    }

    /// The `Locale` to hand a `Date.FormatStyle` so the numeric field order
    /// honours the preference. `AUTO` returns `.current` (the device locale
    /// governs); the pinned cases return the canonical locale whose default
    /// numeric date order matches the requested preference — identical to the
    /// server's `dateOrderLocale`.
    public var formattingLocale: Locale {
        switch self {
        case .auto: .current
        case .dayMonthYear: Locale(identifier: "de_DE")
        case .monthDayYear: Locale(identifier: "en_US")
        case .yearMonthDay: Locale(identifier: "en_CA")
        }
    }

    /// A `Date.FormatStyle` style for date display. The canonical app default is
    /// `.abbreviated` (e.g. "17 Jun 2026") — the most common existing style.
    public enum Style: Sendable {
        /// Numeric date in the preference's field order (e.g. 17.06.2026 /
        /// 06/17/2026 / 2026-06-17). Routes through `.numeric` so the pinned
        /// locale governs the field order; for non-AUTO this is the user's
        /// explicit pick rendered numerically.
        case numeric
        /// Abbreviated month (e.g. "17 Jun 2026" / "Jun 17, 2026"). The
        /// preference still governs the field order via the pinned locale.
        case abbreviated
        /// Long month (e.g. "17 June 2026" / "June 17, 2026").
        case long
        /// Full date incl. weekday (e.g. "Wed, 17 Jun 2026").
        case complete
    }

    /// Format `date` honouring the preference + the requested style. Routes
    /// through `Date.FormatStyle` with the resolved ``formattingLocale`` so the
    /// field order follows the server pick while the device timezone governs
    /// the calendar day.
    public func formatDate(_ date: Date, style: Style = .abbreviated) -> String {
        date.formatted(Self.formatStyle(for: style).locale(formattingLocale))
    }

    /// Format `date` honouring BOTH the date-order preference AND the
    /// 12h/24h time preference (``HLTimeFormat``).
    ///
    /// **BH-final-diff M6.** The date-order pref pins a canonical locale
    /// (`formattingLocale`) whose DEFAULT hour cycle would otherwise silently
    /// govern the time component (MDY → `en_US` → 12h regardless of an H24 pref;
    /// DMY → `de_DE` → 24h regardless of an H12 pref). The two prefs are
    /// orthogonal, so we compose: take the date-order locale for the
    /// day/month/separator layout, then force its hour cycle from the live
    /// ``HLTimeFormat`` so an explicit AM/PM-vs-24h pick is honoured here too.
    public func formatDateTime(
        _ date: Date,
        style: Style = .abbreviated,
        defaults: UserDefaults = .standard
    ) -> String {
        let locale = Self.dateTimeLocale(
            dateOrder: formattingLocale,
            timeFormat: HLTimeFormat.current(defaults: defaults)
        )
        return date.formatted(
            Self.formatStyle(for: style, includeTime: true).locale(locale)
        )
    }

    /// Compose the date-order locale with the time pref's hour cycle. `AUTO`
    /// time keeps the date-order locale's own hour cycle (the prior behaviour);
    /// a forced H12/H24 pins the cycle while leaving day/month order untouched.
    private static func dateTimeLocale(dateOrder: Locale, timeFormat: HLTimeFormat) -> Locale {
        let cycle: Locale.HourCycle? = switch timeFormat {
        case .auto: nil
        case .twelveHour: .oneToTwelve
        case .twentyFourHour: .zeroToTwentyThree
        }
        guard let cycle else { return dateOrder }
        var components = Locale.Components(locale: dateOrder)
        components.hourCycle = cycle
        return Locale(components: components)
    }

    private static func formatStyle(for style: Style, includeTime: Bool = false) -> Date.FormatStyle {
        let time: Date.FormatStyle.TimeStyle = includeTime ? .shortened : .omitted
        return switch style {
        case .numeric: Date.FormatStyle(date: .numeric, time: time)
        case .abbreviated: Date.FormatStyle(date: .abbreviated, time: time)
        case .long: Date.FormatStyle(date: .long, time: time)
        case .complete: Date.FormatStyle(date: .complete, time: time)
        }
    }

    // MARK: - Static conveniences (UserDefaults-mirror)

    /// Format `date` with the *currently effective* preference (UserDefaults
    /// mirror). The pure labs / illness / share-link formatters call this so
    /// they need no store dependency.
    public static func date(
        _ date: Date,
        style: Style = .abbreviated,
        defaults: UserDefaults = .standard
    ) -> String {
        current(defaults: defaults).formatDate(date, style: style)
    }

    /// Format `date` (with a short time) using the currently effective
    /// preference (UserDefaults mirror).
    public static func dateTime(
        _ date: Date,
        style: Style = .abbreviated,
        defaults: UserDefaults = .standard
    ) -> String {
        current(defaults: defaults).formatDateTime(date, style: style, defaults: defaults)
    }

    // MARK: - Compact day+month with conditional year (b215)

    /// Compact **day + month** for historical list rows, appending the **year**
    /// only when `date` falls outside `now`'s calendar year. Same-year dates keep
    /// the tight "14. Juni" / "Jun 14" form; a prior- (or future-) year date reads
    /// "14. Juni 2024" / "Jun 14, 2024" so a historical row is never ambiguous
    /// about which year it belongs to.
    ///
    /// Field order, month styling and separators come from `locale` — Foundation
    /// orders day / month / year per the BCP-47 locale, so localisation is
    /// automatic (no hardcoded month names). Month width matches the app's
    /// existing bare `.day().month()` call-sites (`.abbreviated`). `now` and
    /// `calendar` are injected (defaulting to `Date()` / `.current`) so unit
    /// tests can pin them deterministically across time zones.
    public static func dayMonth(
        _ date: Date,
        relativeTo now: Date = Date(),
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        appendingYearIfNeeded(
            date,
            base: Date.FormatStyle().day().month().locale(locale),
            relativeTo: now,
            calendar: calendar
        )
    }

    /// Append the **year** to an arbitrary day/month `base` style, but only when
    /// `date` isn't in `now`'s calendar year. Lets sites that carry extra
    /// components (a weekday prefix, an `hour().minute()` suffix) share the exact
    /// same "year only when not the current year" decision as
    /// ``dayMonth(_:relativeTo:locale:calendar:)`` instead of duplicating the
    /// `Calendar` year comparison. Foundation slots the appended year into the
    /// locale-correct position, so the rest of the template is untouched.
    public static func appendingYearIfNeeded(
        _ date: Date,
        base: Date.FormatStyle,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        return date.formatted(sameYear ? base : base.year())
    }
}
