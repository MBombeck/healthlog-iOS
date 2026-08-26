import SwiftUI

/// INV-3 (v0157) — the body-render ordering/visibility helpers, hoisted off
/// `extension DashboardScreen` into a free static namespace so the new
/// store-scoped leaf hosts (`DashboardMetricsHost` in `Sub/DashboardSlots.swift`)
/// can call them WITHOUT re-introducing a body dependency on `DashboardScreen`
/// itself.
///
/// **Why a static helper, not extension members.** Under Observation, every
/// `@Observable` property read during a view's `body` registers a dependency on
/// THAT view. The pre-INV-3 `DashboardScreen.body` called these helpers inline,
/// so the layout/store/moduleGate reads landed on the screen body — any unrelated
/// mutation re-rendered the whole home surface. By moving the render logic here as
/// pure statics that take the stores as parameters, the leaf host that calls them
/// (and reads the stores via its OWN `@Environment`) is the only view that takes
/// the dependency.
///
/// **Behaviour is byte-identical** to the previous `extension DashboardScreen`
/// members — same filter/sort rules, same load-bearing `gate.modules` and
/// `store.policyTick` Observation touches (INV-3 hazards C3/C4), same memoised
/// lookups. The reads still happen during the CALLER's `body`, so the
/// `@Observable` dependency chain is preserved on the calling leaf.
@MainActor
enum DashboardMetricOrdering {
    /// #30 — the union of `MetricKind`s owned by every server-disabled module.
    /// Empty when no `ModuleGate` is wired (previews / tests) or every module is
    /// on. Reading `moduleGate.modules` (via the memoised accessor) makes the
    /// CALLER re-evaluate when the map changes (the gate is `@Observable`).
    static func moduleDisabledMetricKinds(container: AppContainer?) -> Set<MetricKind> {
        guard let gate = container?.moduleGate else { return [] }
        // W-PERF-SWR (High) — the per-call set-build (loop over every
        // `ModuleKey` × its kinds) is memoized on the gate keyed on `modules`,
        // so `orderedMetrics`'s up-to-3×-per-body call no longer rebuilds it.
        // The accessor reads `modules` internally → the @Observable dependency
        // is preserved (a disable still flips the tile out).
        return gate.dashboardDisabledMetricKinds()
    }

    /// Applies the user's preferred order + visibility to the metrics array
    /// returned by `/api/dashboard/summary`. The layout store is the authority on
    /// which tiles appear and in what sequence.
    ///
    /// Behaviour rules:
    /// - Drop metrics whose corresponding widget id is `tileVisible: false`.
    /// - Keep metrics whose widget id is unknown to the layout (defensive
    ///   against server adding a kind before the layout endpoint catches up).
    /// - Sort by the layout's `order`. Unmapped metrics float to the end.
    static func orderedMetrics(
        _ metrics: [DashboardMetric],
        store: DashboardStore,
        layoutStore: DashboardLayoutStore,
        container: AppContainer?
    ) -> [DashboardMetric] {
        // W-B187 — the two id→order / id→visibility dictionaries depend ONLY on
        // the layout, so they're memoized on the store (`widgetOrderLookup`) and
        // recomputed only when the layout changes — not on every body eval driven
        // by an unrelated store's churn. The per-metric live reads (`policyTick`,
        // `metricStates`, `recentlyPinnedIds`) stay in the closure below so the
        // empty-tile policy still re-evaluates on data changes.
        let lookup = layoutStore.widgetOrderLookup
        let orderById = lookup.orderById
        let visibilityById = lookup.visibilityById
        // #30 — drop tiles whose owning module is switched OFF server-side. The
        // gate fails open (all-on) when the server map is absent / not loaded,
        // so this is a no-op until the #30 deploy goes live.
        let moduleDisabledKinds = moduleDisabledMetricKinds(container: container)
        return metrics
            .compactMap { metric -> (Int, DashboardMetric)? in
                // #30 — module-gated kind hidden by a server-disabled module.
                if moduleDisabledKinds.contains(metric.kind) { return nil }
                guard let widgetId = DashboardWidgetId.id(forMetricKind: metric.kind) else {
                    // Unknown to the layout — keep it (float to end).
                    return (.max, metric)
                }
                // Hidden by the user.
                if visibilityById[widgetId] == false { return nil }
                // V051B F1b + V052-A1 N1 — auto-hide tiles with no data ever,
                // and additionally hide tiles whose per-kind state stayed
                // `.unknown`/`.loading` after `recentAll()` failed (fan-out
                // settled but no derivation landed). Both branches require
                // the metric itself to carry no remembered value or sparkline.
                // V052-R3 A-H1 — touch `policyTick` so the @Observable
                // dependency chain re-evaluates this predicate when the
                // post-settle 1.6s tick fires. Without this read, a cold
                // launch with HK + network both failing would leave tiles
                // on `.loading` forever (no further state change drives a
                // re-render past the 1.5s grace window).
                _ = store.policyTick
                // v0.14 b147 — NEVER auto-hide a tile the user explicitly
                // pinned via "Add to Home". A freshly pinned synth tile has
                // no data yet, so the empty-tile policy would filter it right
                // back out (operator bug: "pin does nothing"). The explicit
                // pin is the user's intent; render it (skeleton / em-dash)
                // until the per-kind fan-out resolves. Genuinely-empty
                // NON-pinned tiles still auto-hide as before.
                let isUserPinned = layoutStore.recentlyPinnedIds.contains(widgetId)
                if !isUserPinned,
                   DashboardEmptyTilePolicy.shouldAutoHide(
                       metric,
                       states: store.metricStates,
                       fanOutSettledAt: store.fanOutSettledAt
                   ) { return nil }
                return (orderById[widgetId] ?? .max, metric)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// v0.14.8 AUDIT-HOME H1 — tile visibility of the `medications` widget row.
    /// Gates every compliance surface on Home (ring card on cards/list, mini-card
    /// on hero) so the customize screen's "Medications" toggle has a real effect.
    /// Defaults to visible when the row is missing (defensive against a server
    /// layout that drops the id — never hide silently).
    static func medicationsTileVisible(layoutStore: DashboardLayoutStore) -> Bool {
        layoutStore.layout.widgets
            .first { $0.id == DashboardWidgetId.medications }?
            .effectiveTileVisible ?? true
    }

    /// `true` only when every metric-mappable widget row in the layout is
    /// explicitly tile-hidden — i.e. the empty grid is the user's own doing.
    /// Non-metric rows (`medications`, `mood`, …) don't count: they never render
    /// in the tile strip, so their visibility can't empty it.
    static func hasUserHiddenAllMetricTiles(layoutStore: DashboardLayoutStore) -> Bool {
        let metricRows = layoutStore.layout.widgets
            .filter { DashboardWidgetId.metricKind(forId: $0.id) != nil }
        guard !metricRows.isEmpty else { return false }
        return metricRows.allSatisfy { !$0.effectiveTileVisible }
    }
}
