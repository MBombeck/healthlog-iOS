import SwiftUI

// `MetricDrillDown` + `DrillDownErrorState` live in `DashboardDrillDown.swift`
// to keep this file under the 600-line `file_length` swiftlint budget.

struct DashboardScreen: View {
    /// v0.12 W0-3 — bind the Home tab's `NavigationStack` to the router's
    /// `homePath` so the path is no longer dead state. The router resets
    /// `homePath` on the `.dashboard` deep link, on the mood-quick-entry
    /// request, and on a Home tab re-tap (`tabSelectionBinding`); with the
    /// stack bound, those resets actually pop the Home stack to root. Home has
    /// no push-deep-link routes of its own (no `navigationDestination(for:)`),
    /// but its in-screen pushes (profile / customize / tile drill-downs) now
    /// live on the shared `homePath` so a re-tap returns them to root too.
    @Environment(AppRouter.self) private var router
    // W-FILELEN — internal (not private) so the `DashboardScreen+Ordering.swift`
    // same-module extension can read these. Pure visibility relax; no behaviour.
    @Environment(DashboardStore.self) var store
    @Environment(DashboardLayoutStore.self) var layoutStore
    @Environment(SettingsStore.self) private var settings
    @Environment(InsightsStore.self) private var insights
    /// Build 7 / item 7.1 — personal targets back the tile "Zielband". Warmed on
    /// the dashboard (gated `response == nil`) so the band paints on the first
    /// Home visit, not only after the user opens Insights; SWR-deduped with the
    /// Insights overview's own load.
    @Environment(InsightsTargetsStore.self) private var insightsTargets
    @Environment(HealthScoreStore.self) private var healthScore
    @Environment(MeasurementsStore.self) private var measurementsStore
    /// v0.15 W-FRONTDOORS — app-wide Vorsorge reminder store backing the Home
    /// next-due tile. Shared (SWR-deduped) with `MeasurementRemindersScreen`.
    @Environment(MeasurementRemindersStore.self) private var remindersStore
    /// v0.15.7 W-RHYTHM-FRONTDOOR — device-health-notifications (ECG/AFib
    /// rhythm-events) store, shared with the Insights overview card. W-FILELEN —
    /// internal so `+Ordering.swift` reads it for `rhythmEventsSummary`.
    @Environment(RhythmEventsStore.self) var rhythmEventsStore
    /// Paired-only gate — the rhythm front door is a pure server read, warmed
    /// only when a server is reachable (standalone hides it like the card).
    @Environment(BackendAvailability.self) private var backend
    /// v0.5.3 D1 — wires /api/insights/generate payload as serverFallback.
    @Environment(DailyBriefingStore.self) private var briefingStore
    /// Web-parity `TodayHero` — the daily-digest store backing the dashboard
    /// hero. Warmed on cold-launch + pull-to-refresh (paired-only, self-hiding).
    @Environment(DailyDigestStore.self) private var digestStore
    /// v0.5.4 BF-1 — mood + meds feed the Statistik-Mode floor on the hero.
    /// b241 Fix 2 — non-private so the `DashboardScreen+Ordering` extension can
    /// read `moodStore.entries` when it hands the mood snapshot to
    /// `refreshMetricStates` (the `.mood` tile derives its state from MoodStore).
    @Environment(MoodStore.self) var moodStore
    @Environment(MedicationsStore.self) private var medicationsStore
    /// W-FILELEN — internal so `DashboardScreen+Ordering.swift` can read it.
    @Environment(\.appContainer) var container
    /// v0.6.2.x bug-c10-ios-direct — HK-direct today step total. The
    /// dashboard Steps tile reads from here for the "today" value so the
    /// operator's freshly-walked steps render even when the server
    /// `stats:` row is frozen (insert-only batch route — see
    /// `LiveHealthKitTodayStore` doc). Refreshed on `.task`,
    /// pull-to-refresh, and scenePhase=.active hooks.
    @Environment(LiveHealthKitTodayStore.self) private var liveTodayStore
    /// W-IMPL-MOTION-POLISH (v0.5.5.1) — reduce-motion gate for the greeting
    /// fade + matched-geometry transition. When `true`, the greeting opacity
    /// stays at 1.0 and the matched-geometry namespace resolves to `nil`.
    /// (Wave 2 / 2.4 — the hero parallax this also gated is gone.)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// v0.6.2.x — observed scenePhase so the dashboard can re-fan-out
    /// per-kind `MetricDataState` after the app returns to foreground.
    /// Without this, `RootView.refreshHealthKitDailyStatsIfReady` posts
    /// today's fresh HK day-totals to the server but the in-memory
    /// tile state stays on the prior commit — operator sees the same
    /// stale Steps value the bug-c10 walkthrough reproduced.
    @Environment(\.scenePhase) private var scenePhase

    /// v0.5.4-NF-1 — NavigationPath suffix flag toggled by the toolbar
    /// avatar tap. Wrapping the bool in a typed `.navigationDestination`
    /// keeps the push declarative + survives state restoration.
    @State private var showProfile = false
    // v0.13.1 IC — the Home-stack metric drill-down state (`drillDown`
    // + the eagerly-built `drillDownStore`) was RETIRED. The tile tap now
    // drives `router.selectInsightsMetric(_:)` so it lands the operator in the
    // Insights tab on that metric (one canonical surface), instead of pushing a
    // second `InsightsMetricScreen` instance onto `homePath`. See
    // `openDetail(for:)`.
    /// W-IMPL-MOTION-POLISH — live scroll offset driving `HealthScoreTile`
    /// translation + `DashboardHeader` greeting opacity. v0.14.8 AUDIT-HOME
    /// M11: an `@Observable` box written by `onScrollGeometryChange` instead
    /// of a screen-level `@State` — the per-frame write no longer
    /// invalidates this whole body (header, hero, grid construction,
    /// `orderedMetrics`); only the tiny readers re-evaluate. See
    /// `DashboardParallax.swift` for the math + reduce-motion contract.
    @State private var parallaxModel = DashboardParallaxModel()
    /// W-IMPL-MOTION-POLISH — namespace for the matched-geometry shared
    /// element transition that lifts a tile's value text into the
    /// `ChartDetailScreen.HeroStrip`. When `accessibilityReduceMotion` is
    /// true we forward `nil` instead of this namespace into the drill-down
    /// payload, which causes both tile + destination to fall through to
    /// `View.matchedTileGeometry` no-op branches — guaranteeing no implicit
    /// frame animation runs.
    @Namespace private var dashboardNamespace
    /// **v0.5.6 HOME-COMPLIANCE-SHEET.** Drives the
    /// `AnstehendeEinnahmenSheet` presentation triggered by the Compliance
    /// ring card tap. v0.6.1.26 — the standalone Überfällig-banner tap was
    /// removed; the ring tap is now the single entry-point to the sheet.
    @State private var showIntakesSheet = false
    /// v0.8.7 W-NATIVE-REORDER — drives the push to the native
    /// `DashboardCustomizationScreen` (List + .onMove + visibility toggles).
    /// Replaces the removed in-grid jiggle edit mode (`isEditingTiles`) +
    /// add-tile sheet (`showAddTileSheet`). Toggled by the always-on toolbar
    /// button and the empty-state "Add tiles" CTA.
    @State private var showCustomize = false
    /// v0.15 W-FRONTDOORS — drives the push to `MeasurementRemindersScreen` (the
    /// Vorsorge manage surface) when the Home tile's card body is tapped. The
    /// deep path (More → … → Notifications → preventive card) still works; this
    /// is the direct front door.
    @State private var showVorsorge = false

    /// Operator-feedback b235 — the error the top banner should show, or `nil`
    /// when it must stay silent because the INLINE metrics error card (#67) is
    /// already carrying the same failure.
    ///
    /// On a dashboard partial failure (`summary == nil`, a load error, no
    /// in-flight retry) `DashboardMetricsHost` renders `DashboardMetricsErrorState`
    /// in the metrics section. Pre-fix the red top banner (`store.error`) rendered
    /// AS WELL, so the same outage screamed twice. We suppress the banner in
    /// EXACTLY the state that shows the inline card — reusing the same
    /// `DashboardMetricsSectionState.resolve` the host branches on — so the two
    /// surfaces can never disagree. Every other banner case (a secondary-request
    /// error while a cached summary still renders the tiles) is unchanged: the
    /// inline card is not shown there, so the banner remains the only surface.
    private var topBannerError: HLError? {
        let inlineErrorShown = DashboardMetricsSectionState.suppressesTopBanner(
            hasSummary: store.summary != nil,
            hasError: store.error != nil,
            isLoading: store.isLoading
        )
        return inlineErrorShown ? nil : store.error
    }

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.homePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    // v0.14.8 AUDIT-HOME M11 — the zero-height GeometryReader
                    // probe is gone; the ScrollView publishes its offset via
                    // `onScrollGeometryChange` below. The header reads the
                    // model itself so only its greeting fades per frame.
                    DashboardHeader(
                        showProfile: $showProfile,
                        parallax: parallaxModel
                    )
                    HealthKitConnectBanner()
                    // v0.5.6 HOME-COMPLIANCE-SHEET — operator brief
                    // (2026-05-22): the standalone "Anstehende
                    // Einnahmen" card is consolidated into a bottom-sheet
                    // v0.6.1.26 — Überfällig-Banner removed per operator
                    // brief 2026-05-24 ("ist sehr alarmierend, lieber in
                    // der Medikamenten-Compliance haben"). The overdue
                    // indicator now renders inline inside ComplianceRingCard
                    // — same intake-sheet on tap, less screaming Home.
                    // v0.5.4.2 — briefing hero collapsed into HealthScoreTile.
                    // b172 — operator: the per-pillar finding chips ("Blood
                    // Pressure", "Weight is slightly different", …) read as
                    // noise on Home; the tile stays the ring + band + delta
                    // only. The findings still live in the Insights overview.
                    // v0.14.8 AUDIT-HOME M11 — the wrapper hosts the
                    // per-frame offset read; the tile itself keeps identity
                    // and never re-evaluates from scrolling alone.
                    // Web-parity `TodayHero` (v1.29.1) — the promoted day's read
                    // REPLACES the old `HealthScoreTile` + `DashboardScoreRingsHost`
                    // cluster at the top of Home (operator brief, decision 1+2).
                    // Server-authoritative daily digest (`GET /api/daily/digest`);
                    // self-hides on absent / gated-off / calm-degrade. The single
                    // health ring taps into Insights. The score-rings live in
                    // Insights ONLY now (they already render there as the wellness
                    // score-ring cards, `InsightsScoreCardsBlock`); the
                    // `checkup.view` rail action opens the Vorsorge front door.
                    //
                    // **Wave 2 / 2.4 (b227): the hero parallax was REMOVED.** The
                    // `DashboardParallaxOffset` wrapper that translated the hero
                    // at `HLMotion.parallaxRate` is gone — the web hero has no
                    // parallax (parity), HIG scroll-views cautions that custom
                    // scroll effects break Look-to-Scroll, and the effect made
                    // the hero read as detached from its own rail. The greeting
                    // fade in `DashboardHeader` still reads `parallaxModel`.
                    //
                    // **Wave 2 / 2.6:** the standalone `DashboardVorsorgeHost`
                    // was REMOVED. It rendered the `VorsorgeTile` in exactly the
                    // situation the hero rail already fires its `preventive_care`
                    // item, so a due reminder showed up TWICE on Home. The hero
                    // rail is now the single due-surface, and its `checkup.view`
                    // action inherited the tile's straight-to-measuring routing
                    // (see `TodayHeroHost.openVorsorge`).
                    TodayHeroHost(
                        onOpenVorsorge: { showVorsorge = true },
                        onShowIntakes: { showIntakesSheet = true }
                    )
                    // v0.15.7 W-RHYTHM-FRONTDOOR — front door to the device-health-
                    // notifications (ECG/AFib rhythm-events) card. Surfaces ONLY
                    // when the wearable flagged events (summary nil on empty →
                    // self-suppresses, no dead slab), routing to the Insights
                    // overview that hosts the full regulator-aware card. See
                    // `RhythmEventsTile` for the non-diagnostic doctrine.
                    if let rhythmEventsSummary {
                        RhythmEventsTile(summary: rhythmEventsSummary)
                    }
                    // INV-3 (v0157) — the metric composition (highlight card,
                    // compliance reconcile + rings, the layout switch, all three
                    // empty-state branches, `orderedMetrics`, `emptyMetricsState`)
                    // moved INTO `DashboardMetricsHost`. It reads `DashboardStore`,
                    // `DashboardLayoutStore`, `SettingsStore.dashboardLayout`,
                    // `MedicationsStore` (reconcile), `LiveHealthKitTodayStore`
                    // (the frequent HK step tick) and the `moduleGate` on its OWN
                    // body, so those mutations no longer re-render this whole home
                    // surface (header → footer). Behaviour byte-identical.
                    DashboardMetricsHost(
                        matchedNamespace: matchedGeometryNamespace,
                        zoomNamespace: dashboardNamespace,
                        allowsMotion: !reduceMotion,
                        onTap: openDetail,
                        onShowIntakes: { showIntakesSheet = true },
                        onShowCustomize: { showCustomize = true },
                        onRequestCapture: { router.requestCapture() },
                        // #67 — retry the failed summary load + re-derive the
                        // per-kind tile states (force past the SWR TTL).
                        onRetry: {
                            Task {
                                await store.refresh(force: true)
                                await refreshTileStates()
                            }
                        }
                    )
                    // v0.14.1 — discreet last-synced caption (operator: "nett,
                    // nicht überfrachtet"). INV-3 — the `store.isLoading` /
                    // `settings.profile` reads moved into `DashboardSyncFooterHost`
                    // so a refresh-flag flip invalidates only the footer, not the
                    // metrics grid above it.
                    DashboardSyncFooterHost()
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                // Native iOS-18 TabView inserts the tab-bar safe-area inset
                // automatically (M2-A2). HLSpace.lg gives a breathing-gap.
                .padding(.bottom, HLSpace.lg)
            }
            // v0.14.8 AUDIT-HOME M11 — native iOS-18 scroll-geometry stream.
            // `contentOffset.y + contentInsets.top` is 0 at rest and grows
            // positive as the user scrolls DOWN — the canonical semantic the
            // math helpers expect. The write lands in the @Observable model
            // from an action closure, so this screen's body holds NO
            // dependency on the per-frame value.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                parallaxModel.scrollOffset = newValue
            }
            .hlScreenBackground()
            // v0.11 perf: mark Dashboard first content paint so the
            // cold-launch first-paint budget (≤300 ms p95) is measurable in
            // Instruments → Points of Interest. No behavioural effect.
            .hlSignpostFirstPaint(.dashboardFirstPaint)
            // v0.5.x C-9 — iOS 26+ soft scroll-edge; iOS 18-25 no-op.
            .hlScrollEdgeSoft()
            // W-B184 — WHOOP-style pull-to-refresh: custom pull glyph + a
            // `.done`-driven checkmark + one success haptic, replacing stock
            // `.refreshable`. The handshake that drives the phase machine (→
            // checkmark) is now owned by `hlPullToRefresh`, so it is dropped
            // from this action's fan-out.
            .hlPullToRefresh {
                // V053-D3 sticky reset — pull-to-refresh is the explicit
                // user-driven invalidation point for the sticky tile state
                // machine (clears prior verdicts so the next fan-out can
                // re-derive without the monotonic-transition guard).
                store.resetMetricStatesForRefresh()
                // v0.6.2.x — pull-to-refresh is also the operator's
                // explicit "give me the current value NOW" signal. Fire
                // the HK daily-stats sync FIRST so the server has
                // today's fresh totals before we reload the dashboard
                // snapshot; otherwise the refresh paints the same stale
                // value the operator just walked past on the prior
                // server-side row. `refreshHealthKitDailyStatsForToday`
                // also kicks the live HK-direct today-step store so the
                // tile's HK-direct number lands first-paint.
                if let container {
                    // W8-A1 — explicit user refresh bypasses the foreground
                    // self-throttle.
                    await container.refreshHealthKitDailyStatsForToday(force: true)
                }
                // W8-B2 — the remaining store refreshes now fan out
                // CONCURRENTLY (previously a chain of sequential awaits). The
                // set is unchanged — same stores, same force-flags — but the
                // round-trips run in parallel and the SWR coordinator
                // single-flights any key two of them happen to share, so the
                // pull completes in one network wave instead of nine serial
                // ones. The HK-stats sync stays sequential ABOVE this block
                // (the summary re-read must see today's fresh server rows),
                // and `refreshTileStates()` stays sequential BELOW (it
                // re-derives per-kind state from the refreshed summary +
                // measurements). W8-B1: dashboard + measurements force past
                // the TTL; the rest respect their own TTLs.
                async let dashboard: Void = store.refresh(force: true)
                async let layout: Void = layoutStore.refresh()
                async let insightsRefresh: Void = insights.refresh()
                // Build 7 / item 7.1 — refresh the tile target bands alongside
                // the digest (paired-only server read).
                async let targetsRefresh: Void = backend.hasServer ? insightsTargets.refresh() : ()
                async let score: Void = healthScore.refresh()
                async let measurements: Void = measurementsStore.load(force: true)
                async let briefing: Void = briefingStore.load()
                async let mood: Void = moodStore.load()
                // Web-parity `TodayHero` — the pull is an explicit refresh of the
                // daily-digest hero too. Paired-only (server-authoritative read).
                async let digest: Void = backend.hasServer ? digestStore.refresh() : ()
                // v0.14.1 — the pull is the explicit sync point. The sync
                // handshake (which flips the bottom caption to "Zuletzt
                // synchronisiert HH:MM" and drives the W-B184 checkmark) now
                // runs inside `hlPullToRefresh`, concurrently with this block.
                _ = await (
                    dashboard, layout, insightsRefresh, targetsRefresh, score,
                    measurements, briefing, mood, digest
                )
                await refreshTileStates()
            }
            .task {
                // Cold-launch parallel fan-out (F5/F6 v0.4.1).
                async let dashboard: () = (store.summary == nil ? store.load() : ())
                async let comprehensive: () = (insights.comprehensive == nil ? insights.load() : ())
                async let layout: () = layoutStore.load()
                async let healthScoreLoad: () = (healthScore.score == nil ? healthScore.load() : ())
                async let measurementsLoad: () = (measurementsStore.recent.isEmpty ? measurementsStore.load() : ())
                async let briefingLoad: () = (briefingStore.response == nil ? briefingStore.load() : ())
                // v0.5.4 BF-1 — mood + meds feed the Statistik-Mode floor.
                async let moodLoad: () = (moodStore.entries.isEmpty ? moodStore.load() : ())
                async let medsLoad: () = (medicationsStore.medications.isEmpty ? medicationsStore.load() : ())
                // v0.6.2.x bug-c10-ios-direct — kick the live HK-direct
                // today-step read in parallel with the rest of cold-launch
                // so the Steps tile lands a fresh number first-paint
                // (TTL-gated so the call collapses to a no-op when the
                // store already has a recent value).
                async let liveTodayLoad: () = liveTodayStore.refreshIfStale()
                // v0.15 W-FRONTDOORS — warm the Vorsorge tile's reminder list
                // (SWR-deduped, so the manage screen's own load collapses to a
                // no-op when it follows). Skipped when already hydrated.
                async let remindersLoad: () = (remindersStore.reminders.isEmpty ? remindersStore.load() : ())
                // v0.15.7 W-RHYTHM-FRONTDOOR — warm the rhythm-events store so the
                // Home front-door tile can gate on real data first-paint. Paired-
                // only (pure server read); skipped in standalone and when already
                // hydrated (SWR-deduped with the Insights overview's own load). The
                // gate is read on the MainActor BEFORE the `async let` so the
                // autoclosure doesn't capture the actor-isolated `response`.
                let warmRhythm = backend.hasServer && rhythmEventsStore.response == nil
                async let rhythmLoad: () = (warmRhythm ? rhythmEventsStore.load() : ())
                // Build 7 / item 7.1 — warm the tile target bands so the Zielband
                // paints first Home visit. Gate read on the MainActor BEFORE the
                // `async let` so the autoclosure doesn't capture the isolated
                // `response`. Paired-only, SWR-deduped, skipped when hydrated.
                let warmTargets = backend.hasServer && insightsTargets.response == nil
                async let targetsLoad: () = (warmTargets ? insightsTargets.load() : ())
                _ = await (
                    dashboard, comprehensive, layout, healthScoreLoad,
                    measurementsLoad, briefingLoad, moodLoad, medsLoad,
                    liveTodayLoad, remindersLoad, rhythmLoad, targetsLoad
                )
                // PA4 unified-data-source: once the summary lands, fan-out
                // per-kind `MetricDataState` via the same endpoint the
                // chart-detail consumes. Shadows the summary endpoint's
                // `latestValue` for the empty-vs-ready predicate so the
                // tile + detail can never disagree.
                await refreshTileStates()
            }
            .onChange(of: layoutStore.layout) { _, _ in
                // v0.14 b147 — a pin/unpin (or any layout mutation, e.g. the
                // customize screen) changes which tiles should surface. Kick
                // the per-kind fan-out so a newly pinned tile derives its
                // `MetricDataState` immediately instead of waiting for the
                // next `.task` / foreground. Combined with the explicit-pin
                // auto-hide exemption above, the pinned tile both APPEARS at
                // once (skeleton) and then HYDRATES with real data.
                Task {
                    await refreshTileStates()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // W8-A1 — RootView now OWNS the foreground HK-stats sync +
                // dashboard summary revalidation (previously both this
                // handler and RootView fired them, running the HK read +
                // `dashboardSummary` revalidation twice concurrently on every
                // `.active` while Home was visible). Here we only re-derive
                // the per-kind tile state from the data RootView refreshed —
                // the sticky tile state-machine settles the tiles once the
                // refreshed summary + per-kind series land. No HK sync, no
                // `store.refresh()` duplicate.
                guard newPhase == .active else { return }
                Task {
                    await refreshTileStates()
                }
            }
            // v0.12 W3-3 — banner SLIDES in via `hlErrorBannerOverlay`, which
            // bakes in the `.animation(.easeInOut(0.3), value: store.error)`
            // driver that was missing here. Pre-fix the `ErrorBanner`
            // transition never played (no value-driver on the overlay), so the
            // banner popped in/out instantly on the primary entry screen.
            // Operator-feedback b235 — suppressed when the inline metrics error
            // card (#67) is already showing, so a partial failure isn't reported
            // by BOTH the top banner and the inline card. See `topBannerError`.
            .hlErrorBannerOverlay(error: topBannerError) {
                // Explicit user retry → force past the TTL.
                Task { await store.refresh(force: true) }
            }
            // v0.10 R5 — the always-on `slider.horizontal.3` customise button
            // (v0.8.7) is removed: the operator found it "fürchterlich" at the
            // dashboard top. Customisation stays reachable via Settings →
            // "Dashboard anpassen" (`SettingsDashboardScreen` → customizeRow)
            // and the all-tiles-hidden empty-state escape hatch below still
            // navigates to `DashboardCustomizationScreen` via `$showCustomize`.
            // The dashboard top is now clean (just the profile avatar).
            .navigationDestination(isPresented: $showCustomize) {
                DashboardCustomizationScreen()
            }
            // v0.15 W-FRONTDOORS — direct front door to the Vorsorge manage
            // surface from the Home tile's card-body tap. Same destination the
            // deep path (More → Notifications → preventive card) reaches.
            .navigationDestination(isPresented: $showVorsorge) {
                MeasurementRemindersScreen()
            }
            .sheet(isPresented: $showIntakesSheet) {
                AnstehendeEinnahmenSheet()
            }
            // v0.13.1 IC — the Home-stack metric drill-down was RETIRED here.
            // A tile tap now drives `router.selectInsightsMetric(_:)` →
            // `.insights(metric:)`, landing the operator in the Insights tab on
            // that metric's page (one canonical surface). The old
            // `.navigationDestination(item: $drillDown)` pushed a SECOND
            // instance of `InsightsMetricScreen` onto `homePath` on the Home
            // tab, which is what made it feel like a duplicate view. The matched-
            // geometry hero zoom was a within-stack effect and cannot carry
            // across the tab switch — see `openDetail(for:)`. The web-mirror
            // `InsightsMetricScreen` is still reachable (and identical) via the
            // Insights tab; nothing about the detail SURFACE was lost.
            // v0.5.4.1 — avatar moved INLINE into the greeting row (see
            // `Header(showProfile:)` below). The toolbar still owns the
            // `navigationDestination` push so the inline tap can flip
            // the binding and trigger the same `ProfileScreen` push that
            // the v0.5.4 NF-1 toolbar item previously fired.
            .dashboardProfileDestination(isPresented: $showProfile)
        }
        // v0.11 N1 — thread the user's display-unit prefs into the tile
        // subtree so every metric surface converts weight/BP/glucose at
        // display time without prop-drilling.
        .environment(\.unitPreferences, settings.unitPreferences)
    }

    // INV-3 (v0157) — `emptyMetricsState` + `vorsorgeDue` +
    // `medicationsTileVisible` + `hasUserHiddenAllMetricTiles` moved off this
    // screen: the empty-state + ordering helpers now live in
    // `DashboardMetricOrdering` (called by `DashboardMetricsHost`), and the
    // Vorsorge gate lives in `DashboardVorsorgeHost`. `rhythmEventsSummary`
    // stays in `DashboardScreen+Ordering.swift` (still read by this body's
    // `RhythmEventsTile` placement).

    /// W-IMPL-MOTION-POLISH — resolves the matched-geometry namespace
    /// forwarded into tiles + the drill-down payload. When the user has
    /// `Reduce Motion` enabled, returns `nil` so both the source tile and
    /// the destination hero fall through to their no-op branches in
    /// `View.matchedTileGeometry`. SwiftUI runs no implicit frame animation
    /// + the navigation push falls back to the default slide transition.
    private var matchedGeometryNamespace: Namespace.ID? {
        reduceMotion ? nil : dashboardNamespace
    }

    // v0.14.8 AUDIT-HOME M11 — the invisible GeometryReader/PreferenceKey
    // `parallaxProbe` was deleted; `onScrollGeometryChange` on the
    // ScrollView (see `body`) is the offset source now.

    private func openDetail(for kind: MetricKind) {
        // v0.14 audit #17 — open the tap-to-detail interval (≤ 200 ms p95). The
        // Insights metric page's first content paint closes it. Pure
        // measurement; no behaviour change.
        HLPerfSignpost.beginTapToDetail()
        // v0.13.1 IC — NAV UNIFICATION. The tile tap no longer pushes
        // `InsightsMetricScreen` onto the Home `NavigationStack` (a second
        // navigation INSTANCE of the same screen, on the wrong tab — the
        // operator's "feels like a duplicate view" report). It now drives the
        // existing `.insights(metric:)` deep link, so a tap switches to the
        // Insights tab and selects that metric's page — one canonical surface,
        // the tab strip live, no double-maintenance.
        //
        // Felt tradeoff: the within-stack matched-geometry hero ZOOM cannot
        // carry across a tab boundary, so the tap is now a tab-switch + pager
        // land rather than a zoom-morph. The unified mental model (operator's
        // explicit ask) is worth the lost zoom; flagged for the felt-walk in
        // the IC report. (Dead zoom modifier removed in AUDIT-HOME M6/HOME-7.)
        router.selectInsightsMetric(kind)
        HLLog.ui.notice("Dashboard tile tap → Insights tab for \(kind.rawValue)")
        // Pre-warm the SWR cache the Insights metric page reads, so the page
        // lands on cached values (same paths `ChartDetailStore.load()` reads).
        // Best-effort + detached so the tab switch is never gated on the warm.
        guard let container else { return }
        let repo = container.measurementsRepo
        Task.detached(priority: .userInitiated) {
            async let series: () = {
                _ = try? await repo.series(kind: kind, days: 30)
            }()
            async let recent: () = {
                _ = try? await repo.recent(kind: kind, limit: 400)
            }()
            _ = await (series, recent)
        }
    }

    // W1 Fix 3 — `makePreLoadHook(for:container:)` moved into the single
    // `AppContainer.makeChartDetailStore(kind:)` factory
    // (`AppContainer+ChartDetail.swift`) so all four drill-in surfaces share
    // one consent + pre-load + live-steps wiring path.

    // `refreshTileStates()`, `moduleDisabledMetricKinds()` and
    // `orderedMetrics(_:)` live in `DashboardScreen+Ordering.swift` to keep
    // this file under the 600-line `file_length` swiftlint budget.
}

// Alternate dashboard renderers were retired in favour of one canonical
// cards composition.
// `DashboardHeader` lives in `DashboardHeader.swift` to keep this file
// under the 600-line `file_length` swiftlint budget.

// `HighlightInsightCard` + `InsightRecommendationActions` + `MetricsGrid` live
// in `DashboardScreen+Sections.swift`; `DrillDownErrorState` lives in
// `DashboardDrillDown.swift` — both to keep this file under the 600-line
// `file_length` swiftlint budget.

// v0.5.1-A B3 — `ComplianceRingCard` extracted to its own file so the
// per-snapshot subtitle helper doesn't push `DashboardScreen.swift` past
// the 600-line file-length lint baseline. See `ComplianceRingCard.swift`.

// `SkeletonContent` lives in `DashboardSkeleton.swift` (now backed by the
// design-system `HLSkeleton` primitive) to keep this file under the
// 600-line swiftlint `file_length` threshold.
