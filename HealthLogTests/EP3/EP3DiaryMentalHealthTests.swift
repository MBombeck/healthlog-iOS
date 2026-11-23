import Foundation
@testable import HealthLog
import Testing

/// Mental wellbeing in the app's forms: a check-in of the history as a
/// history row (date, score, band as status, one side line), the band of
/// the result as a whole catalogue key, and the instrument's name as the
/// page title while the check-in runs.
@Suite("Seelisches Wohlbefinden in Zeilen aus einem Guss")
struct EP3DiaryMentalHealthTests {
    private static func assessment(
        flagged: Bool = false,
        wording: AssessmentWording? = nil
    ) -> MentalHealthAssessmentDTO {
        MentalHealthAssessmentDTO(
            id: "a1",
            instrument: .phq9,
            locale: "de",
            version: "1",
            totalScore: 12,
            severityBand: "moderate",
            item9Flagged: flagged,
            crisisShownAt: nil,
            takenAt: "2026-11-10T08:00:00Z",
            createdAt: "2026-11-10T08:00:00Z",
            wording: wording
        )
    }

    @Test func historyRowShowsScoreAndBandWithoutASideLine() {
        let content = MentalHealthHistoryRowContent(row: Self.assessment())
        #expect(content.date == MentalHealthDateFormat.short("2026-11-10T08:00:00Z"))
        #expect(content.score == 12)
        #expect(content.band == MentalWellbeingResult.bandLabel(instrument: .phq9, band: "moderate"))
        #expect(content.detail == nil)
    }

    @Test func supportShownAndUnvalidatedWordingShareOneSideLine() {
        let content = MentalHealthHistoryRowContent(
            row: Self.assessment(flagged: true, wording: .unvalidatedTranslation)
        )
        let expected = [
            String(localized: "mentalHealth.history.flaggedBadge"),
            String(localized: "mentalHealth.wording.historyUnvalidated")
        ].joined(separator: ", ")
        #expect(content.detail == expected)
    }

    @Test func validatedWordingAddsNothing() {
        let content = MentalHealthHistoryRowContent(row: Self.assessment(wording: .validated))
        #expect(content.detail == nil)
    }

    @Test func bandIsLookedUpAsAWholeKey() {
        let label = MentalWellbeingResult.bandLabel(instrument: .phq9, band: "moderate")
        #expect(label == String(localized: "mentalHealth.band.PHQ9.moderate"))
        #expect(!label.contains("%"))
    }

    @Test func pageTitleKeyNamesTheRunningInstrument() {
        for instrument in MentalHealthInstrument.allCases {
            #expect(
                MentalWellbeingScreen.instrumentTitleKey(instrument)
                    == "mentalHealth.instrument.\(instrument.keySegment)"
            )
        }
    }
}
