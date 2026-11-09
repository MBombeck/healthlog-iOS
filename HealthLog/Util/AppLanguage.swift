import Foundation

/// **The language the app's own interface renders in.**
///
/// iOS resolves `Bundle.main.preferredLocalizations` against the languages the
/// app ships (`CFBundleLocalizations`: de, en, nl, ko), so its first entry is the
/// language every catalogue string on screen is in. `Locale.current` is the
/// DEVICE language and can name one the app does not ship: a French phone
/// renders the English interface, yet `Locale.current.language.languageCode`
/// says "fr". Before this type, every `languageCode == "en" ? "en" : "de"`
/// branch sent that reader German server prose, German on-device prompts and
/// a German PDF under an English interface, and every Dutch reader the same.
///
/// Anything whose text must match the visible copy (server-rendered prose, the
/// on-device model's prompts and output language, the doctor report) reads
/// this type instead of `Locale.current`. `scripts/i18n-guard.py` fails the
/// lint step when app code outside this file asks for a language code or the
/// bundle's localizations; see `docs/localization.md`.
public enum AppLanguage: String, Sendable, CaseIterable, Equatable {
    case de
    case en
    case nl
    case ko

    /// Tests only: pins ``current`` for the running task and its child tasks,
    /// so a request capture can run the same code under every interface
    /// language without relaunching the host app.
    @TaskLocal static var pinned: AppLanguage?

    /// The interface language right now. Never a language the app does not
    /// ship; English when the bundle answers nothing (the catalogue's
    /// `sourceLanguage` and the project's `developmentLanguage`).
    public static var current: AppLanguage {
        pinned ?? resolve(Bundle.main.preferredLocalizations.first)
    }

    /// Map a language tag ("nl", "nl-BE", "de_AT", "en-US") to a shipped
    /// language by its primary subtag. Anything else reads English, the
    /// language the interface itself falls back to.
    public static func resolve(_ identifier: String?) -> AppLanguage {
        guard let identifier else { return .en }
        let primary = identifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        return AppLanguage(rawValue: primary) ?? .en
    }

    /// Same mapping for a `Locale`, for the services that take one as a
    /// parameter (on-device prompts, tests that pin a language).
    public static func resolve(_ locale: Locale) -> AppLanguage {
        resolve(locale.language.languageCode?.identifier)
    }

    /// A `Locale` for formatting in this language (dates, numbers, the
    /// on-device model's locale). Region-neutral on purpose: a Belgian reader
    /// of Dutch keeps their region through `Locale.current` wherever the
    /// region matters.
    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// The `locale` for a server endpoint that accepts every interface
    /// language (narratives, status prose, derived insights, the health-record
    /// export, medication extraction, the screeners).
    public var serverCode: String {
        rawValue
    }

    // MARK: - Chat bodies (Coach, document chat)

    /// First server whose Coach and document chat bodies take every interface
    /// language (#157 point 2). Older servers validate `locale` as `de` or
    /// `en` and answer anything else with a 422.
    static let chatAllLanguagesMinimumServerVersion = "1.46.2"

    /// The `locale` for the two chat request bodies. German and English go to
    /// every server. Any other language goes only to a server known to be at
    /// least ``chatAllLanguagesMinimumServerVersion``; otherwise the field is
    /// left out and the server resolves the reader's language itself (account
    /// language, then `Accept-Language`). An unknown server version counts as
    /// too old.
    public func chatServerCode(serverAcceptsEveryLanguage: Bool) -> String? {
        switch self {
        case .de, .en: rawValue
        case .nl, .ko: serverAcceptsEveryLanguage ? rawValue : nil
        }
    }

    /// ``chatServerCode(serverAcceptsEveryLanguage:)`` against the one
    /// remembered server version (``KnownServerVersion``).
    public func chatServerCode(defaults: UserDefaults = .standard) -> String? {
        chatServerCode(
            serverAcceptsEveryLanguage: KnownServerVersion.isAtLeast(
                Self.chatAllLanguagesMinimumServerVersion,
                defaults: defaults
            )
        )
    }

    // MARK: - Region

    /// The device region, when there is one. Region stays a device fact: the
    /// interface language never implies a country.
    static var deviceRegion: String? {
        Locale.current.region?.identifier
    }

    /// `<language>-<REGION>` from the device region, for fields that take a
    /// free language tag (the screener's `locale`, whose crisis set follows the
    /// country): `nl-BE`, `de-AT`, `en-US`, and `en-PT` for a Portuguese phone
    /// with the English interface. Just the language without a region.
    public var regionTag: String {
        regionTag(region: Self.deviceRegion)
    }

    func regionTag(region: String?) -> String {
        guard let region, !region.isEmpty else { return rawValue }
        return "\(rawValue)-\(region.uppercased())"
    }

    // MARK: - Formatting

    /// Language plus device region when that pairing is a real locale
    /// (`nl_BE` stays `nl_BE`, `en_DE` stays `en_DE`), else the language's
    /// home locale (`nl` on a German phone formats as `nl_NL`). For formatters
    /// whose month and weekday names must read in the interface language.
    public var formattingLocale: Locale {
        formattingLocale(region: Self.deviceRegion)
    }

    func formattingLocale(region: String?) -> Locale {
        if let region, !region.isEmpty {
            let paired = "\(rawValue)_\(region.uppercased())"
            if Locale.availableIdentifiers.contains(paired) {
                return Locale(identifier: paired)
            }
        }
        return Locale(identifier: homeLocaleIdentifier)
    }

    /// The locale a language formats in when the device region does not pair
    /// with it.
    var homeLocaleIdentifier: String {
        switch self {
        case .de: "de_DE"
        case .en: "en_US"
        case .nl: "nl_NL"
        case .ko: "ko_KR"
        }
    }

    /// A locale in this language whose numeric date order is day, month,
    /// year, for the pinned DMY date preference (``HLDateFormat``). Month
    /// names follow the interface: before 1.5 every language got `de_DE`, so
    /// an English reader with DMY saw "17. Juni 2026".
    var dayMonthYearLocale: Locale {
        switch self {
        case .de: Locale(identifier: "de_DE")
        case .en: Locale(identifier: "en_GB")
        case .nl: Locale(identifier: "nl_NL")
        // No Korean locale orders a numeric date day first, and Korean spells
        // a date year first whatever the pick. The pick therefore governs the
        // numeric style only (`en_GB`: 17/06/2026); ``HLDateFormat`` renders
        // the spelled-out styles in Korean.
        case .ko: Locale(identifier: "en_GB")
        }
    }
}
