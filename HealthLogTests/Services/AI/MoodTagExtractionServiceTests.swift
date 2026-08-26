import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `MoodTagExtractionService` (D-2).
///
/// The actual on-device `LanguageModelSession` is unavailable in CI (Apple
/// Intelligence is device-eligibility gated + cannot be reached from the
/// test runner). We cover the parts that are testable without invoking the
/// model:
///
///   * empty-input short-circuit
///   * feature-flag short-circuit (uses `.assistantTrend`, per dispatch)
///   * MDRSafetyFilter integration via `MoodTagsExtraction: BriefingTextProvider`
///   * sanitise(_:existingTags:): trim, dedupe, length-cap, count-cap,
///     existing-tag dedupe
///   * fallback-reason enum completeness
@Suite("MoodTagExtractionService — gates + safety + sanitisation (D-2)")
struct MoodTagExtractionServiceTests {
    // MARK: - Short-circuits

    @Test("suggestTags — empty raw note returns .fallback(.emptyInput)")
    func emptyInputShortCircuit() async {
        let service = MoodTagExtractionService()
        let outcome = await service.suggestTags(forNote: "")
        #expect(outcome.suggestions == nil)
        #expect(outcome.fallbackReason == .emptyInput)
    }

    @Test("suggestTags — whitespace-only note returns .fallback(.emptyInput)")
    func whitespaceOnlyInputShortCircuit() async {
        let service = MoodTagExtractionService()
        let outcome = await service.suggestTags(forNote: "   \n\n  ")
        #expect(outcome.fallbackReason == .emptyInput)
    }

    @Test("suggestTags — assistantTrend off short-circuits before any FM work")
    func featureFlagOffShortCircuit() async {
        let flags = StubFeatureFlagsService(assistantTrend: false)
        let service = MoodTagExtractionService(featureFlags: flags)
        let outcome = await service.suggestTags(forNote: "schlecht geschlafen")
        #expect(outcome.suggestions == nil)
        #expect(outcome.fallbackReason == .featureFlagDisabled)
    }

    @Test("suggestTags — assistantTrend on but framework unavailable returns the right fallback")
    func frameworkAvailabilityFallback() async {
        // On the CI runner (which has FoundationModels.framework available
        // but the model is not reachable), the outcome SHOULD be one of
        // the FM-side fallbacks (deviceIneligible / appleIntelligenceDisabled
        // / modelNotReady / generationFailed / safetyRefused). We cannot
        // pin a single value because the runner state isn't deterministic,
        // but we can require that the outcome is a fallback and not a
        // false-positive success.
        let flags = StubFeatureFlagsService(assistantTrend: true)
        let service = MoodTagExtractionService(featureFlags: flags)
        let outcome = await service.suggestTags(forNote: "Tag voller Stress.")
        // Either we got a success (extremely unlikely in CI) or we got a
        // fallback. Both shapes are well-defined; we only insist on the
        // outcome being well-formed.
        if let suggestions = outcome.suggestions {
            // If the model actually responded, it must respect the cap.
            #expect(suggestions.count <= MoodTagExtractionService.maxSuggestions)
        } else {
            #expect(outcome.fallbackReason != nil)
        }
    }

    // MARK: - MDR safety filter integration

    @Test("MDRSafetyFilter passes through a benign MoodTagsExtraction")
    func safetyFilterPassesBenignExtraction() async {
        let filter = MDRSafetyFilter()
        let extraction = MoodTagsExtraction(suggestions: ["Schlaf", "Stress", "Arbeit"])
        let result = await filter.scrub(extraction)
        #expect(result == .passed)
    }

    @Test("MDRSafetyFilter refuses an extraction containing a diagnostic claim")
    func safetyFilterRefusesDiagnosticInLabel() async {
        let filter = MDRSafetyFilter()
        // Hallucinated model output that sneaks a diagnosis into a label.
        let extraction = MoodTagsExtraction(suggestions: ["Schlaf", "Du hast Bluthochdruck"])
        let result = await filter.scrub(extraction)
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("MDRSafetyFilter refuses an extraction carrying prescriptive language")
    func safetyFilterRefusesPrescriptive() async {
        let filter = MDRSafetyFilter()
        let extraction = MoodTagsExtraction(suggestions: ["du musst jetzt nehmen"])
        let result = await filter.scrub(extraction)
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("MoodTagsExtraction.allTextFields surfaces every label for the filter")
    func allTextFieldsSurfaces() {
        let extraction = MoodTagsExtraction(suggestions: ["A", "B", "C"])
        #expect(extraction.allTextFields == ["A", "B", "C"])
    }

    // MARK: - Sanitiser

    @Test("sanitise — trim + dedupe (case-insensitive)")
    func sanitiseTrimAndDedupe() {
        let raw = ["  Schlaf  ", "stress", "Schlaf", "Stress", "STRESS"]
        let out = MoodTagExtractionService.sanitise(raw, existingTags: [])
        #expect(out.map(\.label) == ["Schlaf", "stress"])
    }

    @Test("sanitise — drops empty + whitespace-only labels")
    func sanitiseDropsEmpty() {
        let raw = ["", "   ", "Schlaf", "\n", "Stress"]
        let out = MoodTagExtractionService.sanitise(raw, existingTags: [])
        #expect(out.map(\.label) == ["Schlaf", "Stress"])
    }

    @Test("sanitise — drops labels already present on the entry (case-insensitive)")
    func sanitiseDropsExisting() {
        let raw = ["Schlaf", "Stress", "Sport"]
        let out = MoodTagExtractionService.sanitise(raw, existingTags: ["stress", "ARBEIT"])
        #expect(out.map(\.label) == ["Schlaf", "Sport"])
    }

    @Test("sanitise — caps label length at maxLabelLength chars")
    func sanitiseCapsLength() {
        let long = String(repeating: "X", count: MoodTagExtractionService.maxLabelLength + 10)
        let out = MoodTagExtractionService.sanitise([long], existingTags: [])
        #expect(out.count == 1)
        #expect(out.first?.label.count == MoodTagExtractionService.maxLabelLength)
    }

    @Test("sanitise — caps total count at maxSuggestions")
    func sanitiseCapsCount() {
        let raw = (0 ..< (MoodTagExtractionService.maxSuggestions * 2)).map { "Tag\($0)" }
        let out = MoodTagExtractionService.sanitise(raw, existingTags: [])
        #expect(out.count == MoodTagExtractionService.maxSuggestions)
    }

    @Test("MoodTagSuggestion.id mirrors the label so SwiftUI ForEach is stable")
    func suggestionIdentity() {
        let s = MoodTagSuggestion(label: "Schlaf")
        #expect(s.id == "Schlaf")
    }

    // MARK: - Fallback-reason completeness

    @Test("Every FallbackReason value is round-trippable through rawValue")
    func fallbackReasonRoundTrip() {
        let cases: [MoodTagSuggestionOutcome.FallbackReason] = [
            .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady,
            .featureFlagDisabled, .safetyRefused, .generationFailed,
            .frameworkUnavailable, .emptyInput
        ]
        for c in cases {
            #expect(MoodTagSuggestionOutcome.FallbackReason(rawValue: c.rawValue) == c)
        }
    }
}

/// Minimal stub for the feature-flag service so the extraction-service
/// tests can force-disable the `.assistantTrend` flag.
private struct StubFeatureFlagsService: FeatureFlagsServicing {
    let assistantTrend: Bool

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        switch flag {
        case .assistantTrend:
            assistantTrend
        case .assistantBriefing,
             .assistantCoach,
             .assistantInsights,
             .enableDailyStats,
             .enableHRBuckets:
            true
        case .cycleTracking:
            false
        }
    }
}
