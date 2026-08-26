import SwiftUI

/// DASHBOARD-TILE-COMPLETENESS — single decision-point that picks the
/// right tile component per `MetricKind`. Centralises the "which tile
/// art does this kind get" question so dashboard layouts (Cards, Hero,
/// List) all stay consistent and a future Audio-Exposure / VO2 Max
/// composite drops in without editing every layout.
///
/// Today's routing table:
/// - `.sleep` → `SleepCompositeTile` (the T-5 GLP-1 composite — stages
///   visible when InsightsStore.comprehensive provides them, plain
///   sparkline fallback otherwise).
/// - Everything else → `HLDashboardTile` (the canonical grid tile).
///
/// The router stays a thin view-wrapper; it does NOT own data or state.
/// Callers feed it the `DashboardMetric` + `MetricDataState` for the kind
/// and the router routes.
struct DashboardTileRouter: View {
    let metric: DashboardMetric
    let dataState: MetricDataState
    /// W-IMPL-MOTION-POLISH (v0.5.5.1) — matched-geometry namespace
    /// forwarded into `HLDashboardTile` so its value text can match the
    /// `ChartDetailScreen` hero number on tap. `nil` under reduce-motion
    /// or when the parent surface doesn't host a namespace (e.g. the
    /// Charts list path, which hasn't adopted the transition yet).
    /// W-IMPL-BACKLOG-CLEANUP (v0.5.5.2): now also forwarded into
    /// `SleepCompositeTile`, which adopts a "soft" matched-geometry on
    /// the duration text (the most visually dominant element of the
    /// composite shape — the stages strip + legend stay behind because
    /// they have no peer in the chart-detail hero today).
    var matchedNamespace: Namespace.ID?
    /// v0.6.2.x bug-c10-ios-direct — HK-direct today step total forwarded
    /// from `DashboardScreen` (read off `LiveHealthKitTodayStore`). Only
    /// the Steps tile honors it; everything else passes through.
    var liveTodayStepsOverride: Double?
    /// Build 7 / item 7.1 — the comprehensive digest (`InsightsStore`) supplies
    /// the per-kind 7-/30-day averages; the personal-targets response
    /// (`InsightsTargetsStore`) supplies the optional target band. Both `nil`
    /// (cold-launch before either landed, the Hero primary card) → the tile
    /// renders exactly as pre-7.1.
    var digest: ComprehensiveDigest?
    var targets: InsightsTargetsResponseDTO?

    var body: some View {
        switch metric.kind {
        case .sleep:
            // Sleep tile renders the duration + stages-strip composite
            // when stages are present. Stages flow once the server
            // emits them on the dashboard summary (A3 §7.1 backlog) —
            // until then SleepCompositeTile falls back to a duration-
            // only tile with a sparkline that matches the regular tile
            // visual cadence. W-IMPL-BACKLOG-CLEANUP (v0.5.5.2): forward
            // the matched-geometry namespace so the duration text
            // participates in the same shared-element transition into
            // the chart-detail hero that every other metric tile uses.
            SleepCompositeTile(metric: metric, stages: nil, matchedNamespace: matchedNamespace)
        default:
            // Build 7 / item 7.1 — project the secondary stats once, per kind,
            // from the digest + targets. The resolvers are pure + honestly omit
            // (nil) for the composite BP tile / unconfigured targets.
            let averages = DashboardTileTargetResolver.averages(for: metric.kind, digest: digest)
            HLDashboardTile(
                metric: metric,
                provenance: nil,
                dataState: dataState,
                matchedNamespace: matchedNamespace,
                liveTodayStepsOverride: liveTodayStepsOverride,
                avg7: averages?.avg7,
                avg30: averages?.avg30,
                targetBand: DashboardTileTargetResolver.targetBand(for: metric.kind, targets: targets)
            )
        }
    }
}
