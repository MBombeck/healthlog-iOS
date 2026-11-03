import SwiftUI

/// **W-COACH-CADENCE (#30) — proactive coach cadence-suggestion cards.**
///
/// Rendered on the Insights overview, near the coach surface, when a coach chat
/// turn surfaced an inline cadence suggestion (routed here via
/// ``CoachConversationStore`` → ``CoachCadenceSuggestionsStore/present(_:)``) so
/// the same suggestion is discoverable outside an open chat. Under one section
/// title, each suggestion is a calm `HLCard` (the same quiet chrome as
/// ``CoachReengageCard``, no saturated fill) with the cadence label and two
/// actions:
///
/// - **Accept** → the server creates the corresponding measurement reminder
///   (origin COACH) and the native reminders list re-lists; a calm note points at
///   where it now lives.
/// - **Dismiss** → the card disappears and won't nag again.
///
/// **Self-suppressing.** The whole section collapses to nothing when the store
/// holds no suggestions (no empty placeholder). The store owns the gating
/// (opt-in toggle + coach module + online) and the optimistic accept/dismiss.
struct CoachCadenceSuggestionsSection: View {
    let store: CoachCadenceSuggestionsStore

    var body: some View {
        // Self-suppress: nothing to offer ⇒ render nothing (no empty card).
        if !store.suggestions.isEmpty {
            // 1.4 B4 — the overview's heading form: a section title above its
            // cards (`InsightsSectionHeader`, like "Vitalwerte"), not a caption
            // kicker with a sparkle inside each card.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("coach.cadenceSuggestion.title")
                ForEach(store.suggestions) { suggestion in
                    CoachCadenceSuggestionCard(
                        suggestion: suggestion,
                        onAccept: { Task { await store.accept(suggestion) } },
                        onDismiss: { Task { await store.dismiss(suggestion) } }
                    )
                }
            }
            .accessibilityIdentifier("InsightsScreen.coachCadenceSuggestions")
        }
    }
}

/// One proactive cadence-suggestion card. Quiet, monochrome coach chrome under
/// the section's title. Accept + Dismiss are the tile-action pair (44 pt) the
/// medication and Vorsorge cards use.
private struct CoachCadenceSuggestionCard: View {
    let suggestion: CoachCadenceSuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // The cadence label (resolved i18n key, generic fallback).
                Text(cadenceLabel)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // 1.4 B4 — the in-card action pair of the medication and
                // Vorsorge tiles (`HLTileActionButton`), not a retired
                // `.restrained` button beside a `.ghost` one.
                HStack(spacing: HLSpace.sm) {
                    HLTileActionButton("coach.cadenceSuggestion.accept", action: onAccept)
                        .accessibilityIdentifier("coach.cadenceSuggestion.accept")
                    HLTileActionButton("coach.cadenceSuggestion.dismiss", action: onDismiss)
                        .accessibilityIdentifier("coach.cadenceSuggestion.dismiss")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.cadenceSuggestion.card")
    }

    /// Resolve the server-supplied i18n key. `String(localized:)` returns the key
    /// verbatim when the catalogue has no entry, so an unknown future cadence
    /// falls back to a generic, still-readable label.
    private var cadenceLabel: String {
        let resolved = String(localized: String.LocalizationValue(suggestion.label))
        return resolved == suggestion.label
            ? String(localized: "coach.cadenceSuggestion.generic")
            : resolved
    }
}

/// Preview-only no-network API client — the section never fetches in a preview
/// (the store is seeded directly), so every leg is an unreachable stub.
private struct PreviewNoNetworkAPIClient: APIClientProtocol {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.offline
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.offline
    }
}

#Preview("CoachCadenceSuggestionsSection") {
    let store = CoachCadenceSuggestionsStore(
        repo: CoachCadenceSuggestionsRepository(api: PreviewNoNetworkAPIClient())
    )
    store.seedForTesting([
        CoachCadenceSuggestion(
            id: "s1",
            cadenceId: "weight_daily_morning",
            measurementType: "WEIGHT",
            label: "coach.reminderSuggestion.cadence.weightDaily"
        )
    ])
    return ScrollView {
        CoachCadenceSuggestionsSection(store: store)
            .padding(HLSpace.lg)
    }
    .background(HLSurface.primary)
}
