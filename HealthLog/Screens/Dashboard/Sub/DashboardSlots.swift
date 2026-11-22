import SwiftUI

// Store-scoped leaf hosts for the Home dashboard.
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

// MARK: - Vorsorge host — REMOVED

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

// MARK: - Sync footer host (DashboardStore)

/// Owns the discreet last-synced caption. Reads `DashboardStore.isLoading`
/// HERE so a loading-flag flip on refresh invalidates ONLY this footer, not
/// the metrics grid above it.
struct DashboardSyncFooterHost: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        // Discreet last-synced caption (operator: "nett, nicht
        // überfrachtet"): "Wird synchronisiert…" during a refresh, otherwise
        // "Zuletzt synchronisiert HH:MM". Routed through the
        // shared `HLSyncStatusFooter` so placement can't drift.
        // 1.4 decision 3 — Today is the one screen that keeps the settled
        // "Zuletzt synchronisiert" line; every other footer shows real states only.
        // No first-login "Deine Daten werden vorbereitet…" here: the
        // `FirstLoginSyncBanner` above the tab bar says it at the same moment.
        HLSyncStatusFooter(screenLoading: store.isLoading, scope: .today)
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
    /// Which half of the composition this host draws. Today splits it over
    /// its two columns: the lead cards stand with the hero, the tiles in the
    /// trailing column. Stacked, the lead stands right above the tiles, the
    /// order it always had.
    enum Part {
        /// The highlight card and the compliance ring.
        case lead
        /// The tiles (or their empty state or skeleton) and the quick actions.
        case tiles
    }

    let part: Part
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
    /// #186 — pushes the symptom quick entry (host's `@State showSymptomEntry`).
    var onLogSymptom: () -> Void = {}

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
    /// The snapshot slot this store already fetches carries the
    /// server's weight verdict; no extra request.
    @Environment(DailyBriefingStore.self) private var briefingStore
    /// The hero's digest: when it names today's medications, the
    /// compliance card would repeat it.
    @Environment(DailyDigestStore.self) private var digestStore
    @Environment(\.appContainer) private var container
    /// Observed so the symptom row appears as soon as the version probe lands.
    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?

    var body: some View {
        switch part {
        case .lead:
            lead
        case .tiles:
            tilesWithRefresh
        }
    }

    private var tilesWithRefresh: some View {
        tiles
            // The summary is re-read after the person marks a dose. Attached
            // to the host, not the compliance card: the card renders nothing
            // while there is nothing to count, and the first dose must still
            // bring it in.
            .onChange(of: DashboardIntakeSignature(medicationsStore)) { old, new in
                guard DashboardIntakeSignature.shouldRefreshSummary(from: old, to: new) else { return }
                Task { await store.refresh(force: true) }
            }
    }

    @ViewBuilder
    private var lead: some View {
        if let summary = store.summary {
            HighlightInsightCard(insight: summary.highlightInsight)
            // The ring renders the server's `compliance`
            // (`scheduledToday` / `takenToday`, profile-zone day, projected
            // slots included since v1.4.39) verbatim. The client no longer
            // recounts today from local intakes; after the person marks a
            // dose, the summary is re-read instead (see `.onChange` below).
            // The ring honours the customize screen's "Medications" toggle.
            if medicationsTileVisible, !ComplianceRingCard.heroNamesMedications(digestStore.digest) {
                // 1.7: the ring counts the confirmed today rows the card
                // shows; the summary only stands in before they are loaded.
                let today = medicationsStore.todayState
                ComplianceRingCard(
                    snapshot: ComplianceRingCard.snapshot(summary: summary.compliance, state: today),
                    openToday: ComplianceRingCard.openToday(state: today),
                    scheduledTodayAt: briefingStore.snapshotBriefing?.scheduledTodayAt,
                    openDoses: ComplianceRingCard.openDoseSlots(medicationsStore.todayIntakes)
                ) {
                    onShowIntakes()
                }
            }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        if let summary = store.summary {
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
                    snapshot: briefingStore.snapshotBriefing,
                    onTap: onTap
                )
            }
            // Build 7 / item 7.2 — Home front door for logging + layout. Only
            // when the dashboard actually has tiles: the empty states above
            // carry their own contextual capture/customize CTAs, so the footer
            // would be a redundant second copy there.
            if !orderedMetrics(summary.metrics).isEmpty {
                DashboardQuickActionsFooter(
                    onShowCustomize: onShowCustomize,
                    onLogSymptom: symptomEntryOffered ? onLogSymptom : nil
                )
            }
        } else if DashboardMetricsSectionState.resolve(
            hasSummary: false,
            hasError: store.error != nil,
            isLoading: store.isLoading
        ) == .error {
            // The summary subrequest failed with no cached fallback. The rest
            // of Home stands, so the failure is the top banner with its retry
            // (`DashboardScreen`), not a second message here and not an
            // endless skeleton.
            EmptyView()
        } else {
            SkeletonContent()
        }
    }

    /// #186 — Today offers "Symptom erfassen" where symptoms can be logged.
    private var symptomEntryOffered: Bool {
        SymptomQuickEntryState.isOffered(
            illnessEnabled: container?.moduleGate.isEnabled(.illness) ?? false,
            serverVersion: serverVersion
        )
    }

    /// Honest empty branch for the metric area, shared by
    /// the cards layout. Distinguishes the two reasons `orderedMetrics` can come
    /// back empty:
    ///
    /// - **The user actually hid every metric tile** → the v0.8.2
    ///   `TileGridEmptyState` escape hatch into the customize screen stays correct
    ///   (title "No tiles shown" and its "Add tiles" button).
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
            // Title and button only: the Apple Health banner above already
            // asks for the connection, and the button says the rest.
            HLEmptyState(icon: "heart.text.square", title: "No data yet") {
                HLButton("Capture first value", systemImage: "plus", variant: .secondary) {
                    onRequestCapture()
                }
            }
            .accessibilityIdentifier("dashboard.noDataEmptyState")
        }
    }

    private var medicationsTileVisible: Bool {
        DashboardMetricOrdering.medicationsTileVisible(layoutStore: layoutStore)
    }

    private func orderedMetrics(_ metrics: [DashboardMetric]) -> [DashboardMetric] {
        DashboardMetricOrdering.orderedMetrics(
            metrics,
            digest: insights.comprehensive?.digest,
            store: store,
            layoutStore: layoutStore,
            container: container
        )
    }
}

// MARK: - Today's one column

/// Today's one column: the head (the Apple Health cards and the hero), the
/// day's cards (rhythm events, highlight, compliance ring) and the tiles.
/// On the phone the day's cards stand above the tiles, as they always did;
/// on a wide page the tiles follow the hero (``TodayLayout/order(contentWidth:)``).
/// The order comes from the width offered in the same layout pass, so
/// nothing jumps after a first frame.
struct TodayStack<Head: View, Cards: View, Tiles: View>: View {
    let head: Head
    let cards: Cards
    let tiles: Tiles

    /// The width last laid out, only for the reading order: VoiceOver and Full
    /// Keyboard Access follow the blocks as they stand.
    @State private var order: TodayLayout.Order = .dayFirst

    var body: some View {
        TodayStackLayout {
            block(priority: 3) { head }
            block(priority: order == .dayFirst ? 2 : 1) { cards }
            block(priority: order == .dayFirst ? 1 : 2) { tiles }
        }
        .onGeometryChange(for: TodayLayout.Order.self) { proxy in
            TodayLayout.order(contentWidth: proxy.size.width)
        } action: { order = $0 }
        .accessibilityElement(children: .contain)
    }

    private func block(priority: Double, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            content()
        }
        .hlContainerGap(HLLayout.cardGap)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(priority)
    }
}

/// Stacks Today's three blocks (head, cards, tiles) in the order of
/// ``TodayLayout/order(contentWidth:)`` at the width it is offered. An empty
/// block takes no gap.
struct TodayStackLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let row = ProposedViewSize(width: width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(row).height }
        let visible = heights.filter { $0 > 0 }.count
        return CGSize(width: width, height: heights.reduce(0, +) + HLLayout.cardGap * CGFloat(max(0, visible - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        let row = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for index in Self.placementOrder(TodayLayout.order(contentWidth: bounds.width), count: subviews.count) {
            let subview = subviews[index]
            let height = subview.sizeThatFits(row).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: row)
            if height > 0 { y += height + HLLayout.cardGap }
        }
    }

    /// The indices of head (0), cards (1) and tiles (2) from the top down.
    static func placementOrder(_ order: TodayLayout.Order, count: Int) -> [Int] {
        guard count == 3 else { return Array(0 ..< count) }
        switch order {
        case .dayFirst: return [0, 1, 2]
        case .tilesFirst: return [0, 2, 1]
        }
    }
}
