import Foundation

/// **The report language is an interface language.**
///
/// `ReportLocale` has one case per `AppLanguage` (the initialiser is an
/// exhaustive switch), and everything a report language needs besides its
/// table comes from `AppLanguage`: the home locale for dates and numbers, and
/// what the server's `/api/export/health-record` accepts.
public extension ReportLocale {
    /// The interface language this report language belongs to.
    var appLanguage: AppLanguage {
        switch self {
        case .de: .de
        case .en: .en
        case .nl: .nl
        case .ko: .ko
        case .es: .es
        }
    }

    /// Dates and numbers in the report. The language's home locale, never the
    /// device region: a report printed on an English iPhone in Germany for a
    /// doctor in London reads "4 Nov", not "4. Nov", and a German report reads
    /// "72,4" on any phone.
    var formattingLocale: Locale {
        Locale(identifier: foundationIdentifier)
    }

    /// The first server that takes `nl` on `POST /api/export/health-record`
    /// (`exportSelectionSchema.locale` is `z.enum(locales)` and `nl` joined
    /// `locales` in 1.43.7; an older server answers 422 to it).
    static let dutchExportMinimumServerVersion = "1.43.7"

    /// The first server that takes `ko` there: Korean joined `locales` in
    /// 1.37.32 ("add Korean as a seventh end-to-end locale").
    static let koreanExportMinimumServerVersion = "1.37.32"

    /// The first server known to take `es` there. Spanish sat in `locales`
    /// before Korean joined it, so every server that takes `ko` takes `es`;
    /// the app asks no older server for it.
    static let spanishExportMinimumServerVersion = koreanExportMinimumServerVersion

    /// The `locale` for the server-rendered report. German and English always;
    /// Dutch only from ``dutchExportMinimumServerVersion``, Korean only from
    /// ``koreanExportMinimumServerVersion`` and Spanish only from
    /// ``spanishExportMinimumServerVersion``, else English, the language an
    /// unknown reader gets everywhere else.
    func exportServerCode(
        serverAcceptsDutch: Bool,
        serverAcceptsKorean: Bool = false,
        serverAcceptsSpanish: Bool = false
    ) -> String {
        switch self {
        case .de, .en: rawValue
        case .nl: serverAcceptsDutch ? rawValue : ReportLocale.en.rawValue
        case .ko: serverAcceptsKorean ? rawValue : ReportLocale.en.rawValue
        case .es: serverAcceptsSpanish ? rawValue : ReportLocale.en.rawValue
        }
    }

    func exportServerCode(defaults: UserDefaults = .standard) -> String {
        exportServerCode(
            serverAcceptsDutch: KnownServerVersion.isAtLeast(Self.dutchExportMinimumServerVersion, defaults: defaults),
            serverAcceptsKorean: KnownServerVersion.isAtLeast(Self.koreanExportMinimumServerVersion, defaults: defaults),
            serverAcceptsSpanish: KnownServerVersion.isAtLeast(Self.spanishExportMinimumServerVersion, defaults: defaults)
        )
    }

    /// The language's own name for the picker ("Deutsch", "English",
    /// "Nederlands", "한국어", "Español"): a reader choosing a language for someone else looks for
    /// that language's name.
    var endonym: String {
        let locale = Locale(identifier: rawValue)
        return locale.localizedString(forLanguageCode: rawValue)?.capitalized(with: locale) ?? rawValue
    }
}
