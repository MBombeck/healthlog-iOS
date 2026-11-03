import Foundation
@testable import HealthLog
import Testing

/// **B5 (1.4) — „LÖSCHEN“ with its umlaut, „LOESCHEN“ still accepted.**
@Suite("B5 — delete confirmation word")
struct DeleteConfirmationPhraseTests {
    @Test("German shows LÖSCHEN, English keeps DELETE")
    func catalogWord() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["DELETE"])
        #expect(ParityCatalog.value(entry, language: "de") == "LÖSCHEN")
        #expect(ParityCatalog.value(entry, language: "en") == "DELETE")
    }

    @Test("LÖSCHEN and LOESCHEN both confirm; anything else does not")
    func germanSpellings() {
        #expect(DeleteConfirmationPhrase.matches("LÖSCHEN", required: "LÖSCHEN"))
        #expect(DeleteConfirmationPhrase.matches("LOESCHEN", required: "LÖSCHEN"))
        #expect(!DeleteConfirmationPhrase.matches("LOSCHEN", required: "LÖSCHEN"))
        #expect(!DeleteConfirmationPhrase.matches("löschen", required: "LÖSCHEN"))
        #expect(!DeleteConfirmationPhrase.matches("loeschen", required: "LÖSCHEN"))
        #expect(!DeleteConfirmationPhrase.matches("LÖSCHEN ", required: "LÖSCHEN"))
        #expect(!DeleteConfirmationPhrase.matches("", required: "LÖSCHEN"))
    }

    @Test("English is unchanged: exactly DELETE")
    func englishUnchanged() {
        #expect(DeleteConfirmationPhrase.matches("DELETE", required: "DELETE"))
        #expect(!DeleteConfirmationPhrase.matches("delete", required: "DELETE"))
        #expect(!DeleteConfirmationPhrase.matches("DELETEE", required: "DELETE"))
    }
}
