import SwiftUI

// `MetricDrillDown` lives in `DashboardDrillDown.swift`
// to keep this file under the 600-line `file_length` swiftlint budget.

struct DashboardScreen: View {
    /// Bind the Home tab's `NavigationStack` to the router's
    /// `homePath` so the path is no longer dead state. The router resets
    /// `homePath` on the `.dashboard` deep link, on the mood-quick-entry
    /// request, and on a Home tab re-tap (`tabSelectionBinding`); with the
    /// stack bound, those resets actually pop the Home stack to root. Home has
    /// no push-deep-link routes of its own (no `navigationDestination(for:)`),
    /// but its in-screen pushes (profile / customize / tile drill-downs) now
    /// live on the shared `homePath` so a re-tap returns them to root too.
    @Environment(AppRouter.self) private var router
    // Internal (not private) so the `DashboardScreen+Ordering.swift`
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
    /// App-wide Vorsorge reminder store backing the Home
    /// next-due tile. Shared (SWR-deduped) with `MeasurementRemindersScreen`.
    @Environment(MeasurementRemindersStore.self) private var remindersStore
    /// Device-health-notifications (ECG/AFib
    /// rhythm-events) store, shared with the Insights overview card. W-FILELEN —
    /// internal so `+Ordering.swift` reads it for `rhythmEventsSummary`.
    @Environment(RhythmEventsStore.self) var rhythmEventsStore
    /// Wires /api/insights/generate payload as serverFallback.
    @Environment(DailyBriefingStore.self) private var briefingStore
    /// Web-parity `TodayHero` — the daily-digest store backing the dashboard
    /// hero. Warmed on cold-launch + pull-to-refresh (self-hiding).
    @Environment(DailyDigestStore.self) private var digestStore
    /// Mood + meds feed the Statistik-Mode floor on the hero.
    /// b241 Fix 2 — non-private so the `DashboardScreen+Ordering` extension can
    /// read `moodStore.entries` when it hands the mood snapshot to
    /// `refreshMetricStates` (the `.mood` tile derives its state from MoodStore).
    @Environment(MoodStore.self) var moodStore
    @Environment(MedicationsStore.self) private var medicationsStore
    /// Internal so `DashboardScreen+Ordering.swift` can read it.
    @Environment(\.appContainer) var container
    /// HK-direct today step total. The
    /// dashboard Steps tile reads from here for the "today" value so the
    /// operator's freshly-walked steps render even when the server
    /// `stats:` row is frozen (insert-only batch route — see
    /// `LiveHealthKitTodayStore` doc). Refreshed on `.task`,
    /// pull-to-refresh, and scenePhase=.active hooks.
    @Environment(LiveHealthKitTodayStore.self) private var liveTodayStore
    /// Reduce-motion gate for the greeting
    /// fade + matched-geometry transition. When `true`, the greeting opacity
    /// stays at 1.0 and the matched-geometry namespace resolves to `nil`.
    /// (Wave 2 / 2.4 — the hero parallax this also gated is gone.)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Observed scenePhase so the dashboard can re-fan-out
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
    // The Home-stack metric drill-down state (`drillDown`
    // + the eagerly-built `drillDownStore`) was RETIRED. The tile tap now
    // drives `router.selectInsightsMetric(_:)` so it lands the operator in the
    // Insights tab on that metric (one canonical surface), instead of pushing a
    // second `InsightsMetricScreen` instance onto `homePath`. See
    // `openDetail(for:)`.
    /// Live scroll offset driving the
    /// `DashboardHeader` greeting opacity. v0.14.8 AUDIT-HOME
    /// M11: an `@Observable` box written by `onScrollGeometryChange` instead
    /// of a screen-level `@State` — the per-frame write no longer
    /// invalidates this whole body (header, hero, grid construction,
    /// `orderedMetrics`); only the tiny readers re-evaluate. See
    /// `DashboardParallax.swift` for the math + reduce-motion contract.
    @State private var parallaxModel = DashboardParallaxModel()
    /// Namespace for the matched-geometry shared
    /// element transition that lifts a tile's value text into the
    /// `ChartDetailScreen.HeroStrip`. When `accessibilityReduceMotion` is
    /// true we forward `nil` instead of this namespace into the drill-down
    /// payload, which causes both tile + destination to fall through to
    /// `View.matchedTileGeometry` no-op branches — guaranteeing no implicit
    /// frame animation runs.
    @Namespace private var dashboardNamespace
    /// Drives the
    /// `AnstehendeEinnahmenSheet` presentation triggered by the Compliance
    /// ring card tap. The standalone Überfällig-banner tap was
    /// removed; the ring tap is now the single entry-point to the sheet.
    @State private var showIntakesSheet = false
    /// Drives the push to the native
    /// `DashboardCustomizationScreen` (List + .onMove + visibility toggles).
    /// Replaces the removed in-grid jiggle edit mode (`isEditingTiles`) +
    /// add-tile sheet (`showAddTileSheet`). Toggled by the always-on toolbar
    /// button and the empty-state "Add tiles" CTA.
    @State private var showCustomize = false
    /// #186 — the symptom quick entry, pushed from the quick-actions card.
    @State private var showSymptomEntry = false
    /// Drives the push to `MeasurementRemindersScreen` (the
    /// Vorsorge manage surface) when the Home tile's card body is tapped. The
    /// deep path (More → … → Notifications → preventive card) still works; this
    /// is the direct front door.
    @State private var showVorsorge = false
    /// Whether the window is short (``TodayLayout/isShortWindow(height:width:)``).
    @State private var isShortWindow = false
    /// Device logic, not layout: whether this device offers Apple Health.
    @Environment(\.deviceProfile) private var deviceProfile

    /// The error the top banner shows. Content stands around every Home
    /// failure, so the banner is the one place it is reported; the metrics
    /// section shows no card of its own (operator-feedback b235: never twice).
    private var topBannerError: HLError? {
        store.error
    }

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.homePath) {
            // A page of tiles: no readable width. One column at every width:
            // on the phone the day's read above the tiles, as Today always
            // had; on a wide page the hero across, the tiles under it, the
            // day's cards last. The greeting heads the column.
            HLPage(readable: false) {
                // The model publishes the scroll offset; the header reads it
                // itself, so only its greeting fades per frame.
                DashboardHeader(
                    showProfile: $showProfile,
                    parallax: parallaxModel
                )
                TodayStack(
                    head: dayColumn,
                    cards: dayCards,
                    tiles: DashboardMetricsHost(
                        part: .tiles,
                        matchedNamespace: matchedGeometryNamespace,
                        zoomNamespace: dashboardNamespace,
                        allowsMotion: !reduceMotion,
                        onTap: openDetail,
                        onShowIntakes: { showIntakesSheet = true },
                        onShowCustomize: { showCustomize = true },
                        onRequestCapture: { router.requestCapture() },
                        onLogSymptom: { showSymptomEntry = true }
                    )
                )
                // Discreet last-synced caption under the column. Its own
                // host, so a refresh-flag flip invalidates only the footer.
                DashboardSyncFooterHost()
            }
            // Native iOS-18 scroll-geometry stream.
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
            // v0.11 perf: mark Dashboard first content paint so the
            // cold-launch first-paint budget (≤300 ms p95) is measurable in
            // Instruments → Points of Interest. No behavioural effect.
            .hlSignpostFirstPaint(.dashboardFirstPaint)
            // Regular: Log as the "+" of this tab root.
            .hlShellCaptureItem(.home)
            // The window's size, safe areas included: in a short window
            // (the folded Duo, a small Stage Manager window) the hero keeps
            // to its short height. Only the verdict is kept, so a resize
            // runs this body only when it crosses the line.
            .onGeometryChange(for: Bool.self) { proxy in
                TodayLayout.isShortWindow(
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom,
                    width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
                )
            } action: { isShortWindow = $0 }
            // WHOOP-style pull-to-refresh: custom pull glyph + a
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
                // Pull-to-refresh is also the operator's
                // explicit "give me the current value NOW" signal. Fire
                // the HK daily-stats sync FIRST so the server has
                // today's fresh totals before we reload the dashboard
                // snapshot; otherwise the refresh paints the same stale
                // value the operator just walked past on the prior
                // server-side row. `refreshHealthKitDailyStatsForToday`
                // also kicks the live HK-direct today-step store so the
                // tile's HK-direct number lands first-paint.
                if let container {
                    // Explicit user refresh bypasses the foreground
                    // self-throttle.
                    await container.refreshHealthKitDailyStatsForToday(force: true)
                }
                // The remaining store refreshes now fan out
                // CONCURRENTLY (previously a chain of sequential awaits). The
                // set is unchanged — same stores, same force-flags — but the
                // round-trips run in parallel and the SWR coordinator
                // single-flights any key two of them happen to share, so the
                // pull completes in one network wave instead of nine serial
                // ones. The HK-stats sync stays sequential ABOVE this block
                // (the summary re-read must see today's fresh server rows),
                // and `refreshTileStates()` stays sequential BELOW (it
                // re-derives per-kind state from the refreshed summary +
                // measurements). Dashboard + measurements force past
                // the TTL; the rest respect their own TTLs.
                async let dashboard: Void = store.refresh(force: true)
                async let layout: Void = layoutStore.refresh()
                async let insightsRefresh: Void = insights.refresh()
                // Build 7 / item 7.1 — refresh the tile target bands alongside
                // the digest.
                async let targetsRefresh: Void = insightsTargets.refresh()
                async let score: Void = healthScore.refresh()
                async let measurements: Void = measurementsStore.load(force: true)
                async let briefing: Void = briefingStore.load()
                async let mood: Void = moodStore.load()
                // Web-parity `TodayHero` — the pull is an explicit refresh of the
                // daily-digest hero too.
                async let digest: Void = digestStore.refresh()
                // The pull is the explicit sync point. The sync
                // handshake (which flips the bottom caption to "Zuletzt
                // synchronisiert HH:MM" and drives the W-B184 checkmark) now
                // runs inside `hlPullToRefresh`, concurrently with this block.
                _ = await (
                    dashboard, layout, insightsRefresh, targetsRefresh, score,
                    measurements, briefing, mood, digest
                )
                await refreshTileStates()
            }
            // 1.7: switching back to Home holds a stale dose state neutral and
            // reloads it (the store throttles and joins a reload in flight).
            .onAppear { medicationsStore.refreshDoseStateIfStale() }
            .task {
                // Cold-launch parallel fan-out (F5/F6 v0.4.1).
                async let dashboard: () = (store.summary == nil ? store.load() : ())
                async let comprehensive: () = (insights.comprehensive == nil ? insights.load() : ())
                async let layout: () = layoutStore.load()
                async let healthScoreLoad: () = (healthScore.score == nil ? healthScore.load() : ())
                async let measurementsLoad: () = (measurementsStore.recent.isEmpty ? measurementsStore.load() : ())
                async let briefingLoad: () = (briefingStore.response == nil ? briefingStore.load() : ())
                // Mood + meds feed the Statistik-Mode floor.
                async let moodLoad: () = (moodStore.entries.isEmpty ? moodStore.load() : ())
                async let medsLoad: () = (medicationsStore.medications.isEmpty ? medicationsStore.load() : ())
                // Kick the live HK-direct
                // today-step read in parallel with the rest of cold-launch
                // so the Steps tile lands a fresh number first-paint
                // (TTL-gated so the call collapses to a no-op when the
                // store already has a recent value).
                async let liveTodayLoad: () = liveTodayStore.refreshIfStale()
                // Warm the Vorsorge tile's reminder list
                // (SWR-deduped, so the manage screen's own load collapses to a
                // no-op when it follows). Skipped when already hydrated.
                async let remindersLoad: () = (remindersStore.reminders.isEmpty ? remindersStore.load() : ())
                // Warm the rhythm-events store so the
                // Home front-door tile can gate on real data first-paint. Skipped
                // when already hydrated (SWR-deduped with the Insights overview's own load). The
                // gate is read on the MainActor BEFORE the `async let` so the
                // autoclosure doesn't capture the actor-isolated `response`.
                let warmRhythm = rhythmEventsStore.response == nil
                async let rhythmLoad: () = (warmRhythm ? rhythmEventsStore.load() : ())
                // Build 7 / item 7.1 — warm the tile target bands so the Zielband
                // paints first Home visit. Gate read on the MainActor BEFORE the
                // `async let` so the autoclosure doesn't capture the isolated
                // `response`. SWR-deduped, skipped when hydrated.
                let warmTargets = insightsTargets.response == nil
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
                // A pin/unpin (or any layout mutation, e.g. the
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
                // RootView now OWNS the foreground HK-stats sync +
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
            // Banner SLIDES in via `hlErrorBannerOverlay`, which
            // bakes in the `.animation(.easeInOut(0.3), value: store.error)`
            // driver that was missing here. Pre-fix the `ErrorBanner`
            // transition never played (no value-driver on the overlay), so the
            // banner popped in/out instantly on the primary entry screen.
            // The one surface of a Home failure; see `topBannerError`.
            .hlErrorBannerOverlay(error: topBannerError) {
                // Explicit user retry → force past the TTL, then re-derive the
                // per-kind tile states.
                Task {
                    await store.refresh(force: true)
                    await refreshTileStates()
                }
            }
            // v0.10 R5 — the always-on `slider.horizontal.3` customise button
            // is removed: the operator found it "fürchterlich" at the
            // dashboard top. Customisation stays reachable via Settings →
            // "Dashboard anpassen" (`SettingsDashboardScreen` → customizeRow)
            // and the all-tiles-hidden empty-state escape hatch below still
            // navigates to `DashboardCustomizationScreen` via `$showCustomize`.
            // The dashboard top is now clean (just the profile avatar).
            .navigationDestination(isPresented: $showCustomize) {
                DashboardCustomizationScreen()
            }
            // Direct front door to the Vorsorge manage
            // surface from the Home tile's card-body tap. Same destination the
            // deep path (More → Notifications → preventive card) reaches.
            .navigationDestination(isPresented: $showVorsorge) {
                MeasurementRemindersScreen()
            }
            // #186 — "Symptom erfassen" from the quick-actions card.
            .navigationDestination(isPresented: $showSymptomEntry) {
                SymptomQuickEntryPage()
            }
            // #191 QoL — "Symptom" from the capture picker lands here.
            .onChange(of: router.symptomQuickEntryRequestCount) {
                showSymptomEntry = true
            }
            .sheet(isPresented: $showIntakesSheet) {
                AnstehendeEinnahmenSheet()
            }
            // The Home-stack metric drill-down was RETIRED here.
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
            // Avatar moved INLINE into the greeting row (see
            // `Header(showProfile:)` below). The toolbar still owns the
            // `navigationDestination` push so the inline tap can flip
            // the binding and trigger the same `ProfileScreen` push that
            // the v0.5.4 NF-1 toolbar item previously fired.
            .dashboardProfileDestination(isPresented: $showProfile)
        }
        // Thread the user's display-unit prefs into the tile
        // subtree so every metric surface converts weight/BP/glucose at
        // display time without prop-drilling.
        .environment(\.unitPreferences, settings.unitPreferences)
    }

    // `emptyMetricsState` + `vorsorgeDue` +
    // `medicationsTileVisible` + `hasUserHiddenAllMetricTiles` moved off this
    // screen: the empty-state + ordering helpers now live in
    // `DashboardMetricOrdering` (called by `DashboardMetricsHost`), and the
    // Vorsorge gate lives in `DashboardVorsorgeHost`. `rhythmEventsSummary`
    // stays in `DashboardScreen+Ordering.swift` (still read by this body's
    // `RhythmEventsTile` placement).

    /// The head of Today's one column (named for the column; the presentation
    /// inventory keys its banner by this name): the Apple Health cards where
    /// the device reads Apple Health and the day's read with its hints.
    @ViewBuilder
    private var dayColumn: some View {
        // The connect banner and the one-time update notice (each with its
        // own rule) only where this device asks for Apple Health at all; on
        // the iPad they would be a call that leads nowhere.
        if TodayLayout.showsAppleHealthCards(deviceProfile) {
            HealthKitConnectBanner()
            HealthKitUpdateNoticeCard()
        }
        // #190: the relay's one-time card and its quiet lines.
        PushRelayDashboardSection()
        // The promoted day's read (`GET /api/daily/digest`); self-hides on
        // absent / gated-off / calm-degrade. The rail is the one due-surface.
        TodayHeroHost(
            onOpenVorsorge: { showVorsorge = true },
            onShowIntakes: { showIntakesSheet = true },
            isShortWindow: isShortWindow
        )
    }

    /// The day's cards after the hero: on the phone above the tiles, on a
    /// wide page under them.
    @ViewBuilder
    private var dayCards: some View {
        // Front door to the rhythm-events card, only when the wearable
        // flagged events.
        if let rhythmEventsSummary {
            RhythmEventsTile(summary: rhythmEventsSummary)
        }
        DashboardMetricsHost(
            part: .lead,
            matchedNamespace: matchedGeometryNamespace,
            zoomNamespace: dashboardNamespace,
            allowsMotion: !reduceMotion,
            onTap: openDetail,
            onShowIntakes: { showIntakesSheet = true },
            onShowCustomize: { showCustomize = true },
            onRequestCapture: { router.requestCapture() }
        )
    }

    /// Resolves the matched-geometry namespace
    /// forwarded into tiles + the drill-down payload. When the user has
    /// `Reduce Motion` enabled, returns `nil` so both the source tile and
    /// the destination hero fall through to their no-op branches in
    /// `View.matchedTileGeometry`. SwiftUI runs no implicit frame animation
    /// + the navigation push falls back to the default slide transition.
    private var matchedGeometryNamespace: Namespace.ID? {
        reduceMotion ? nil : dashboardNamespace
    }

    // The invisible GeometryReader/PreferenceKey
    // `parallaxProbe` was deleted; `onScrollGeometryChange` on the
    // ScrollView (see `body`) is the offset source now.

    private func openDetail(for kind: MetricKind) {
        // v0.14 audit #17 — open the tap-to-detail interval (≤ 200 ms p95). The
        // Insights metric page's first content paint closes it. Pure
        // measurement; no behaviour change.
        HLPerfSignpost.beginTapToDetail()
        // NAV UNIFICATION. The tile tap no longer pushes
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
// in `DashboardScreen+Sections.swift` to keep this file under the 600-line
// `file_length` swiftlint budget.

// `ComplianceRingCard` extracted to its own file so the
// per-snapshot subtitle helper doesn't push `DashboardScreen.swift` past
// the 600-line file-length lint baseline. See `ComplianceRingCard.swift`.

// `SkeletonContent` lives in `DashboardSkeleton.swift` (now backed by the
// design-system `HLSkeleton` primitive) to keep this file under the
// 600-line swiftlint `file_length` threshold.
