import Foundation
@testable import HealthLog
import Testing

/// **B5 (1.4, #126 P2 v1.40.2) — the Coach's reach names what lies
/// beyond it.** The server treats the chosen window as a real limit and the
/// Coach answers `outside_reach` for older data by saying it lies beyond the
/// limit, never that it is missing (`system-addendum.ts`, v1.43.10). The one
/// line under the picker says the same: older readings stay, just out of reach.
@Suite("B5 — Coach reach sentence for outside_reach")
struct CoachReachSentenceTests {
    @Test("the reach card's line says older readings stay and are only out of reach")
    func reachSentence() throws {
        let german = "Der Coach nutzt in jeder Antwort nur Daten aus diesem Zeitraum. "
            + "Ältere Werte bleiben gespeichert, sie liegen nur außerhalb seiner Reichweite."
        let english = "The Coach only uses data from this period, in every answer. "
            + "Older readings stay saved, they are just out of its reach."
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["settings.coach.window.description"])
        #expect(ParityCatalog.value(entry, language: "de") == german)
        #expect(ParityCatalog.value(entry, language: "en") == english)
    }

    @Test("the picker still offers 7 days, 30 days, 90 days, 12 months and all")
    func pickerChoices() {
        #expect(CoachDefaultWindow.allCases == [.last7days, .last30days, .last90days, .lastYear, .allTime])
    }
}
