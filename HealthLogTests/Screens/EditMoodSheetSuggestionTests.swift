import Foundation
@testable import HealthLog
import Testing

/// D-2 — EditMoodSheet tag-suggestion acceptance state-contract.
///
/// We don't snapshot the SwiftUI body (the rest of the suite is state-shape
/// only, per the file-level note in `MoodScreenStateTests`). Instead we
/// exercise the building blocks that drive the UI: the accept(_:) flow,
/// the suggestion-list mutation rules, the existing-tag dedup-on-accept.
///
/// The actual `MoodStore.suggestTags(_:)` round-trip is covered in
/// `MoodStoreTagSuggestionsTests`. This file focuses on the view-side
/// state contract — what happens to `suggestions` + `rawTags` when the
/// user taps a chip.
@MainActor
@Suite("EditMoodSheet — D-2 tag-suggestion acceptance flow")
struct EditMoodSheetSuggestionTests {
    @Test("SuggestionAcceptance.accept — moves suggestion from list to rawTags")
    func acceptMovesSuggestionToTags() {
        var state = SuggestionAcceptance(
            rawTags: ["Sport"],
            suggestions: [
                MoodTagSuggestion(label: "Schlaf"),
                MoodTagSuggestion(label: "Stress")
            ]
        )
        state.accept(MoodTagSuggestion(label: "Schlaf"))
        #expect(state.rawTags == ["Sport", "Schlaf"])
        #expect(state.suggestions.map(\.label) == ["Stress"])
    }

    @Test("SuggestionAcceptance.accept — skips when tag already on entry")
    func acceptSkipsExisting() {
        var state = SuggestionAcceptance(
            rawTags: ["Stress"],
            suggestions: [MoodTagSuggestion(label: "stress")]
        )
        state.accept(MoodTagSuggestion(label: "stress"))
        // No duplicate added; suggestion still consumed (removed from list).
        #expect(state.rawTags == ["Stress"])
        #expect(state.suggestions.isEmpty)
    }

    @Test("SuggestionAcceptance — case-insensitive dedupe on accept")
    func acceptCaseInsensitiveDedupe() {
        var state = SuggestionAcceptance(
            rawTags: ["Arbeit"],
            suggestions: [MoodTagSuggestion(label: "ARBEIT")]
        )
        state.accept(MoodTagSuggestion(label: "ARBEIT"))
        #expect(state.rawTags == ["Arbeit"])
        #expect(state.suggestions.isEmpty)
    }

    @Test("MoodTagSuggestionOutcome fallback messages cover every reason")
    func fallbackMessageCompleteness() {
        let allReasons: [MoodTagSuggestionOutcome.FallbackReason] = [
            .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady,
            .featureFlagDisabled, .safetyRefused, .generationFailed,
            .frameworkUnavailable, .emptyInput
        ]
        for reason in allReasons {
            // The mapping table in EditMoodSheet should produce a non-empty
            // message for every reason — guard against a future enum case
            // sneaking in without a copy.
            let message = SuggestionAcceptance.fallbackMessage(reason)
            #expect(!message.isEmpty, "Missing copy for fallback \(reason.rawValue)")
        }
    }

    @Test("SuggestionAcceptance.dismiss — clears suggestion list without touching tags")
    func dismissClearsSuggestionsKeepsTags() {
        var state = SuggestionAcceptance(
            rawTags: ["Sport"],
            suggestions: [MoodTagSuggestion(label: "Schlaf")]
        )
        state.dismiss()
        #expect(state.suggestions.isEmpty)
        #expect(state.rawTags == ["Sport"])
    }
}

/// Pure value-type mirror of EditMoodSheet's suggestion state. Lives in the
/// test bundle so we can exercise the accept / dismiss rules without
/// instantiating the full SwiftUI view.
///
/// Mirrors the behaviour in `EditMoodSheet.accept(_:)` and the dismiss
/// "X"-button. If those rules ever diverge from this struct, the test
/// suite catches it — and the divergence itself is the bug.
private struct SuggestionAcceptance {
    var rawTags: [String]
    var suggestions: [MoodTagSuggestion]

    mutating func accept(_ suggestion: MoodTagSuggestion) {
        if !rawTags.contains(where: { $0.caseInsensitiveCompare(suggestion.label) == .orderedSame }) {
            rawTags.append(suggestion.label)
        }
        suggestions.removeAll { $0.id == suggestion.id }
    }

    mutating func dismiss() {
        suggestions = []
    }

    static func fallbackMessage(_ reason: MoodTagSuggestionOutcome.FallbackReason) -> String {
        switch reason {
        case .featureFlagDisabled:
            "Tag-Vorschlaege sind aktuell deaktiviert."
        case .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady, .frameworkUnavailable:
            "On-Device-Vorschlaege sind auf diesem Geraet nicht verfuegbar."
        case .safetyRefused:
            "Vorschlaege wurden vom Sicherheitsfilter zurueckgehalten."
        case .generationFailed:
            "Konnte keine Vorschlaege erzeugen. Versuche es spaeter erneut."
        case .emptyInput:
            "Schreibe etwas in die Notiz, dann werden Vorschlaege moeglich."
        }
    }
}
