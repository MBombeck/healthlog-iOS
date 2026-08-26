import SwiftUI

/// **v0.15.7 W-RHYTHM-FRONTDOOR — Home front door to the device-health-
/// notifications (ECG/AFib rhythm-events) card.**
///
/// The ECG / AFib / irregular-rhythm timeline already has a dedicated, regulator-
/// aware surface — `InsightsRhythmEventsCard` on the Insights overview — but it
/// is only reachable by scrolling into the Insights tab. This Home tile gives it
/// a discoverable front door: when the user's wearable has flagged events, a
/// calm card on the dashboard summarises "your watch sent N notifications" and
/// taps straight through to the Insights overview that hosts the full card.
///
/// **Only when there ARE events (mirror of `VorsorgeTile`).** The card itself
/// self-suppresses on empty; this tile does the same one layer up — the host
/// (`DashboardScreen`) gates placement on `RhythmEventsTileModel.summary(...)`
/// being non-nil, so it is NEVER a dead/empty slab (per `DashboardEmptyTilePolicy`).
///
/// **Non-diagnostic doctrine preserved.** The tile shows ONLY a count + the
/// neutral "your watch sent these on its own" framing — it never re-states a
/// verdict, never implies HealthLog detected anything. The verbatim disclaimer
/// + per-event verdicts live on the destination card, unchanged. The tile is a
/// pure navigation affordance, not a second rendering of the medical content.
struct RhythmEventsTile: View {
    @Environment(AppRouter.self) private var router

    /// The non-empty summary resolved ONCE by the host
    /// (`DashboardScreen.rhythmEventsSummary`) via the pure
    /// `RhythmEventsTileModel.summary` selector and threaded in, so the
    /// placement gate and the rendered row share one truth.
    let summary: RhythmEventsTileModel.Summary

    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                Text("dashboard.rhythmEvents.tile.title")
                    .font(.hlTitle3)
                    .foregroundStyle(HLText.primary)
                Text(summary.subtitle)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { router.requestInsightsOverview() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("dashboard.rhythmEvents.tile")
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            Text("dashboard.rhythmEvents.tile.eyebrow")
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// Pure selection + summary mapping for the Home rhythm-events front-door tile —
/// split out of the view so the gate decision is unit-testable without a SwiftUI
/// host (mirrors `VorsorgeNextDue`).
///
/// **Self-suppress doctrine.** `summary(for:)` returns `nil` on an empty event
/// list, which is the signal the host omits the tile entirely (no dead/empty
/// slab). Non-nil → the tile renders with a localized count subtitle.
enum RhythmEventsTileModel {
    /// The render payload for the front-door tile: the event count + the derived
    /// localized subtitle line. Only constructed when there is at least one event.
    struct Summary: Equatable {
        let count: Int
        let subtitle: String
    }

    /// Build the tile summary for the current rhythm-event rows, or `nil` when
    /// there are none (→ the host self-suppresses the tile). The subtitle is a
    /// neutral, non-diagnostic count ("Your watch sent N notification(s).") — the
    /// verdicts + disclaimer stay on the destination card.
    static func summary(for events: [RhythmEventsDTO.Event]) -> Summary? {
        guard !events.isEmpty else { return nil }
        // Plural-aware (`%lld`-keyed `plural` variations in the catalog) — pass the
        // count through `String(localized:)` interpolation so the right `one` /
        // `other` form resolves per language.
        let subtitle = String(localized: "dashboard.rhythmEvents.tile.subtitle \(events.count)")
        return Summary(count: events.count, subtitle: subtitle)
    }
}
