import SwiftUI

/// The two server-derived overview surfaces, grouped so the
/// `InsightsScreen` mounts them with a single line (file-length discipline).
///
/// Renders the WellnessScores ring cards (`vitals-dashboard.tsx` derived tiles
/// + `wellness-scores.tsx`: server-computed scores + age/HRV re-frames —
/// HONEST-ONLY) and, unless hoisted out, the correlations discovery block.
///
/// Pure server reads. Each child self-suppresses to `EmptyView` when its data
/// is absent, so with no data the surface contributes nothing to the scroll column.
///
/// **The RhythmEvents card moved OUT of this group.** It
/// used to be the first child here, but the only call site passed it a
/// hardcoded `rhythmEvents: []` (`InsightsOverviewSlots.swift:236`), so the card
/// self-suppressed forever and the section was dead on the Insights overview
/// while the web showed it. It now lives in its own `InsightsRhythmEventsSlot`
/// fed by the real `RhythmEventsStore` — which also lets it be independently
/// ordered and hidden as the `rhythm-events` overview SECTION (4.5).
struct InsightsServerDerivedOverview: View {
    /// The FULL derived list (`DerivedInsightsStore.metrics`, both `ok` and
    /// `insufficient` arms) the score-ring cards consume, so the confidence gate
    /// can render the calm "not enough data yet" state for a core score.
    let derivedMetricsAll: [DerivedMetricDTO]
    /// Deep-nav from a score-detail contributor row into that metric's
    /// Insights page (reuses the overview's `trendChartMetric` push seam).
    let onSelectMetric: ((MetricKind) -> Void)?
    /// Deep-nav from the Stimmung contributor into the Mood special
    /// Insights page (mood is not a chartable `MetricKind`). `nil` → non-tappable.
    var onSelectMood: (() -> Void)?
    /// The FDR-surviving discovered pairs
    /// (`CorrelationsDiscoveryStore.presentable`). Empty → the discovery block
    /// self-suppresses (surface gated off OR nothing statistically defensible).
    /// Defaulted since the overview hoists the block out (`showsCorrelations:
    /// false`) and therefore hands over no pairs at all.
    var correlations: [DiscoveredCorrelation] = []
    /// Behaviour × outcome pairs assessed (the discovery block's honest footer).
    var correlationsTested: Int = 0
    /// Pairs the person marked as not relevant for them
    /// (`CorrelationsDiscoveryStore.dismissedPairs`), kept reachable behind a
    /// disclosure so the statement stays reversible.
    var correlationsDismissed: [DiscoveredCorrelation] = []
    /// Records the relevance statement (`true` = not relevant for
    /// me). `nil` hides the affordance.
    var onSetCorrelationDismissed: ((DiscoveredCorrelation, Bool) -> Void)?
    /// Statements currently in flight (control disabled).
    var correlationsPendingIDs: Set<String> = []
    /// Set when a statement could not be saved and the optimistic
    /// change was rolled back.
    var correlationsActionError: String?
    /// When false, the score block omits its "Signale des Tages"
    /// section so the host can render it separately (the overview hoists it BELOW
    /// the Einschätzung text). Defaults true so other callers are unaffected.
    var showsSignals: Bool = true
    /// 2026-07-31 (operator) — when false, the "Zusammenhänge in deinen Daten"
    /// block is omitted here so the host can render it separately. The overview
    /// hoists it OUT of the Gesundheitswerte slot and mounts it directly BELOW the
    /// Tagesbriefing (`InsightsCorrelationsSlot`), because sitting inside this
    /// group pinned it right behind the health values. Same hoisting idiom as
    /// ``showsSignals``; defaults true so other callers are unaffected.
    var showsCorrelations: Bool = true

    var body: some View {
        // The wellness-score RING CARDS (Bereitschaft / Schlaf / Belastung
        // + Cardio-Fitness gauge). "Signale des Tages" is hoisted out when
        // `showsSignals` is false (rendered by the host after the Einschätzung).
        InsightsScoreCardsBlock(
            metrics: derivedMetricsAll,
            onSelectMetric: onSelectMetric,
            onSelectMood: onSelectMood,
            showsSignals: showsSignals
        )
        // Mounts BELOW the score cards (descriptive,
        // never causal; self-suppresses when empty / gated off). Hoisted OUT when
        // `showsCorrelations` is false — the overview then renders it right after
        // the Tagesbriefing instead.
        if showsCorrelations {
            InsightsCorrelationsDiscoveryBlock(
                pairs: correlations,
                pairsTested: correlationsTested,
                dismissedPairs: correlationsDismissed,
                onSetDismissed: onSetCorrelationDismissed,
                pendingIDs: correlationsPendingIDs,
                actionError: correlationsActionError
            )
        }
    }
}
