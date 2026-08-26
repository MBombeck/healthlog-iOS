import SwiftUI

/// **W-COACH-CADENCE (#30) — proactive coach cadence-suggestion cards.**
///
/// Rendered on the Insights overview, near the coach surface, when a coach chat
/// turn surfaced an inline cadence suggestion (routed here via
/// ``CoachConversationStore`` → ``CoachCadenceSuggestionsStore/present(_:)``) so
/// the same suggestion is discoverable outside an open chat. Each suggestion is a
/// calm `HLCard` (the same quiet coach/insight chrome as ``CoachReengageCard``,
/// NOT the colourful `AskCoachHeroCard` hero — the saturated purple moment stays
/// reserved for the consented hero) with the cadence label and two actions:
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
            VStack(spacing: HLSpace.sm) {
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

/// One proactive cadence-suggestion card. Quiet, monochrome coach chrome; the
/// coach glyph is the only brand cue (no saturated fill). Accept + Dismiss use
/// the canonical `HLButton` (44pt-floored) so the hit targets and styling match
/// every other CTA.
private struct CoachCadenceSuggestionCard: View {
    let suggestion: CoachCadenceSuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(
                    String(localized: "coach.cadenceSuggestion.title"),
                    systemImage: "sparkles"
                )
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .accessibilityIdentifier("coach.cadenceSuggestion.kicker")

                // The cadence label (resolved i18n key, generic fallback).
                Text(cadenceLabel)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: HLSpace.sm) {
                    HLButton(
                        String(localized: "coach.cadenceSuggestion.accept"),
                        variant: .restrained,
                        size: .compact,
                        action: onAccept
                    )
                    .accessibilityIdentifier("coach.cadenceSuggestion.accept")
                    HLButton(
                        String(localized: "coach.cadenceSuggestion.dismiss"),
                        variant: .ghost,
                        size: .compact,
                        action: onDismiss
                    )
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
