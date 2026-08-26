import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `SmartReminderPhraseService`. The actual on-device
/// `LanguageModelSession` is unavailable in CI (Apple Intelligence is
/// device-eligibility gated + cannot be reached from the test runner). We
/// cover the parts that are testable without invoking the model:
///
///   * empty-input short-circuit
///   * feature-flag short-circuit
///   * MDRSafetyFilter integration via `ReminderPhrase: BriefingTextProvider`
///   * fallback-reason enum completeness
///   * `Slot.from(hour:)` bucketing
///   * prompt builder content (locale switch + streak cap)
@Suite("SmartReminderPhraseService — gates + safety integration (D-1)")
@MainActor
struct SmartReminderPhraseServiceTests {
    // MARK: - Short-circuits

    @Test("generate — empty medication name returns .fallback(.emptyInput)")
    func emptyMedicationNameShortCircuits() async {
        let service = SmartReminderPhraseService()
        let ctx = ReminderPhraseContext(medicationName: "", slot: .noon)
        let outcome = await service.generate(context: ctx)
        #expect(outcome.phrase == nil)
        #expect(outcome.fallbackReason == .emptyInput)
    }

    @Test("generate — whitespace-only medication name returns .fallback(.emptyInput)")
    func whitespaceOnlyNameShortCircuits() async {
        let service = SmartReminderPhraseService()
        let ctx = ReminderPhraseContext(medicationName: "   \n  ", slot: .morning)
        let outcome = await service.generate(context: ctx)
        #expect(outcome.fallbackReason == .emptyInput)
    }

    @Test("generate — feature flag off short-circuits before any FM work")
    func featureFlagOffShortCircuits() async {
        let flags = StubReminderFeatureFlagsService(assistantBriefing: false)
        let service = SmartReminderPhraseService(featureFlags: flags)
        let ctx = ReminderPhraseContext(medicationName: "Trulicity", slot: .noon)
        let outcome = await service.generate(context: ctx)
        #expect(outcome.phrase == nil)
        #expect(outcome.fallbackReason == .featureFlagDisabled)
    }

    // MARK: - Safety filter integration

    @Test("MDRSafetyFilter passes through a benign reminder phrase")
    func safetyFilterPassesBenignPhrase() async {
        let filter = MDRSafetyFilter()
        let phrase = ReminderPhrase(
            title: "Zeit für deine Mittagsmedikation",
            body: "Drei Tage in Folge pünktlich — heute auch?"
        )
        let result = await filter.scrub(phrase)
        #expect(result == .passed)
    }

    @Test("MDRSafetyFilter refuses a phrase that contains predictive language")
    func safetyFilterRefusesPredictivePhrase() async {
        let filter = MDRSafetyFilter()
        // A malicious / hallucinated FM output that predicts the body's
        // future state. The filter must catch it.
        let phrase = ReminderPhrase(
            title: "Trulicity Reminder",
            body: "Dein Wert wird steigen, wenn du jetzt nimmst."
        )
        let result = await filter.scrub(phrase)
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("MDRSafetyFilter refuses a phrase that contains prescriptive advice")
    func safetyFilterRefusesPrescriptivePhrase() async {
        let filter = MDRSafetyFilter()
        let phrase = ReminderPhrase(
            title: "Trulicity",
            body: "Du musst jetzt nehmen, sonst eskaliert es."
        )
        let result = await filter.scrub(phrase)
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("ReminderPhrase.allTextFields surfaces title + body for the filter")
    func allTextFieldsSurfacesBoth() {
        let phrase = ReminderPhrase(title: "T", body: "B")
        #expect(phrase.allTextFields == ["T", "B"])
    }

    // MARK: - Fallback-reason completeness

    @Test("Every FallbackReason value is round-trippable through rawValue")
    func fallbackReasonRoundTrip() {
        let cases: [ReminderPhraseOutcome.FallbackReason] = [
            .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady,
            .featureFlagDisabled, .safetyRefused, .generationFailed,
            .frameworkUnavailable, .emptyInput
        ]
        for c in cases {
            #expect(ReminderPhraseOutcome.FallbackReason(rawValue: c.rawValue) == c)
        }
    }

    // MARK: - Slot bucketing

    @Test(
        "Slot.from(hour:) buckets each canonical hour to its slot",
        arguments: [
            (6, ReminderPhraseContext.Slot.morning),
            (10, .morning),
            (12, .noon),
            (13, .noon),
            (15, .afternoon),
            (17, .afternoon),
            (19, .evening),
            (21, .evening),
            (23, .night),
            (3, .night)
        ] as [(Int, ReminderPhraseContext.Slot)]
    )
    func slotFromHourBuckets(hour: Int, expected: ReminderPhraseContext.Slot) {
        #expect(ReminderPhraseContext.Slot.from(hour: hour) == expected)
    }

    // MARK: - Prompt builder

    @Test("Prompt builder uses German slot labels when locale is de")
    func promptBuilderUsesGermanLabels() {
        let ctx = ReminderPhraseContext(
            medicationName: "Trulicity",
            slot: .noon,
            streakDays: 3,
            missedPrevious: false
        )
        let prompt = SmartReminderPhrasePrompt.build(context: ctx, locale: Locale(identifier: "de"))
        #expect(prompt.contains("Medikament: Trulicity"))
        #expect(prompt.contains("Tageszeit: Mittag"))
        #expect(prompt.contains("Streak-Tage (auf 7 begrenzt): 3"))
        #expect(prompt.contains("vorherige Dosis verpasst: nein"))
    }

    @Test("Prompt builder uses English slot labels when locale is en")
    func promptBuilderUsesEnglishLabels() {
        let ctx = ReminderPhraseContext(
            medicationName: "Aspirin",
            slot: .morning,
            streakDays: 0,
            missedPrevious: true
        )
        let prompt = SmartReminderPhrasePrompt.build(context: ctx, locale: Locale(identifier: "en"))
        #expect(prompt.contains("medication: Aspirin"))
        #expect(prompt.contains("slot: morning"))
        #expect(prompt.contains("streakDays (capped at 7): 0"))
        #expect(prompt.contains("missedPrevious: true"))
    }

    @Test("Prompt builder caps streakDays at 7 to limit history exposure")
    func promptBuilderCapsStreakAtSeven() {
        let ctx = ReminderPhraseContext(
            medicationName: "Trulicity",
            slot: .evening,
            streakDays: 42
        )
        let prompt = SmartReminderPhrasePrompt.build(context: ctx, locale: Locale(identifier: "de"))
        #expect(prompt.contains("Streak-Tage (auf 7 begrenzt): 7"))
        #expect(!prompt.contains("42"))
    }

    @Test("Prompt builder floors negative streakDays at 0")
    func promptBuilderFloorsNegativeStreakAtZero() {
        let ctx = ReminderPhraseContext(
            medicationName: "Trulicity",
            slot: .noon,
            streakDays: -5
        )
        let prompt = SmartReminderPhrasePrompt.build(context: ctx, locale: Locale(identifier: "de"))
        #expect(prompt.contains("Streak-Tage (auf 7 begrenzt): 0"))
    }
}

/// Minimal stub for the feature-flag service so the smart-reminder
/// tests can force-disable the assistant briefing flag.
private struct StubReminderFeatureFlagsService: FeatureFlagsServicing {
    let assistantBriefing: Bool

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        switch flag {
        case .assistantBriefing: assistantBriefing
        case .assistantCoach,
             .assistantTrend,
             .assistantInsights,
             .enableDailyStats,
             .enableHRBuckets:
            true
        case .cycleTracking:
            false
        }
    }
}
