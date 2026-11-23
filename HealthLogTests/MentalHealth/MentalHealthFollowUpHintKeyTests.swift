import Foundation
@testable import HealthLog
import Testing

/// **The follow-up hint after a screening shows words, not its key.**
///
/// The hint is the one line that points a person with a high score towards
/// professional help. Its key has to be looked up whole; built as an
/// interpolated literal it was looked up as a format key that does not exist,
/// and the screen showed `mentalHealth.followUpHint.phq9`.
@Suite("Mental health follow-up hint resolves in every language")
struct MentalHealthFollowUpHintKeyTests {
    @Test("each instrument's hint key is the plain dotted key")
    func keys() {
        #expect(MentalWellbeingResult.followUpHintKey(.gad7) == "mentalHealth.followUpHint.gad7")
        #expect(MentalWellbeingResult.followUpHintKey(.phq9) == "mentalHealth.followUpHint.phq9")
        #expect(MentalWellbeingResult.followUpHintKey(.sci) == "mentalHealth.followUpHint.sci")
        #expect(MentalWellbeingResult.followUpHintKey(.who5) == "mentalHealth.followUpHint.who5")
    }

    @Test("each hint has text of its own in the shipped catalog", arguments: ["de", "en", "nl"])
    func resolves(language: String) throws {
        // The test host is the app, so its catalog is the one that ships.
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for instrument in MentalHealthInstrument.allCases {
            let key = MentalWellbeingResult.followUpHintKey(instrument)
            let text = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(text != key, "\(instrument) in \(language) shows its key")
            #expect(text != "MISSING", "\(instrument) has no \(language) text")
            #expect(!text.isEmpty, "\(instrument) in \(language) is empty")
        }
    }
}
