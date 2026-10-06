import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `MedicationExtractionService`. The actual on-device
/// `LanguageModelSession` is unavailable in CI (Apple Intelligence is
/// device-eligibility gated + cannot be reached from the test runner). We
/// cover the parts that are testable without invoking the model:
///
///   * empty-input short-circuit
///   * feature-flag short-circuit
///   * MDRSafetyFilter integration via `MedicationDraft: BriefingTextProvider`
///   * fallback-reason enum completeness
@Suite("MedicationExtractionService — gates + safety integration (T-6)")
@MainActor
struct MedicationExtractionServiceTests {
    // MARK: - Short-circuits

    @Test("extract — empty raw text returns .fallback(.emptyInput)")
    func emptyInputShortCircuit() async {
        let service = MedicationExtractionService()
        let outcome = await service.extract(from: "")
        #expect(outcome.draft == nil)
        #expect(outcome.fallbackReason == .emptyInput)
    }

    @Test("extract — whitespace-only raw text returns .fallback(.emptyInput)")
    func whitespaceOnlyInputShortCircuit() async {
        let service = MedicationExtractionService()
        let outcome = await service.extract(from: "   \n\n  ")
        #expect(outcome.fallbackReason == .emptyInput)
    }

    @Test("extract — medicationExtract disallows on-device → short-circuits before any FM work")
    func featureFlagOffShortCircuit() async {
        let flags = AICaps.reader([.medicationExtract: AICaps.operatorDisabled])
        let service = MedicationExtractionService(aiCapabilities: flags)
        let outcome = await service.extract(from: "Metformin 500 mg")
        #expect(outcome.draft == nil)
        #expect(outcome.fallbackReason == .capabilityNotAllowed)
    }

    // MARK: - Safety filter integration

    @Test("MDRSafetyFilter passes through a benign MedicationDraft")
    func safetyFilterPassesBenignDraft() async {
        let filter = MDRSafetyFilter()
        let draft = MedicationDraft(
            name: "Metformin Hexal",
            doseStrength: "500 mg",
            doseForm: "Filmtablette",
            manufacturerHint: "Hexal AG",
            source: .foundationModels
        )
        let result = await filter.scrub(draft)
        #expect(result == .passed)
    }

    @Test("MDRSafetyFilter refuses a draft whose name contains a diagnostic claim")
    func safetyFilterRefusesDiagnosticInName() async {
        let filter = MDRSafetyFilter()
        // A malicious / hallucinated FM output that injects "Du leidest an Diabetes"
        // into the name field. The filter must catch it.
        let draft = MedicationDraft(
            name: "Du leidest an Diabetes",
            doseStrength: "500 mg",
            source: .foundationModels
        )
        let result = await filter.scrub(draft)
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("MDRSafetyFilter refuses a draft whose doseForm carries prescriptive advice")
    func safetyFilterRefusesPrescriptiveInDoseForm() async {
        let filter = MDRSafetyFilter()
        let draft = MedicationDraft(
            name: "Ozempic",
            doseStrength: "0,5 mg",
            doseForm: "du musst jetzt nehmen", // malicious injection
            source: .foundationModels
        )
        let result = await filter.scrub(draft)
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("MedicationDraft.allTextFields surfaces every populated string for the filter")
    func allTextFieldsSurfacesEveryString() {
        let draft = MedicationDraft(
            name: "A",
            doseStrength: "B",
            doseForm: "C",
            manufacturerHint: "D",
            source: .foundationModels
        )
        #expect(draft.allTextFields == ["A", "B", "C", "D"])
    }

    @Test("MedicationDraft.allTextFields substitutes empty string for nil optionals")
    func allTextFieldsSubstitutesEmptyForNil() {
        let draft = MedicationDraft(name: "Aspirin", source: .heuristic)
        #expect(draft.allTextFields == ["Aspirin", "", "", ""])
    }

    // MARK: - Fallback-reason completeness

    @Test("Every FallbackReason value is round-trippable through rawValue")
    func fallbackReasonRoundTrip() {
        let cases: [MedicationExtractionOutcome.FallbackReason] = [
            .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady,
            .capabilityNotAllowed, .safetyRefused, .generationFailed,
            .frameworkUnavailable, .emptyInput
        ]
        for c in cases {
            #expect(MedicationExtractionOutcome.FallbackReason(rawValue: c.rawValue) == c)
        }
    }
}
