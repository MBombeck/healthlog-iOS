import Foundation
@testable import HealthLog
import Testing

/// **The Dutch screener wording is the published validated text, not ours.**
///
/// Re-wording a validated instrument changes what it measures. The server
/// carries the published Dutch versions (`src/lib/mental-health/wording/*/nl.ts`:
/// Pfizer's "Dutch for the Netherlands" PHQ-9 and GAD-7, the WHO-5 Dutch
/// version). Since L10N-MH the app bundles that text in
/// `Resources/Questionnaires/questionnaire-wording.nl.json`
/// (``QuestionnaireWordingLockstepTests`` pins it), and
/// ``MentalHealthInstrument/validatedItemLocales`` reads "nl" from its
/// `validated` flags.
///
/// The SCI has no validated Dutch version: the form shows the server's own
/// translation with a note and the switch to the English original, and only
/// a reader who switched sends `englishOriginal`
/// (``MentalHealthWordingFlowTests``).
@Suite("Dutch screener wording (validated text)")
struct MentalHealthDutchWordingTests {
    @Test("PHQ-9, GAD-7 and WHO-5 count as validated in Dutch; the SCI does not")
    func validatedLocales() {
        for instrument in [MentalHealthInstrument.phq9, .gad7, .who5] {
            #expect(instrument.validatedItemLocales.contains("nl"))
            #expect(instrument.hasValidatedItems(locale: "nl_NL"))
            #expect(instrument.hasValidatedItems(locale: "nl-BE"))
        }
        #expect(!MentalHealthInstrument.sci.hasValidatedItems(locale: "nl"))
    }

    @Test("englishOriginal is on the wire when set and absent when nil")
    func englishOriginalWire() throws {
        let shownInEnglish = CreateAssessmentRequest(
            instrument: .sci,
            items: Array(repeating: 2, count: 8),
            locale: "nl",
            englishOriginal: true
        )
        let withFlag = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shownInEnglish)) as? [String: Any]
        )
        #expect(withFlag["englishOriginal"] as? Bool == true)
        #expect(withFlag["locale"] as? String == "nl")

        let validated = CreateAssessmentRequest(instrument: .phq9, items: Array(repeating: 0, count: 9), locale: "nl")
        let withoutFlag = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(validated)) as? [String: Any]
        )
        #expect(withoutFlag["englishOriginal"] == nil)
    }
}
