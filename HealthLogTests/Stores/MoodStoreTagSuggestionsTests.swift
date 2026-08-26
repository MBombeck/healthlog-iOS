import Foundation
@testable import HealthLog
import Testing

/// D-2 — MoodStore.suggestTags API coverage.
///
/// The store delegates to `MoodTagExtractionService` and gates on whether
/// an extraction service was injected at construction time. The store also
/// reports `supportsTagSuggestions` so views can decide whether to show
/// the "Tags vorschlagen" affordance at all.
///
/// Direct FoundationModels invocation is unreachable from CI (Apple
/// Intelligence model catalogue is empty on the simulator), so we exercise
/// the wiring + the feature-flag short-circuit — the parts that decide
/// whether the model call is even attempted.
@MainActor
@Suite("MoodStore — D-2 tag-suggestion API")
struct MoodStoreTagSuggestionsTests {
    @Test("supportsTagSuggestions — false when no extraction service injected")
    func supportsTagSuggestionsFalseWithoutService() throws {
        let store = try makeStore(tagExtraction: nil)
        #expect(store.supportsTagSuggestions == false)
    }

    @Test("supportsTagSuggestions — true on iOS 26+ runtimes when service injected")
    func supportsTagSuggestionsTrueWithService() throws {
        let store = try makeStore(tagExtraction: MoodTagExtractionService())
        // The test runner (iPhone 17 Pro simulator on Xcode 26.5) is iOS 26+,
        // so the gate returns true. On older runtimes the gate would return
        // false and the assertion would flip — that is by design, the UI
        // hides the affordance on older OS.
        if #available(iOS 26.0, *) {
            #expect(store.supportsTagSuggestions == true)
        } else {
            #expect(store.supportsTagSuggestions == false)
        }
    }

    @Test("suggestTags — nil when no extraction service injected")
    func suggestTagsNilWithoutService() async throws {
        let store = try makeStore(tagExtraction: nil)
        let outcome = await store.suggestTags(forNote: "schlecht geschlafen")
        #expect(outcome == nil)
    }

    @Test("suggestTags — surfaces .emptyInput fallback from service for empty note")
    func suggestTagsEmptyInputPropagates() async throws {
        let store = try makeStore(tagExtraction: MoodTagExtractionService())
        let outcome = await store.suggestTags(forNote: "")
        #expect(outcome?.suggestions == nil)
        #expect(outcome?.fallbackReason == .emptyInput)
    }

    @Test("suggestTags — feature flag off short-circuits before any FM work")
    func suggestTagsFeatureFlagOff() async throws {
        let stubFlags = StubFeatureFlagsService(assistantTrend: false)
        let extraction = MoodTagExtractionService(featureFlags: stubFlags)
        let store = try makeStore(tagExtraction: extraction)
        let outcome = await store.suggestTags(forNote: "Heute war hart.")
        #expect(outcome?.suggestions == nil)
        #expect(outcome?.fallbackReason == .featureFlagDisabled)
    }

    @Test("suggestTags — passes existing tags through so suggestions de-dupe against them")
    func suggestTagsForwardsExistingTags() async throws {
        // We can't easily verify the prompt body without invoking the model.
        // What we CAN verify is that the wiring exists end-to-end and the
        // call resolves without crashing for a well-formed note +
        // existing-tag list. The outcome is whatever the FM availability
        // path decides; this test only insists on "no crash, well-shaped
        // outcome".
        let store = try makeStore(tagExtraction: MoodTagExtractionService())
        let outcome = await store.suggestTags(
            forNote: "Stress bei der Arbeit, aber gut geschlafen.",
            existingTags: ["Arbeit"]
        )
        #expect(outcome != nil)
        // Either we got a success (very rare in CI) or a fallback — both
        // are well-defined shapes.
        if let outcome {
            if let suggestions = outcome.suggestions {
                // If the model did respond, none of the labels should equal
                // an existing tag (sanitiser dedupe).
                let labels = Set(suggestions.map { $0.label.lowercased() })
                #expect(!labels.contains("arbeit"))
            } else {
                #expect(outcome.fallbackReason != nil)
            }
        }
    }

    // MARK: - Helpers

    private func makeStore(tagExtraction: MoodTagExtractionService?) throws -> MoodStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)
        return MoodStore(repo: repo, tagExtraction: tagExtraction)
    }
}

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
