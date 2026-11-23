import Foundation
@testable import HealthLog
import Testing

/// One word per recurring control, in all three languages. The German column
/// is the one the operator reads; "Speichern" and "Hinzufügen" are the two
/// that used to vary from screen to screen ("Sichern" beside "Speichern").
@Suite("Control words")
struct HLControlWordTests {
    private static let expected: [HLControlWord: [String: String]] = [
        .cancel: ["de": "Abbrechen", "en": "Cancel", "nl": "Annuleren"],
        .save: ["de": "Speichern", "en": "Save", "nl": "Opslaan"],
        .done: ["de": "Fertig", "en": "Done", "nl": "Gereed"],
        .close: ["de": "Schließen", "en": "Close", "nl": "Sluiten"],
        .add: ["de": "Hinzufügen", "en": "Add", "nl": "Toevoegen"],
        .delete: ["de": "Löschen", "en": "Delete", "nl": "Verwijderen"],
        .edit: ["de": "Bearbeiten", "en": "Edit", "nl": "Bewerken"],
        .retry: ["de": "Erneut versuchen", "en": "Try again", "nl": "Opnieuw proberen"]
    ]

    @Test("every control word has its expectation here")
    func tableIsComplete() {
        #expect(Set(Self.expected.keys) == Set(HLControlWord.allCases))
    }

    @Test("each word reads the same in every place it is used", arguments: ["de", "en", "nl"])
    func words(language: String) throws {
        // The test host is the app, so its catalog is the one that ships.
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for word in HLControlWord.allCases {
            let localized = bundle.localizedString(forKey: word.catalogKey, value: "MISSING", table: nil)
            #expect(localized == Self.expected[word]?[language], "\(word) in \(language)")
        }
    }
}
