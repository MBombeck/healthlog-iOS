import Foundation
@testable import HealthLog
import Testing

/// ``AppLanguage`` maps a tag to the interface language the app actually ships
/// (de / en / nl), so server prose, on-device prompts and the PDF follow the
/// visible copy instead of the device language.
@Suite("AppLanguage")
struct AppLanguageTests {
    @Test("Shipped languages resolve by their primary subtag, any region or separator")
    func shippedLanguages() {
        #expect(AppLanguage.resolve("de") == .de)
        #expect(AppLanguage.resolve("de_AT") == .de)
        #expect(AppLanguage.resolve("en-GB") == .en)
        #expect(AppLanguage.resolve("nl") == .nl)
        #expect(AppLanguage.resolve("nl-BE") == .nl)
        #expect(AppLanguage.resolve("NL_nl") == .nl)
    }

    @Test("A language the app does not ship reads English, like the interface itself")
    func unshippedLanguagesReadEnglish() {
        // Before AppLanguage a French device fell through to German prose.
        #expect(AppLanguage.resolve("fr") == .en)
        #expect(AppLanguage.resolve("fr_FR") == .en)
        #expect(AppLanguage.resolve("") == .en)
        #expect(AppLanguage.resolve(nil as String?) == .en)
    }

    @Test("A Locale resolves the same way as its identifier")
    func localeResolution() {
        #expect(AppLanguage.resolve(Locale(identifier: "nl_NL")) == .nl)
        #expect(AppLanguage.resolve(Locale(identifier: "de_CH")) == .de)
        #expect(AppLanguage.resolve(Locale(identifier: "it_IT")) == .en)
    }

    @Test("Open endpoints get every language as its own code")
    func serverCodes() {
        #expect(AppLanguage.de.serverCode == "de")
        #expect(AppLanguage.en.serverCode == "en")
        #expect(AppLanguage.nl.serverCode == "nl")
    }

    @Test("The current language is always one the app ships")
    func currentIsShipped() {
        #expect(AppLanguage.allCases.contains(AppLanguage.current))
    }

    /// The full suite runs German (`-testLanguage de`); the language run of
    /// 1.5 L10N-FINAL runs the language suites with `-testLanguage nl`. Either
    /// way the host follows the requested test language, and a pin overrides it.
    @Test("The unit-test host runs the requested test language (de for the suite), and a pin overrides it per task")
    func pinOverridesCurrent() {
        let requested = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        let host = AppLanguage.resolve(requested ?? "de")
        #expect(AppLanguage.current == host)
        for language in AppLanguage.allCases {
            #expect(AppLanguage.$pinned.withValue(language) { AppLanguage.current } == language)
        }
        #expect(AppLanguage.current == host)
    }

    /// iOS itself picks the bundle localization; this is the same algorithm the
    /// app host runs, asked for a device that prefers a language the app does
    /// not ship.
    @Test("iOS resolves a French device to the English interface, never German")
    func frenchDeviceGetsEnglish() {
        let shipped = AppLanguage.allCases.map(\.rawValue)
        for preferences in [["fr-FR"], ["fr-FR", "it-IT"], ["pt-PT"]] {
            let resolved = Bundle.preferredLocalizations(from: shipped, forPreferences: preferences).first
            #expect(AppLanguage.resolve(resolved) == .en, "\(preferences) resolved \(resolved ?? "nil")")
        }
        let belgian = Bundle.preferredLocalizations(from: shipped, forPreferences: ["nl-BE"]).first
        #expect(AppLanguage.resolve(belgian) == .nl)
        let austrian = Bundle.preferredLocalizations(from: shipped, forPreferences: ["de-AT"]).first
        #expect(AppLanguage.resolve(austrian) == .de)
    }

    @Test("Every language the gates know has a case in AppLanguage")
    func languageListMatchesCode() {
        let list = CatalogLanguages.statusByLanguage
        #expect(!list.isEmpty, "scripts/l10n/languages.json not readable")
        let known = Set(AppLanguage.allCases.map(\.rawValue))
        #expect(Set(list.keys).isSubset(of: known), "languages.json names a language without a case: \(list.keys.sorted())")
        #expect(CatalogLanguages.required.contains("de"))
        #expect(CatalogLanguages.required.contains("en"))
    }

    // MARK: - Chat bodies

    @Test("Chat bodies: de and en always, nl only from server 1.46.2")
    func chatPolicy() {
        #expect(AppLanguage.de.chatServerCode(serverAcceptsEveryLanguage: false) == "de")
        #expect(AppLanguage.en.chatServerCode(serverAcceptsEveryLanguage: false) == "en")
        #expect(AppLanguage.nl.chatServerCode(serverAcceptsEveryLanguage: false) == nil)
        #expect(AppLanguage.de.chatServerCode(serverAcceptsEveryLanguage: true) == "de")
        #expect(AppLanguage.nl.chatServerCode(serverAcceptsEveryLanguage: true) == "nl")
        #expect(AppLanguage.chatAllLanguagesMinimumServerVersion == "1.46.2")
    }

    @Test(
        "The remembered server version decides; unknown counts as too old",
        arguments: [
            (nil as String?, nil as String?),
            ("1.46.1", nil),
            ("1.46.2", "nl"),
            ("1.47.0", "nl")
        ]
    )
    func chatPolicyReadsKnownServerVersion(version: String?, expected: String?) throws {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let version {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
        }
        #expect(AppLanguage.nl.chatServerCode(defaults: defaults) == expected)
        // German and English never depend on the server version.
        #expect(AppLanguage.de.chatServerCode(defaults: defaults) == "de")
        #expect(AppLanguage.en.chatServerCode(defaults: defaults) == "en")
    }

    // MARK: - Region and formatting

    @Test("regionTag joins the interface language with the device region")
    func regionTag() {
        #expect(AppLanguage.nl.regionTag(region: "BE") == "nl-BE")
        #expect(AppLanguage.de.regionTag(region: "AT") == "de-AT")
        #expect(AppLanguage.en.regionTag(region: "US") == "en-US")
        // A Portuguese phone with the English interface: the country stays.
        #expect(AppLanguage.en.regionTag(region: "PT") == "en-PT")
        #expect(AppLanguage.de.regionTag(region: "de") == "de-DE")
        #expect(AppLanguage.nl.regionTag(region: nil) == "nl")
        #expect(AppLanguage.nl.regionTag(region: "") == "nl")
    }

    @Test("formattingLocale keeps a real language-region pair, else the language's home locale")
    func formattingLocale() {
        #expect(AppLanguage.nl.formattingLocale(region: "BE").identifier == "nl_BE")
        #expect(AppLanguage.de.formattingLocale(region: "AT").identifier == "de_AT")
        #expect(AppLanguage.en.formattingLocale(region: "DE").identifier == "en_DE")
        // Dutch on a German phone: there is no nl_DE, so Dutch formats as nl_NL.
        #expect(AppLanguage.nl.formattingLocale(region: "DE").identifier == "nl_NL")
        #expect(AppLanguage.de.formattingLocale(region: "US").identifier == "de_DE")
        #expect(AppLanguage.en.formattingLocale(region: nil).identifier == "en_US")
        for language in AppLanguage.allCases {
            #expect(AppLanguage.resolve(language.formattingLocale) == language)
        }
    }

    @Test("The DMY date preference renders day first, with month names in the interface language")
    func dayMonthYearLocale() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 17
        components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        let style = try Date.FormatStyle(date: .long, time: .omitted, timeZone: #require(TimeZone(identifier: "UTC")))
        let expectations: [AppLanguage: String] = [.de: "Juni", .en: "June", .nl: "juni"]
        for language in AppLanguage.allCases {
            let text = date.formatted(style.locale(language.dayMonthYearLocale))
            let month = try #require(expectations[language])
            #expect(text.contains(month), "\(language): \(text)")
            let day = try #require(text.range(of: "17")?.lowerBound)
            let monthIndex = try #require(text.range(of: month)?.lowerBound)
            #expect(day < monthIndex, "\(language) must put the day first: \(text)")
        }
        #expect(AppLanguage.$pinned.withValue(.en) { HLDateFormat.dayMonthYear.formattingLocale.identifier } == "en_GB")
        #expect(AppLanguage.$pinned.withValue(.de) { HLDateFormat.dayMonthYear.formattingLocale.identifier } == "de_DE")
        #expect(AppLanguage.$pinned.withValue(.nl) { HLDateFormat.dayMonthYear.formattingLocale.identifier } == "nl_NL")
    }

    // MARK: - Call sites that used to decide on their own

    @Test("Metric-insight invalidation drops one row per interface language")
    func cacheInvalidationCoversEveryLanguage() {
        let keys = MutationKind.measurementChange(kind: .bloodPressure).affectedKeys(profileTimeZone: .gmt)
        for language in AppLanguage.allCases {
            #expect(keys.contains(.metricInsights(kind: .bloodPressure, locale: language.serverCode)))
        }
    }

    @Test("Mid-sentence casing and the screener locale follow the interface language")
    @MainActor
    func formerCallSites() {
        // L10N-MH: the screener sends the interface language with the device
        // region (`regionTag`), so the server can pick the country's crisis set.
        #expect(AppLanguage.$pinned.withValue(.nl) { MentalHealthStore.deviceDisplayLocale() } == AppLanguage.nl.regionTag)
        #expect(AppLanguage.$pinned.withValue(.en) { MentalHealthStore.deviceDisplayLocale() } == AppLanguage.en.regionTag)
        #expect(AppLanguage.nl.regionTag(region: "BE") == "nl-BE")
        #expect(AppLanguage.$pinned.withValue(.de) { HLLearnLinks.appLanguageCode } == "de")
        #expect(AppLanguage.$pinned.withValue(.nl) { HLLearnLinks.appLanguageCode } == "nl")
        // The site has German and English editions; Dutch reads the English one.
        let nlGuide = HLLearnLinks.url(forSlug: HLLearnLinks.guides[0].slug, languageCode: "nl")
        #expect(nlGuide?.absoluteString.contains("/de/") == false)
    }
}
