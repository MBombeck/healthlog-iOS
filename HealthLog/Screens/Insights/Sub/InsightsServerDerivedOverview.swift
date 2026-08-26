import SwiftUI

/// W5b (v0.12) — the two server-derived overview surfaces, grouped so the
/// `InsightsScreen` mounts them with a single line (file-length discipline).
///
/// Renders the derived re-frames / WellnessScores block
/// (`vitals-dashboard.tsx` derived tiles + `wellness-scores.tsx`:
/// server-computed scores + age/HRV re-frames with the
/// coverage/confidence/provenance transparency envelope — HONEST-ONLY).
///
/// Pure server reads (paired-only). The host gates this whole group on
/// `BackendAvailability.hasServer`; each child additionally self-suppresses to
/// `EmptyView` when its data is absent, so in standalone / no-data the surface
/// contributes nothing to the scroll column.
///
/// **Parity Build 4 · 4.6 — the RhythmEvents card moved OUT of this group.** It
/// used to be the first child here, but the only call site passed it a
/// hardcoded `rhythmEvents: []` (`InsightsOverviewSlots.swift:236`), so the card
/// self-suppressed forever and the section was dead on the Insights overview
/// while the web showed it. It now lives in its own `InsightsRhythmEventsSlot`
/// fed by the real `RhythmEventsStore` — which also lets it be independently
/// ordered and hidden as the `rhythm-events` overview SECTION (4.5).
struct InsightsServerDerivedOverview: View {
    /// The `status:ok` derived envelopes (`DerivedInsightsStore.presentable`).
    /// Empty → the derived block self-suppresses.
    let derivedMetrics: [DerivedMetricDTO]
    /// I-2 — the FULL derived list (`DerivedInsightsStore.metrics`, both `ok` and
    /// `insufficient` arms) the score-ring cards consume, so the confidence gate
    /// can render the calm "not enough data yet" state for a core score.
    let derivedMetricsAll: [DerivedMetricDTO]
    /// I-2 — deep-nav from a score-detail contributor row into that metric's
    /// Insights page (reuses the overview's `trendChartMetric` push seam).
    let onSelectMetric: ((MetricKind) -> Void)?
    /// v0.14.3 F3 — deep-nav from the Stimmung contributor into the Mood special
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
    /// **CU-33** — pairs the person marked as not relevant for them
    /// (`CorrelationsDiscoveryStore.dismissedPairs`), kept reachable behind a
    /// disclosure so the statement stays reversible.
    var correlationsDismissed: [DiscoveredCorrelation] = []
    /// **CU-33** — records the relevance statement (`true` = not relevant for
    /// me). `nil` hides the affordance.
    var onSetCorrelationDismissed: ((DiscoveredCorrelation, Bool) -> Void)?
    /// **CU-33** — statements currently in flight (control disabled).
    var correlationsPendingIDs: Set<String> = []
    /// **CU-33** — pairs the server brought back on its own after a material
    /// evidence change. Rendered as a calm note, never as an error.
    var correlationsResurfacedIDs: Set<String> = []
    /// **CU-33** — set when a statement could not be saved and the optimistic
    /// change was rolled back.
    var correlationsActionError: String?
    /// v0.14.7 (b156) — when false, the score block omits its "Signale des Tages"
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
        // I-2 — the wellness-score RING CARDS (Bereitschaft / Schlaf / Belastung
        // + Cardio-Fitness gauge). "Signale des Tages" is hoisted out when
        // `showsSignals` is false (rendered by the host after the Einschätzung).
        InsightsScoreCardsBlock(
            metrics: derivedMetricsAll,
            onSelectMetric: onSelectMetric,
            onSelectMood: onSelectMood,
            showsSignals: showsSignals
        )
        // v0.14.9 §2 — every tile-able derived score is now ring-promoted
        // (Recovery / Stress + Vascular age + HRV balance joined the rings), so
        // the "More from your data" text lane has nothing left and self-suppresses.
        // The block stays mounted as the single-source-of-truth dedup partner +
        // a safety-net for any FUTURE unpromoted derived metric (it filters out
        // `ringPromotedIDs` and renders only what remains — today: nothing).
        InsightsDerivedBlock(metrics: derivedMetrics)
        // v0.12 — mounts BELOW the derived-insights block (descriptive,
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
                resurfacedIDs: correlationsResurfacedIDs,
                actionError: correlationsActionError
            )
        }
    }
}
