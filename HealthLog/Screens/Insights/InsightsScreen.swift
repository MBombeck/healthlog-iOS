import SwiftUI

/// Apple-Health-Highlights-style Insights surface.
///
/// **Layout (v0.10.0 W-Insights, R2 §4 — the four-zone IA):**
/// 1. **Zone 1 — Hero:** ONE on-device "Today at a glance" briefing card with
///    loud provenance + whole-card tap → AskCoach.
/// 2. **Zone 2 — Dynamics:** alarming alerts + notable-trend chips (only when
///    present, OUT of the AI gate).
/// 3. **Zone 3 — Tiles:** the customizable overview sections (vitals, BMI, BP,
///    mood, …); tap → chart. Data-only. (The `HLMetricTile` target grid, the
///    long-tail block and the per-tile `✦` explainer they fed were never mounted
///    after the redesign and were deleted in #115 B7.)
/// 4. **Zone 4 — Go deeper:** Trends + Correlations footer links + data-quality
///    footnote.
///
/// **What v0.10.0 removed:** the second hero (`AskCoachHeroCard` body card → header coin + Hero tap), the
/// always-on `SummaryCard`, the inline `TrendObservationCard` AI wall, and the
/// `FeatureDisabledCard` placeholder (data-only doctrine).
///
/// **Apple-Health pattern:** each section renders only when its data is present;
/// empty-states are humane, never "0 entries"; one scrollable column.
struct InsightsScreen: View {
    @Environment(InsightsStore.self) private var store
    @Environment(DailyBriefingStore.self) private var briefingStore
    @Environment(HealthScoreStore.self) private var healthScoreStore
    @Environment(MeasurementsStore.self) private var measurementsStore
    // Mood + medication-compliance feed the Statistik-Mode
    // floor on the hero, matching Dashboard wiring.
    @Environment(MoodStore.self) private var moodStore
    @Environment(DashboardStore.self) private var dashboardStore
    /// Personal targets (Gewicht, Ruhepuls, Mood, Mood-Stabilität,
    /// Compliance, Schritte), warmed here for the metric pages. The store hits
    /// `GET /api/insights/targets`, which already powers the Ziele tab —
    /// reading it here costs no extra round-trip when the operator
    /// reaches Insights, the server-side 60s TTL absorbs the parallel use.
    @Environment(InsightsTargetsStore.self) private var insightsTargetsStore
    /// RhythmEvents card + derived re-frames block (server-derived,
    /// stores self-suppress).
    @Environment(RhythmEventsStore.self) private var rhythmEventsStore
    @Environment(DerivedInsightsStore.self) private var derivedInsightsStore
    /// Discovered-correlations block (server-derived, operator-gated,
    /// self-suppressing).
    @Environment(CorrelationsDiscoveryStore.self) private var correlationsDiscoveryStore
    /// v1.25 — the clinical-signal awareness cards' store
    /// (health-status + breathing-screening on this overview; server-derived,
    /// self-suppressing).
    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    /// Backs the Tagesbriefing prose fallback (`generalHealthReportText`):
    /// `briefingStore.summary` is AI-provider-only, so a provider-less account —
    /// or one whose summary is still warming — falls back to the deterministic
    /// `.week`/`.month` period narrative. The self-loading "Zeitraum im Rückblick"
    /// card that used to warm this store was removed, so BRIEFING-LOAD-
    /// FIX warms it explicitly on `.task` + scenePhase-active via
    /// `loadOverviewNarrative()`; the ref is also fanned into pull-to-refresh.
    @Environment(NarrativeStore.self) private var narrativeStore
    /// Server-first Insights tile layout (order + visibility).
    @Environment(InsightsLayoutStore.self) private var layoutStore
    @Environment(\.appContainer) private var appContainer
    /// Drives the `.coach` deep-link wake.
    @Environment(AppRouter.self) private var router
    /// Reduce-motion-aware entrances: opacity-only, instant when reduced.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Re-trigger the Tagesbriefing narrative warm
    /// on app-foreground so a server warm that hadn't settled by the time
    /// Insights first appeared still resolves without a manual pull-to-refresh
    /// (mirrors `InsightsMetricScreen`'s `loadAssessment()` scenePhase idiom).
    @Environment(\.scenePhase) private var scenePhase

    /// Drives the push to the native
    /// `SettingsInsightsCustomizationScreen` (List + .onMove + visibility
    /// toggles). Replaces the removed in-grid jiggle edit mode + add sheet.
    @State private var showCustomize = false

    /// AskCoachSheet flag. The single coach surface reached
    /// from Insights (header coin / hero tap / `.coach` deep-link / per-tile
    /// "Ask the coach").
    ///
    /// The rival `presentMiniCoach`/`MiniCoachSheet` entry was
    /// removed: it had a `.sheet` wired but no live trigger set it `true`, so it
    /// was a dead third coach surface. The MiniCoach on-device subsystem stays
    /// (it backs the SettingsAIScreen config toggle + onboarding) — only the
    /// duplicate Insights entry point is gone. AskCoach is the one coach surface.
    @State private var presentAskCoach: Bool = false
    /// The coach sheet grows out of the coach button in the bar.
    @Namespace private var coachZoom

    /// Tapped suggested-prompt chip, threaded into `AskCoachSheet(seed:)`
    /// to pre-fill the composer. `nil` for coin / hero-tap / deep-link; cleared on
    /// dismiss so a later blank entry isn't seeded.
    @State private var coachSeed: String?

    /// Metric scope from the per-tile "Ask the coach about this"
    /// affordance, threaded into `AskCoachSheet(launchScope:)` so the first server
    /// turn narrows the snapshot to that metric. `nil` for the generic header/hero
    /// entries; cleared on dismiss alongside `coachSeed`.
    @State private var coachLaunchScope: CoachLaunchScope?

    /// The overview no longer owns a `NavigationStack`; the
    /// container hosts ONE shared stack (no per-arm teardown on pill switch). The `.navigationDestination`/`.toolbar`/
    /// `.sheet` modifiers below resolve against that ancestor stack, unchanged.
    var body: some View {
        // Re-tapping the Insights tab scrolls the overview back to
        // the top. The container already resets the pager `selection` to
        // `.overview` on the root-request bump; here the overview ALSO snaps its
        // own inner scroll to the top so a re-tap returns to the very top, not
        // wherever the operator was scrolled.
        scrollBody
            // In the pager the head stands fixed at the top, over the strip.
            .insightsPageHead(enabled: inPager) {
                // The coach sheet grows out of the coach button here too.
                overviewHeader.environment(\.hlActionZoomNamespace, coachZoom)
            }
            .onChange(of: router.insightsRootRequestCount) { _, _ in
                if reduceMotion {
                    scrollPosition.scrollTo(edge: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollPosition.scrollTo(edge: .top)
                    }
                }
            }
    }

    /// The page's own scroll position; a reset goes to the very top of the
    /// page, the page's top room above the head included.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// In the Insights pager the head is pinned above the strip.
    @Environment(\.insightsInPager) private var inPager

    private var overviewHeader: some View {
        InsightsOverviewHeader(
            appContainer: appContainer,
            onCustomize: { showCustomize = true },
            onAskCoach: { presentAskCoach = true }
        )
    }

    private var scrollBody: some View {
        // The page's stack is eager: the LazyVStack (v0.11 perf) kept
        // re-phasing its items while a scroll ran into sections that load
        // themselves and change height, and under XCUITest the main thread
        // stayed in `LazyLayoutViewCache.updateItemPhases` for over 30 s.
        HLPage {
            // The header's own `@Observable` reads (targets / feature-flags /
            // AI gates) live INSIDE `InsightsOverviewHeader`, so they do not
            // invalidate this screen's body.
            if !inPager {
                overviewHeader
            }

            // The skeleton gate + the four-zone loaded composition + the sync
            // footer all live in `InsightsOverviewBody`, which owns their store
            // reads. A store mutation invalidates the affected leaf, not this
            // scroll/sheet/toolbar scaffold.
            InsightsOverviewBody(
                appContainer: appContainer,
                onCustomize: { showCustomize = true },
                onAskCoach: { presentAskCoach = true },
                onSelectMetric: { kind in router.selectInsightsMetric(kind) },
                onSelectMood: { router.selectInsightsSpecial(.mood) }
            )
            // The timeline goes onto the stack's own path, not through a
            // destination of this page (``InsightsRoute``).
            InsightsTimelineEntry {
                HLLog.ui.notice("Zeitleiste: Tipp in Insights")
                router.openTimelineFromInsights()
            }
        }
        .scrollPosition($scrollPosition)
        // The score rings move for a few seconds after the overview appears,
        // then rest.
        .insightsRingMotionWindow()
        // The bar stays like on every other tab: empty and inline, so the
        // title stands at the same height as theirs.
        .navigationBarTitleDisplayMode(.inline)
        // WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic). The sync handshake that drives the checkmark + the
        // bottom caption now runs inside the modifier (concurrently with this
        // fan-out), so it is dropped from the block below.
        .hlPullToRefresh {
            // Explicit "every read-through store this view
            // depends on" pull-to-refresh fan-out. Future maintainers:
            // if you add a card here that reads from a new store,
            // ADD ITS LOAD HERE TOO. Otherwise pull-to-refresh feels
            // half-broken (the new card stays stale while everything
            // else refreshes around it).
            //
            // Dependency chain:
            //   - `store.refresh()`          → ComprehensiveDigest + Recommendations
            //   - `briefingStore.load()`     → Daily Briefing summary
            //   - `healthScoreStore.refresh` → Health Score tile
            //   - `measurementsStore.load()` → TrendObservationCard
            //   - `measurementsStore.loadAvailability()`
            //                                → the per-kind has-data set the
            //                                  Insights TAB STRIP gates every
            //                                  metric pill on (22-01 / R4)
            //   - `moodStore.load()`         → Statistik-Mode floor on
            //                                  briefing-related cards
            //   - `dashboardStore.refresh()` → dashboard summary fed
            //                                  into Statistik-Mode floor
            //
            // DASHBOARD-BUG-FIX-2 (2026-05-16) → operator reported the
            // briefing rendering "(keine Messungen im Zeitfenster)"
            // even with plenty of data; root cause was a missing
            // `measurementsStore.load()` in this block.
            // Pull-to-refresh force-revalidates the hot keys
            // (dashboard + measurements) past their SWR TTL.
            //
            // 22-01 (R4) — `loadAvailability()` was omitted here, and the
            // omission is the whole of "pull to refresh does nothing" on this
            // surface: the read had exactly ONE call site (the container's
            // `.task`), so a read that lost its race was never re-driven and
            // the strip stayed short for the rest of the session. The block's
            // own rule three comments up said to add it; this is that.
            async let comprehensive: Void = store.refresh()
            async let briefing: Void = briefingStore.load()
            async let healthScore: Void = healthScoreStore.refresh()
            async let measurements: Void = measurementsStore.load(force: true)
            async let availability: Bool = measurementsStore.loadAvailability()
            async let mood: Void = moodStore.load()
            async let dashboard: Void = dashboardStore.refresh(force: true)
            async let targets: Void = insightsTargetsStore.refresh()
            // Keep the server-first tile layout in sync.
            async let layout: Void = layoutStore.refresh()
            // Server-derived overview surfaces.
            async let rhythm: Void = rhythmEventsStore.refresh()
            async let derived: Void = derivedInsightsStore.refresh()
            // Discovered-correlations block (operator-gated; refresh
            // reflects a surface that turned OFF, not just a stale snapshot).
            async let correlations: Void = correlationsDiscoveryStore.refresh()
            // v1.25 — revalidate the clinical-signal awareness cards.
            async let clinicalSignals: Void = clinicalSignalsStore.refresh()
            // I-3 ITEM 5 — revalidate the touched retrospective period(s) too.
            let narrativeLocale = AppLanguage.current.serverCode
            async let narrative: Void = narrativeStore.refresh(locale: narrativeLocale)
            // The sync handshake that makes the bottom caption's
            // "Zuletzt synchronisiert HH:MM" authoritative (and drives the
            // W-B184 checkmark) now runs inside `hlPullToRefresh`.
            _ = await (
                comprehensive, briefing, healthScore, measurements, availability,
                mood, dashboard, targets, layout, rhythm, derived, correlations,
                clinicalSignals, narrative
            )
        }
        .task {
            // Cold-launch fan-out parallelised across every
            // store the view depends on. See the doc-block in
            // `refreshable` above for the canonical dependency list;
            // this block mirrors it but only hits the network when the
            // store carries no data yet (tab-switch back to Insights
            // does not refetch when warm).
            async let comprehensiveLoad: Void = store.comprehensive == nil ? store.load() : ()
            async let healthScoreLoad: Void = healthScoreStore.score == nil ? healthScoreStore.load() : ()
            // The on-device briefing hero's server-fallback
            // arm reads `briefingStore.briefing`; cold-warm it here so a
            // tab-switch into Insights resolves the server arm without
            // waiting for a pull-to-refresh. Skipped when already warm.
            async let briefingLoad: Void = briefingStore.briefing == nil ? briefingStore.load() : ()
            // Keep briefing/trend input warm.
            async let measurementsLoad: Void = measurementsStore.recent.isEmpty ? measurementsStore.load() : ()
            // Mood + dashboard-summary needed for the
            // Statistik-Mode floor.
            async let moodLoad: Void = moodStore.entries.isEmpty ? moodStore.load() : ()
            async let dashboardLoad: Void = dashboardStore.summary == nil ? dashboardStore.load() : ()
            async let targetsLoad: Void = insightsTargetsStore.response == nil
                ? insightsTargetsStore.load()
                : ()
            // Hydrate the server-first layout (instant-paint
            // cache already painted the operator's order on first frame).
            async let layoutLoad: Void = layoutStore.load()
            // Cold-warm the server-derived surfaces (daily SWR).
            let warmRhythm = rhythmEventsStore.response == nil
            let warmDerived = derivedInsightsStore.metrics.isEmpty
            let warmCorrelations = correlationsDiscoveryStore.response == nil
            async let rhythmLoad: Void = warmRhythm ? rhythmEventsStore.load() : ()
            async let derivedLoad: Void = warmDerived ? derivedInsightsStore.load() : ()
            async let correlationsLoad: Void = warmCorrelations ? correlationsDiscoveryStore.load() : ()
            // v1.25 — cold-warm the clinical-signal cards (daily SWR).
            let warmClinicalSignals = !clinicalSignalsStore.hasSettledOnce
            async let clinicalSignalsLoad: Void = warmClinicalSignals ? clinicalSignalsStore.load() : ()
            // Cold-warm the Tagesbriefing narrative
            // fallback on first appear. `generalHealthReportText` falls back from
            // `briefingStore.summary` (AI-provider-only) to the deterministic
            // period NARRATIVE — but nothing loaded `narrativeStore` on appear
            // (the self-loading "Zeitraum im Rückblick" card that used to warm it
            // was removed in v0.14.9), so the slot stayed empty until a manual
            // pull. `load(period:)` is lazy (skips when settled) and carries the
            // bounded warm re-poll for the "still generating" case.
            async let narrativeLoad: Void = loadOverviewNarrative()
            _ = await (
                comprehensiveLoad,
                healthScoreLoad,
                briefingLoad,
                measurementsLoad,
                moodLoad,
                dashboardLoad,
                targetsLoad,
                layoutLoad,
                rhythmLoad,
                derivedLoad,
                correlationsLoad,
                clinicalSignalsLoad,
                narrativeLoad
            )
        }
        // Re-trigger the Tagesbriefing narrative
        // warm on app-foreground so a server warm that exceeded the bounded
        // in-session re-poll window (or that started while the screen was
        // backgrounded) still resolves without a manual pull. Cache-first +
        // idempotent (a settled period simply no-ops). Mirrors `InsightsMetricScreen.loadAssessment` on `.active`.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadOverviewNarrative() }
        }
        // `.large`-detent placeholder.
        // v0.5.7 wires the generative back-end (see AskCoachSheet).
        .sheet(isPresented: $presentAskCoach, onDismiss: {
            coachSeed = nil
            coachLaunchScope = nil
        }, content: {
            AskCoachSheet(seed: coachSeed, launchScope: coachLaunchScope)
                .hlZoomTransition(from: HLTabHeaderAction.Role.coach, in: coachZoom)
        })
        .environment(\.hlActionZoomNamespace, coachZoom)
        // `.coach` deep-link wakeup. The
        // router pulses `askCoachRequestCount`; we surface the sheet.
        .onChange(of: router.askCoachRequestCount) { _, _ in
            // A Coach deep-link opens whenever an assistant is
            // chosen (on-device or online); `.none` ignores it.
            if aiSurfacesVisible { presentAskCoach = true }
        }
        // The custom in-grid jiggle edit mode
        // (scrim + floating Done pill + add-tile sheet) is gone. Reorder /
        // add / remove all live in the native `SettingsInsightsCustomization
        // Screen`, pushed from here.
        .navigationDestination(isPresented: $showCustomize) {
            SettingsInsightsCustomizationScreen()
        }
        // The legacy `.navigationDestination(item: $trendChartMetric)`
        // dead-end push (a bare `InsightsMetricScreen` on this screen's local
        // stack — no tab strip, no swipe, back only via Insights) is GONE. Every
        // overview entry point (Trends row, wellness contributors, Home tile)
        // now routes through `router.selectInsightsMetric`, which resolves the
        // slug onto `InsightsContainerScreen`'s navigable pager.
    }

    /// True when ANY assistant surface should be visible: the user
    /// chose `.onDevice` / `.online`, OR the
    /// privacy-first `.none` user's iPhone can answer privately on-device (iOS 26
    /// + Apple Intelligence ready) — surfacing the private coach + briefing with
    /// no external-AI consent. The briefing hero degrades cleanly per arm; reading
    /// `onDeviceAICapable` tracks `LocalLLMService`'s `@Observable` availability so
    /// the surfaces appear live when Apple Intelligence becomes ready.
    private var aiSurfacesVisible: Bool {
        guard let container = appContainer else { return false }
        // And the server's `coach` capability offers an entry.
        return (container.aiMode != .none || container.onDeviceAICapable) && container.offersCoach
    }

    /// Warms the `.week` narrative that backs the
    /// Tagesbriefing prose fallback.
    ///
    /// - On first appear / a still-empty period: lazy `load` (skips when already
    ///   settled with content; carries `NarrativeStore`'s bounded warm re-poll
    ///   for the "server still generating" case).
    /// - On a settled-but-empty period (e.g. the in-session re-poll cap was hit
    ///   before the server warm finished): force one corrective re-fetch so a
    ///   later foreground recovers it — `NarrativeStore` re-arms its own bounded
    ///   re-poll from there. Battery-safe: at most one forced fetch per
    ///   foreground, and only while the prose is still absent.
    @MainActor
    private func loadOverviewNarrative() async {
        let locale = AppLanguage.current.serverCode
        let needsCorrectiveRetry = narrativeStore.hasSettled(.week)
            && narrativeStore.narrative(for: .week) == nil
        await narrativeStore.load(period: .week, locale: locale, force: needsCorrectiveRetry)
    }
}
