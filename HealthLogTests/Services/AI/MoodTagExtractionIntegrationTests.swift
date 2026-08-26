import Foundation
@testable import HealthLog
import Testing

/// D-2 integration coverage — the full pipeline from a free-text note
/// through `MoodStore.suggestTags(...)` → `MoodTagExtractionService` →
/// `MDRSafetyFilter` → sanitiser, simulated end-to-end with stubbed model
/// output via the service's own `sanitise(_:existingTags:)` helper.
///
/// We don't invoke `LanguageModelSession` itself in CI (the simulator's
/// model catalogue is empty), so we exercise the deterministic parts of
/// the pipeline: a hypothetical model response is fed through the sanitiser
/// + filter, and the resulting suggestions are accepted into a mood entry
/// via the same code path the UI would take.
@MainActor
@Suite("MoodTagExtraction — end-to-end pipeline (D-2)")
struct MoodTagExtractionIntegrationTests {
    @Test("end-to-end — note → sanitise → safety → accept → MoodEntry.tags persisted")
    func endToEndHappyPath() async throws {
        // 1. Hypothetical model output (what FoundationModels would return
        //    on a real device for "schlecht geschlafen, gestresst von
        //    Arbeit, Kopfweh").
        let rawModelOutput = ["Schlaf", "Stress", "Arbeit", "Kopfweh", "Stress"]
        let existingTags: [String] = []

        // 2. Sanitiser path.
        let suggestions = MoodTagExtractionService.sanitise(rawModelOutput, existingTags: existingTags)
        #expect(suggestions.map(\.label) == ["Schlaf", "Stress", "Arbeit", "Kopfweh"])
        #expect(suggestions.count <= MoodTagExtractionService.maxSuggestions)

        // 3. Safety pass — the extraction shape must survive the filter.
        let extraction = MoodTagsExtraction(suggestions: suggestions.map(\.label))
        let filter = MDRSafetyFilter()
        let scrub = await filter.scrub(extraction)
        #expect(scrub == .passed)

        // 4. User-accept simulation: take all 4 suggestions into rawTags.
        var rawTags: [String] = []
        for suggestion in suggestions {
            rawTags.append(suggestion.label)
        }
        #expect(rawTags == ["Schlaf", "Stress", "Arbeit", "Kopfweh"])

        // 5. Persist via MoodEntry — verifies `note` + `tags` are separate
        //    fields (no `note:..."` hack) and `note` survives encoding.
        let entry = MoodEntry(
            id: "integration-1",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            score: 2,
            tags: rawTags,
            note: "Schlecht geschlafen, gestresst von der Arbeit, Kopfweh."
        )
        #expect(entry.tags == ["Schlaf", "Stress", "Arbeit", "Kopfweh"])
        #expect(entry.note == "Schlecht geschlafen, gestresst von der Arbeit, Kopfweh.")

        // 6. Codable round-trip — ensures the suggested-and-accepted tags
        //    survive the wire format unchanged.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MoodEntry.self, from: data)
        #expect(decoded.tags == entry.tags)
        #expect(decoded.note == entry.note)
        #expect(decoded.tags.allSatisfy { !$0.hasPrefix("note:") })
    }

    @Test("end-to-end — safety filter blocks injected diagnostic suggestion before accept")
    func endToEndSafetyBlocks() async {
        // Hallucinated model output sneaking a diagnostic claim into the
        // labels. The filter is the belt-and-braces — even if the prompt
        // discipline failed, the user must not see the bad label.
        let rawModelOutput = ["Schlaf", "Stress", "Du hast Bluthochdruck"]
        let suggestions = MoodTagExtractionService.sanitise(rawModelOutput, existingTags: [])

        // Sanitiser doesn't drop diagnostic claims — that's the filter's job.
        // It only enforces shape (length, dedupe, count). So all three pass
        // through here.
        #expect(suggestions.count == 3)

        let extraction = MoodTagsExtraction(suggestions: suggestions.map(\.label))
        let filter = MDRSafetyFilter()
        let result = await filter.scrub(extraction)
        // Filter REFUSES — the caller (service) maps this to .safetyRefused
        // and the UI never sees the suggestions at all.
        #expect(result == .refused(reason: .mdrPatternMatch))
    }

    @Test("end-to-end — existing tags dedupe across the full pipeline")
    func endToEndExistingTagDedupe() {
        // User already has "Arbeit" on the entry. The model proposes
        // "Arbeit" + 3 new tags. Sanitiser drops the duplicate; what
        // reaches the user is only the new tags.
        let rawModelOutput = ["arbeit", "Schlaf", "Stress", "Sport"]
        let existing = ["Arbeit"]
        let suggestions = MoodTagExtractionService.sanitise(rawModelOutput, existingTags: existing)
        #expect(suggestions.map(\.label) == ["Schlaf", "Stress", "Sport"])
    }
}
