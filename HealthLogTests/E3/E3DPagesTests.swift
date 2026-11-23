import Foundation
@testable import HealthLog
import Testing

/// Labs, documents, diary, mood, cycle and the questionnaires on the shared
/// action forms: the questionnaire steps through its questions with the
/// stepper of the app, and every choice wears the mark of its kind.
@MainActor
@Suite("E3 package D: action forms on the record pages")
struct E3DPagesTests {
    // MARK: - Questionnaire stepper

    @Test("Forward opens only over an answered question with a later step")
    func questionnaireForward() {
        // Nine scored questions plus the optional follow-up.
        let answers = [2, 1, -1, -1, -1, -1, -1, -1, -1]
        #expect(MentalWellbeingForm.canAdvance(step: 0, answers: answers, totalSteps: 10))
        #expect(MentalWellbeingForm.canAdvance(step: 1, answers: answers, totalSteps: 10))
        #expect(!MentalWellbeingForm.canAdvance(step: 2, answers: answers, totalSteps: 10))
    }

    @Test("The last step has no forward, answered or not")
    func questionnaireLastStep() {
        let answers = Array(repeating: 1, count: 9)
        #expect(MentalWellbeingForm.canAdvance(step: 8, answers: answers, totalSteps: 10))
        #expect(!MentalWellbeingForm.canAdvance(step: 9, answers: answers, totalSteps: 10))
        #expect(!MentalWellbeingForm.canAdvance(step: 8, answers: answers, totalSteps: 9))
    }

    @Test("A step outside the answers never opens forward")
    func questionnaireOutOfRange() {
        #expect(!MentalWellbeingForm.canAdvance(step: 0, answers: [], totalSteps: 3))
    }

    // MARK: - Choice marks

    @Test("Selecting documents shows the circle of a multiple choice")
    func documentSelectionMark() {
        #expect(HLChoiceRow.symbol(mode: .multiple, isSelected: true) == "checkmark.circle.fill")
        #expect(HLChoiceRow.symbol(mode: .multiple, isSelected: false) == "circle")
        #expect(HLChoiceRow.edge(for: .multiple) == .leading)
    }

    @Test("A questionnaire answer is a single choice with the check mark trailing")
    func questionnaireAnswerMark() {
        #expect(HLChoiceRow.symbol(mode: .single, isSelected: true) == "checkmark")
        #expect(HLChoiceRow.symbol(mode: .single, isSelected: false) == nil)
        #expect(HLChoiceRow.edge(for: .single) == .trailing)
    }
}
