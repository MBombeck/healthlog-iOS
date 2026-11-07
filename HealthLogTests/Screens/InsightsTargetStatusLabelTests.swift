import Foundation
@testable import HealthLog
import Testing

/// **1.5 L10N-FINAL** — the server emits a target's `classification.category`
/// as a canonical English token. The status chip shows it in the reader's
/// language through `targets.status.*`, like the web, and never a raw key.
@Suite("target classification chip in the reader's language")
struct InsightsTargetStatusLabelTests {
    /// The suite runs German; the 1.5 language run repeats it in Dutch.
    @Test("server tokens read in the interface language (German suite, Dutch language run)")
    func interfaceLanguageLabels() {
        let language = AppLanguage.current
        #expect(InsightsTargetStatusLabel.label(for: "Overweight")
            == language.pick(de: "Übergewicht", en: "Overweight", nl: "Overgewicht"))
        #expect(InsightsTargetStatusLabel.label(for: "Hypertension Grade 1")
            == language.pick(de: "Hypertonie Grad 1", en: "Hypertension Grade 1", nl: "Hypertensie graad 1"))
        #expect(InsightsTargetStatusLabel.label(for: "Optimal") == language.pick(de: "Optimal", en: "Optimal", nl: "Optimaal"))
    }

    @Test("an unknown token stays as the server sent it")
    func unknownTokenPassesThrough() {
        #expect(InsightsTargetStatusLabel.label(for: "Brand new category") == "Brand new category")
        #expect(InsightsTargetStatusLabel.label(for: "").isEmpty)
    }

    @Test("every token has text in every listed language, never its key", arguments: CatalogLanguages.listed)
    @available(iOS 18.4, *)
    func everyTokenTranslated(language: String) {
        for (token, resource) in InsightsTargetStatusLabel.keys {
            let resolved = Bundle.main.localizedString(
                forKey: resource.key,
                value: nil,
                table: nil,
                localizations: [Locale.Language(identifier: language)]
            )
            #expect(resolved != resource.key && !resolved.isEmpty, "\(language): \(token)")
        }
    }

    @Test("Dutch reads Dutch")
    @available(iOS 18.4, *)
    func dutchLabels() {
        let resolved = Bundle.main.localizedString(
            forKey: "targets.status.optimal",
            value: nil,
            table: nil,
            localizations: [Locale.Language(identifier: "nl")]
        )
        #expect(resolved == "Optimaal")
        #expect(InsightsTargetStatusLabel.keys.count == 42)
    }
}
