import SwiftUI

// INV-3 (v0157) — store-scoped leaf hosts for the Home dashboard.
//
// **Why these exist.** Under the Observation framework, every `@Observable`
// property read DURING a view's `body` registers a dependency on THAT view. The
// pre-INV-3 `DashboardScreen.body` read ~7 stores (`DashboardStore`,
// `DashboardLayoutStore`, `SettingsStore`, `MeasurementRemindersStore`,
// `MedicationsStore` via the compliance reconcile, `LiveHealthKitTodayStore`, and
// the `moduleGate`) into ONE body, so a mutation to ANY of them — a frequent HK
// step tick on `liveTodayStore`, an intake-mark on `medicationsStore`, a refresh
// flag flip on `store.isLoading` — re-rendered the WHOLE home surface (header →
// hero → grid construction → ordering → footer).
//
// The fix mirrors `Insights/Sub/InsightsOverviewSlots.swift`: each `@Observable`
// store is now read by the SMALLEST leaf that uses it, so a mutation invalidates
// only that leaf. **Behaviour is byte-identical** — the slots render the exact
// same content, in the same order, behind the same gates as the inline blocks
// they replaced. No visual or behavioural change; only the invalidation scope
// shrank.

// MARK: - Vorsorge host — REMOVED (Wave 2 / 2.6)

//
// `DashboardVorsorgeHost` + its `VorsorgeTile` were deleted. The host gated on
// `VorsorgeNextDue.nextDueNow`, i.e. EXACTLY the condition under which the daily
// digest also emits its `preventive_care` hero-rail item — so a due preventive
// reminder rendered TWICE on Home (rail card + standalone tile). Operator b227:
// one surface, folded into the hero with the same look as "Medikament fällig".
//
// Nothing was lost: `TodayHeroHost.openVorsorge` (`TodayHeroCard.swift`) now
// resolves `VorsorgeNextDue.nextDueNow` itself and branches on the SHARED
// `VorsorgeCard.primaryAction` seam, so the hero rail's `checkup.view` inherits
// the tile's "straight to DOING it" routing (prefilled measure / check-in), with
// the manage list as the free-text fallback.

// MARK: - Sync footer host (DashboardStore + SettingsStore.profile)

/// Owns the discreet last-synced caption. Reads `DashboardStore.isLoading` /
/// `.summary` + `SettingsStore.profile` HERE so a loading-flag flip on refresh
/// invalidates ONLY this footer — not the metrics grid above it.
struct DashboardSyncFooterHost: View {
    @Environment(DashboardStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        // v0.14.1 — discreet last-synced caption (operator: "nett, nicht
        // überfrachtet"). First-login hint while a fresh session has nothing
        // loaded yet; "Wird synchronisiert…" during a refresh; otherwise "Zuletzt
        // synchronisiert HH:MM". v0.14.8 W2-SYNCUX — routed through the shared
        // `HLSyncStatusFooter` so every refreshable screen mounts the identical
        // primitive (placement can't drift).
        HLSyncStatusFooter(
            screenLoading: store.isLoading,
            firstLoginPreparing: settings.profile == nil && store.summary == nil
        )
    }
}

// MARK: - Metrics host (DashboardStore + DashboardLayoutStore + LiveHealthKit + Settings + moduleGate)

/// The big one. Owns the canonical cards metric composition, its standalone
/// compliance ring, the empty-state branch, plus `orderedMetrics` /
/// `emptyMetricsState`.
///
/// The compliance rings live INSIDE this host (not a separate sibling) because
/// they're sequenced between the highlight card and the grid within the layout
/// switch — a separate sibling would break the byte-identical render order
/// (INV-3 C9 / AUDIT-HOME L15/H1/H3). Folding them in still confines the
/// `MedicationsStore` reconcile dependency to this host (off the parent body —
/// the actual INV-3 win); the cost is a med-intake also re-renders the grid,
/// which is acceptable. Reads `DashboardStore` (`summary.metrics`, `metricStates`,
/// `policyTick`, `fanOutSettledAt`), `DashboardLayoutStore`
/// (ordering / visibility / `recentlyPinnedIds`), `LiveHealthKitTodayStore.todayStepCount`,
/// `MedicationsStore` (via the reconcile), and the `\.appContainer` moduleGate
/// HERE — so a metric fan-out, a frequent HK step tick, or a med-intake mark
/// invalidates ONLY this host instead of the whole home surface.
///
/// INV-3 hazards held: the `gate.modules` + `store.policyTick` Observation touches
/// move WITH `orderedMetrics` (via `DashboardMetricOrdering`, called inside THIS
/// body so the deps register here).
struct DashboardMetricsHost: View {
    let matchedNamespace: Namespace.ID?
    let zoomNamespace: Namespace.ID
    let allowsMotion: Bool
    /// Tile tap → `router.selectInsightsMetric` (host's `openDetail`).
    let onTap: (MetricKind) -> Void
    /// Opens `AnstehendeEinnahmenSheet` (host's `@State showIntakesSheet`).
    let onShowIntakes: () -> Void
    /// Pushes `DashboardCustomizationScreen` (host's `@State showCustomize`).
    let onShowCustomize: () -> Void
    /// Requests the capture flow (`router.requestCapture()`).
    let onRequestCapture: () -> Void
    /// #67 — retries the summary load + per-kind tile fan-out when the metrics
    /// section failed with no cached fallback (drives `DashboardMetricsErrorState`).
    let onRetry: () -> Void

    @Environment(DashboardStore.self) private var store
    @Environment(DashboardLayoutStore.self) private var layoutStore
    @Environment(MedicationsStore.self) private var medicationsStore
    @Environment(LiveHealthKitTodayStore.self) private var liveTodayStore
    // Build 7 / item 7.1 — the digest (7-/30-day averages) + personal targets
    // (target band) feed the tile secondary stats. Read HERE (the metrics host)
    // rather than the parent body so an insights/targets refresh invalidates
    // ONLY this host (INV-3 scoping); both stores settle rarely, so the extra
    // dependency is a cold cost, not a per-frame one.
    @Environment(InsightsStore.self) private var insights
    @Environment(InsightsTargetsStore.self) private var insightsTargets
    @Environment(\.appContainer) private var container

    var body: some View {
        if let summary = store.summary {
            HighlightInsightCard(insight: summary.highlightInsight)
            // v0.5.4.3 HP-6 — see ComplianceReconciler.
            let reconciledCompliance = ComplianceReconciler
                .reconcile(server: summary.compliance, medicationsStore: medicationsStore)
            // The ring honours the customize screen's "Medications" toggle.
            if medicationsTileVisible {
                ComplianceRingCard(snapshot: reconciledCompliance) {
                    onShowIntakes()
                }
            }
            let visibleMetrics = orderedMetrics(summary.metrics)
            if visibleMetrics.isEmpty {
                emptyMetricsState
            } else {
                MetricsGrid(
                    metrics: visibleMetrics,
                    states: store.metricStates,
                    matchedNamespace: matchedNamespace,
                    zoomNamespace: zoomNamespace,
                    allowsMotion: allowsMotion,
                    liveTodayStepsOverride: liveTodayStore.todayStepCount,
                    digest: insights.comprehensive?.digest,
                    targets: insightsTargets.response,
                    onTap: onTap
                )
            }
            // Build 7 / item 7.2 — Home front door for logging + layout. Only
            // when the dashboard actually has tiles: the empty states above
            // carry their own contextual capture/customize CTAs, so the footer
            // would be a redundant second copy there.
            if !orderedMetrics(summary.metrics).isEmpty {
                DashboardQuickActionsFooter(
                    onShowCustomize: onShowCustomize
                )
            }
        } else if DashboardMetricsSectionState.resolve(
            hasSummary: false,
            hasError: store.error != nil,
            isLoading: store.isLoading
        ) == .error {
            // #67 — the summary subrequest failed with no cached fallback.
            // Show an honest error + retry instead of an indefinite skeleton;
            // the score rings / hero / compliance sections above render through
            // their own stores and are unaffected.
            DashboardMetricsErrorState(onRetry: onRetry)
        } else {
            SkeletonContent()
        }
    }

    /// v0.14.8 AUDIT-HOME H2 — honest empty branch for the metric area, shared by
    /// the cards layout. Distinguishes the two reasons `orderedMetrics` can come
    /// back empty:
    ///
    /// - **The user actually hid every metric tile** → the v0.8.2
    ///   `TileGridEmptyState` escape hatch into the customize screen stays correct
    ///   ("You've hidden every tile. Add some back…").
    /// - **A fresh account with zero data** → every synth tile auto-hid via
    ///   `DashboardEmptyTilePolicy`, the user hid *nothing*, and the old copy plus
    ///   its CTA was a lying dead-end. Render the calm "No data yet" guidance
    ///   toward Apple-Health-Connect / Erfassen instead.
    @ViewBuilder
    private var emptyMetricsState: some View {
        if DashboardMetricOrdering.hasUserHiddenAllMetricTiles(layoutStore: layoutStore) {
            TileGridEmptyState {
                onShowCustomize()
            }
        } else {
            DashboardNoDataEmptyState {
                onRequestCapture()
            }
        }
    }

    private var medicationsTileVisible: Bool {
        DashboardMetricOrdering.medicationsTileVisible(layoutStore: layoutStore)
    }

    private func orderedMetrics(_ metrics: [DashboardMetric]) -> [DashboardMetric] {
        DashboardMetricOrdering.orderedMetrics(
            metrics,
            store: store,
            layoutStore: layoutStore,
            container: container
        )
    }
}
