import SwiftUI

/// Apple-Health-Highlights-style Insights surface.
///
/// **Layout (v0.10.0 W-Insights, R2 §4 — the four-zone IA):**
/// 1. **Zone 1 — Hero:** ONE on-device "Today at a glance" briefing card with
///    loud provenance + whole-card tap → AskCoach.
/// 2. **Zone 2 — Dynamics:** alarming alerts + notable-trend chips (only when
///    present, OUT of the AI gate).
/// 3. **Zone 3 — Tiles:** the unified `HLMetricTile` grid + BMI + BP + mood +
///    long-tail; tap → chart, `✦` → per-tile AI explainer. Data-only.
/// 4. **Zone 4 — Go deeper:** Trends + Correlations footer links + data-quality
///    footnote.
///
/// **What v0.10.0 removed:** the duplicate Health Score (lives on Dashboard),
/// the second hero (`AskCoachHeroCard` body card → header coin + Hero tap), the
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
    // v0.5.4 BF-1 — mood + medication-compliance feed the Statistik-Mode
    // floor on the hero, matching Dashboard wiring.
    @Environment(MoodStore.self) private var moodStore
    @Environment(DashboardStore.self) private var dashboardStore
    /// v0.6.1.1 — backs the new `InsightsTargetTileGrid` (Gewicht, Ruhepuls,
    /// Mood, Mood-Stabilität, Compliance, Schritte). The store hits
    /// `GET /api/insights/targets`, which already powers the Ziele tab —
    /// reading it here costs no extra round-trip when the operator
    /// reaches Insights, the server-side 60s TTL absorbs the parallel use.
    @Environment(InsightsTargetsStore.self) private var insightsTargetsStore
    /// v0.12 W5b — RhythmEvents card + derived re-frames block (server-derived,
    /// paired-only; call sites gate on `backend.hasServer`, stores self-suppress).
    @Environment(RhythmEventsStore.self) private var rhythmEventsStore
    @Environment(DerivedInsightsStore.self) private var derivedInsightsStore
    /// v0.12 — discovered-correlations block (server-derived, operator-gated,
    /// self-suppressing). Gated on `backend.hasServer` like the other
    /// server-derived overview surfaces.
    @Environment(CorrelationsDiscoveryStore.self) private var correlationsDiscoveryStore
    /// v1.25 (GH iOS #38) — the clinical-signal awareness cards' store
    /// (health-status + breathing-screening on this overview; server-derived,
    /// paired-only, self-suppressing). Gated on `backend.hasServer` like the
    /// other server-derived overview surfaces.
    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    /// Backs the Tagesbriefing prose fallback (`generalHealthReportText`):
    /// `briefingStore.summary` is AI-provider-only, so a provider-less account —
    /// or one whose summary is still warming — falls back to the deterministic
    /// `.week`/`.month` period narrative. The self-loading "Zeitraum im Rückblick"
    /// card that used to warm this store was removed (v0.14.9), so BRIEFING-LOAD-
    /// FIX (v0.14.8) warms it explicitly on `.task` + scenePhase-active via
    /// `loadOverviewNarrative()`; the ref is also fanned into pull-to-refresh.
    @Environment(NarrativeStore.self) private var narrativeStore
    /// v0.8.0 W10 — server-first Insights tile layout (order + visibility).
    @Environment(InsightsLayoutStore.self) private var layoutStore
    /// v0.11 W3 — server-derived gate. The Insights screen is mostly on-device
    /// (the Daily-Briefing hero and the metric tiles are (A) — they survive in
    /// standalone via the W2 read-union). The **server-generated** layer —
    /// comprehensive digest alerts, the cross-metric Correlations subpage, and
    /// insight generate/feedback — has no on-device equivalent (it trains the
    /// server model), so in standalone those surfaces yield to a single calm
    /// `HLCloudDerivedPlaceholder` in Zone 4 rather than spinning. The on-device
    /// single-metric `TrendObservationsService` observations (the `✦` explainers)
    /// stay (A) visible. (§4 matrix: insight cards/correlations/comprehensive +
    /// generate/feedback = (B).)
    @Environment(BackendAvailability.self) private var backend
    @Environment(\.appContainer) private var appContainer
    /// POLISH-COACH (v0.5.5.6) — drives the `.coach` deep-link wake.
    @Environment(AppRouter.self) private var router
    /// W52-1 — reduce-motion-aware entrances: opacity-only, instant when reduced.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// BRIEFING-LOAD-FIX (v0.14.8) — re-trigger the Tagesbriefing narrative warm
    /// on app-foreground so a server warm that hadn't settled by the time
    /// Insights first appeared still resolves without a manual pull-to-refresh
    /// (mirrors `InsightsMetricScreen`'s `loadAssessment()` scenePhase idiom).
    @Environment(\.scenePhase) private var scenePhase
    /// W52-3 / Task #48 — the container's hide-on-scroll model; this overview
    /// reports its own inner-scroll offset up (see the reporter on the ScrollView).
    @Environment(InsightsStripVisibility.self) private var stripVisibility

    /// v0.8.7 W-NATIVE-REORDER — drives the push to the native
    /// `SettingsInsightsCustomizationScreen` (List + .onMove + visibility
    /// toggles). Replaces the removed in-grid jiggle edit mode + add sheet.
    @State private var showCustomize = false

    /// POLISH-COACH — AskCoachSheet flag. The single coach surface reached
    /// from Insights (header coin / hero tap / `.coach` deep-link / per-tile
    /// "Ask the coach").
    ///
    /// v0.11 IA (C5) — the rival `presentMiniCoach`/`MiniCoachSheet` entry was
    /// removed: it had a `.sheet` wired but no live trigger set it `true`, so it
    /// was a dead third coach surface. The MiniCoach on-device subsystem stays
    /// (it backs the SettingsAIScreen config toggle + onboarding) — only the
    /// duplicate Insights entry point is gone. AskCoach is the one coach surface.
    @State private var presentAskCoach: Bool = false

    /// v0.13 WP — tapped suggested-prompt chip, threaded into `AskCoachSheet(seed:)`
    /// to pre-fill the composer. `nil` for coin / hero-tap / deep-link; cleared on
    /// dismiss so a later blank entry isn't seeded.
    @State private var coachSeed: String?

    /// A360 H2 (v0156) — metric scope from the per-tile "Ask the coach about this"
    /// affordance, threaded into `AskCoachSheet(launchScope:)` so the first server
    /// turn narrows the snapshot to that metric. `nil` for the generic header/hero
    /// entries; cleared on dismiss alongside `coachSeed`.
    @State private var coachLaunchScope: CoachLaunchScope?

    /// v0.10.0 W-Insights (R2 Phase B) — the metric whose per-tile AI
    /// explainer sheet is presented (tap on a tile's `✦`). nil → no sheet.
    /// State lives here (not in the grid) so `HLMetricTile` stays a reusable,
    /// state-free primitive.
    @State private var aiExplainerMetric: AIExplainerMetric?

    /// W22-W22 #4 — the overview no longer owns a `NavigationStack`; the
    /// container hosts ONE shared stack (sticky strip → scroll-edge glass, no
    /// per-arm teardown on pill switch). The `.navigationDestination`/`.toolbar`/
    /// `.sheet` modifiers below resolve against that ancestor stack, unchanged.
    var body: some View {
        // v0.14.6 N6 — re-tapping the Insights tab scrolls the overview back to
        // the top. The container already resets the pager `selection` to
        // `.overview` on the root-request bump; here the overview ALSO snaps its
        // own inner scroll to the top so a re-tap returns to the very top, not
        // wherever the operator was scrolled.
        ScrollViewReader { proxy in
            scrollBody
                .onChange(of: router.insightsRootRequestCount) { _, _ in
                    if reduceMotion {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                    }
                }
        }
    }

    private static let topAnchorID = "insights.overview.top"

    private var scrollBody: some View {
        ScrollView {
            // v0.11 perf: LazyVStack so the long Insights card column
            // builds incrementally instead of all up-front — cuts the
            // cold-launch + scroll cost on this scroll surface.
            LazyVStack(alignment: .leading, spacing: HLSpace.lg) {
                // v0.14.6 N6 — zero-height top anchor for the re-tap reset.
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                // v0.6.1.8 Y7.1 — inline header (handbook §3.1 Flavour B). The
                // header's own `@Observable` reads (targets / feature-flags / AI
                // gates) live INSIDE `InsightsOverviewHeader` (W-PERF-INSIGHTS), so
                // they no longer invalidate this screen's body.
                InsightsOverviewHeader(
                    appContainer: appContainer,
                    onCustomize: { showCustomize = true },
                    onAskCoach: { presentAskCoach = true }
                )
                // v0.11 W35 — web-parity description line under the header,
                // mirroring `InsightsMetricScreen.descriptionSlot`. Self-
                // suppresses when the catalog key is absent/empty (echo test).
                overviewDescriptionSlot

                // W-PERF-INSIGHTS — the skeleton gate + the four-zone loaded
                // composition + the sync footer all live in `InsightsOverviewBody`,
                // which owns their store reads. A store mutation now invalidates the
                // affected leaf, not this scroll/sheet/toolbar scaffold.
                InsightsOverviewBody(
                    appContainer: appContainer,
                    onCustomize: { showCustomize = true },
                    onAskCoach: { presentAskCoach = true },
                    onSelectMetric: { kind in router.selectInsightsMetric(kind) },
                    onSelectMood: { router.selectInsightsSpecial(.mood) }
                )
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            // Native iOS-18 `TabView` already supplies the bottom inset;
            // the legacy 96pt was a pre-native-`TabView` leftover (M2-A2).
            .padding(.bottom, HLSpace.lg)
        }
        // W52-3 / Task #48 — report this overview's own inner scroll offset for
        // hide-on-scroll (not the horizontal pager → no W44 vertical coupling).
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility.report(offset: newOffset)
        }
        .hlScreenBackground()
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so content blurs into
        // the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic). The sync handshake that drives the checkmark + the
        // bottom caption now runs inside the modifier (concurrently with this
        // fan-out), so it is dropped from the block below.
        .hlPullToRefresh {
            // v0.5.5.1 — explicit "every read-through store this view
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
            //                                  + PerKindInsightsBlock
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
            // W8-B1 — pull-to-refresh force-revalidates the hot keys
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
            // v0.8.0 W10 — keep the server-first tile layout in sync.
            async let layout: Void = layoutStore.refresh()
            // W5b — server-derived overview surfaces (paired-only).
            async let rhythm: Void = backend.hasServer ? rhythmEventsStore.refresh() : ()
            async let derived: Void = backend.hasServer ? derivedInsightsStore.refresh() : ()
            // v0.12 — discovered-correlations block (operator-gated; refresh
            // reflects a surface that turned OFF, not just a stale snapshot).
            async let correlations: Void = backend.hasServer ? correlationsDiscoveryStore.refresh() : ()
            // v1.25 — revalidate the clinical-signal awareness cards.
            async let clinicalSignals: Void = backend.hasServer ? clinicalSignalsStore.refresh() : ()
            // I-3 ITEM 5 — revalidate the touched retrospective period(s) too.
            let narrativeLocale = Locale.current.language.languageCode?.identifier == "en" ? "en" : "de"
            async let narrative: Void = backend.hasServer
                ? narrativeStore.refresh(locale: narrativeLocale)
                : ()
            // v0.14.1 — the sync handshake that makes the bottom caption's
            // "Zuletzt synchronisiert HH:MM" authoritative (and drives the
            // W-B184 checkmark) now runs inside `hlPullToRefresh`.
            _ = await (
                comprehensive, briefing, healthScore, measurements, availability,
                mood, dashboard, targets, layout, rhythm, derived, correlations,
                clinicalSignals, narrative
            )
        }
        .task {
            // v0.5.5.1 — cold-launch fan-out parallelised across every
            // store the view depends on. See the doc-block in
            // `refreshable` above for the canonical dependency list;
            // this block mirrors it but only hits the network when the
            // store carries no data yet (tab-switch back to Insights
            // does not refetch when warm).
            async let comprehensiveLoad: Void = store.comprehensive == nil ? store.load() : ()
            async let healthScoreLoad: Void = healthScoreStore.score == nil ? healthScoreStore.load() : ()
            // v0.9.0 W2 — the on-device briefing hero's server-fallback
            // arm reads `briefingStore.briefing`; cold-warm it here so a
            // tab-switch into Insights resolves the server arm without
            // waiting for a pull-to-refresh. Skipped when already warm.
            async let briefingLoad: Void = briefingStore.briefing == nil ? briefingStore.load() : ()
            // DASHBOARD-BUG-FIX-2 — keep briefing/trend input warm.
            async let measurementsLoad: Void = measurementsStore.recent.isEmpty ? measurementsStore.load() : ()
            // v0.5.4 BF-1 — mood + dashboard-summary needed for the
            // Statistik-Mode floor.
            async let moodLoad: Void = moodStore.entries.isEmpty ? moodStore.load() : ()
            async let dashboardLoad: Void = dashboardStore.summary == nil ? dashboardStore.load() : ()
            async let targetsLoad: Void = insightsTargetsStore.response == nil
                ? insightsTargetsStore.load()
                : ()
            // v0.8.0 W10 — hydrate the server-first layout (instant-paint
            // cache already painted the operator's order on first frame).
            async let layoutLoad: Void = layoutStore.load()
            // W5b — cold-warm the server-derived surfaces (paired-only, daily SWR).
            let warmRhythm = backend.hasServer && rhythmEventsStore.response == nil
            let warmDerived = backend.hasServer && derivedInsightsStore.metrics.isEmpty
            let warmCorrelations = backend.hasServer && correlationsDiscoveryStore.response == nil
            async let rhythmLoad: Void = warmRhythm ? rhythmEventsStore.load() : ()
            async let derivedLoad: Void = warmDerived ? derivedInsightsStore.load() : ()
            async let correlationsLoad: Void = warmCorrelations ? correlationsDiscoveryStore.load() : ()
            // v1.25 — cold-warm the clinical-signal cards (paired-only, daily SWR).
            let warmClinicalSignals = backend.hasServer && !clinicalSignalsStore.hasSettledOnce
            async let clinicalSignalsLoad: Void = warmClinicalSignals ? clinicalSignalsStore.load() : ()
            // BRIEFING-LOAD-FIX (v0.14.8) — cold-warm the Tagesbriefing narrative
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
        // BRIEFING-LOAD-FIX (v0.14.8) — re-trigger the Tagesbriefing narrative
        // warm on app-foreground so a server warm that exceeded the bounded
        // in-session re-poll window (or that started while the screen was
        // backgrounded) still resolves without a manual pull. Cache-first +
        // idempotent (a settled period simply no-ops); standalone skips via
        // `hasServer`. Mirrors `InsightsMetricScreen.loadAssessment` on `.active`.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadOverviewNarrative() }
        }
        // POLISH-COACH (v0.5.5.6) — `.large`-detent placeholder.
        // v0.5.7 wires the generative back-end (see AskCoachSheet).
        .sheet(isPresented: $presentAskCoach, onDismiss: {
            coachSeed = nil
            coachLaunchScope = nil
        }, content: {
            AskCoachSheet(seed: coachSeed, launchScope: coachLaunchScope)
        })
        // v0.10.0 W-Insights (R2 Phase B) — per-tile on-device AI explainer.
        // Presented when the operator taps a tile's `✦`. Wraps the existing
        // `TrendObservationsService` output as a `.medium` sheet; "Ask the
        // coach about this" pulses the AskCoach surface.
        .sheet(item: $aiExplainerMetric) { selected in
            MetricAIExplainerSheet(
                metric: selected.kind,
                locale: .current,
                service: appContainer?.trendObservationsService ?? TrendObservationsService(),
                onAskCoach: {
                    // A360 H2 — hand the tile's metric to the Coach: a localized
                    // opener (composer seed) + the wire scope so the snapshot
                    // narrows to this metric instead of opening blank.
                    coachSeed = AskCoachSheet.metricSeed(for: selected.kind)
                    coachLaunchScope = selected.kind.coachScopeSource.map { CoachLaunchScope(metric: $0) }
                    presentAskCoach = true
                }
            )
        }
        // POLISH-COACH (v0.5.5.6) — `.coach` deep-link wakeup. The
        // router pulses `askCoachRequestCount`; we surface the sheet.
        .onChange(of: router.askCoachRequestCount) { _, _ in
            // Task #53 — a Coach deep-link opens whenever an assistant is
            // chosen (on-device or online); `.none` ignores it.
            if aiSurfacesVisible { presentAskCoach = true }
        }
        // v0.8.7 W-NATIVE-REORDER — the custom in-grid jiggle edit mode
        // (scrim + floating Done pill + add-tile sheet) is gone. Reorder /
        // add / remove all live in the native `SettingsInsightsCustomization
        // Screen`, pushed from here.
        .navigationDestination(isPresented: $showCustomize) {
            SettingsInsightsCustomizationScreen()
        }
        // v0.14.3 E4 — the legacy `.navigationDestination(item: $trendChartMetric)`
        // dead-end push (a bare `InsightsMetricScreen` on this screen's local
        // stack — no tab strip, no swipe, back only via Insights) is GONE. Every
        // overview entry point (Trends row, wellness contributors, Home tile)
        // now routes through `router.selectInsightsMetric`, which resolves the
        // slug onto `InsightsContainerScreen`'s navigable pager.
    }

    /// Task #53 — true when ANY assistant surface should be visible: the user
    /// chose `.onDevice` / `.online`, OR (v0151 ON-DEVICE-REACH) the
    /// privacy-first `.none` user's iPhone can answer privately on-device (iOS 26
    /// + Apple Intelligence ready) — surfacing the private coach + briefing with
    /// no external-AI consent. The briefing hero degrades cleanly per arm; reading
    /// `onDeviceAICapable` tracks `LocalLLMService`'s `@Observable` availability so
    /// the surfaces appear live when Apple Intelligence becomes ready.
    private var aiSurfacesVisible: Bool {
        guard let container = appContainer else { return false }
        return container.aiMode != .none || container.onDeviceAICapable
    }

    /// BRIEFING-LOAD-FIX (v0.14.8) — warms the `.week` narrative that backs the
    /// Tagesbriefing prose fallback. Server-derived → paired only (the route
    /// 403s in standalone; gate here avoids a doomed round-trip).
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
        guard backend.hasServer else { return }
        let locale = Locale.current.language.languageCode?.identifier == "en" ? "en" : "de"
        let needsCorrectiveRetry = narrativeStore.hasSettled(.week)
            && narrativeStore.narrative(for: .week) == nil
        await narrativeStore.load(period: .week, locale: locale, force: needsCorrectiveRetry)
    }

    // MARK: - Overview description slot (web copy — self-suppresses)

    /// Renders the static overview explainer paragraph under the header,
    /// mirroring `InsightsMetricScreen.descriptionSlot`. Self-suppresses when
    /// `insights.overview.description` is absent (echo test) or empty. (v0.11 W35
    /// moved `bpTile`/`hasBPSignal` to `InsightsMetricScreen`.)
    @ViewBuilder
    private var overviewDescriptionSlot: some View {
        if let resolved = overviewDescriptionText, !resolved.isEmpty {
            Text(resolved)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("insights.overview.description")
        }
    }

    /// The overview description copy. A missing catalog entry resolves to the
    /// key verbatim → suppress. INVARIANT: `insights.overview.description` MUST
    /// carry plain copy (no `%@`) in BOTH EN+DE — see
    /// `InsightsMetricScreen.descriptionText`.
    private var overviewDescriptionText: String? {
        let key = "insights.overview.description"
        let resolved = String(localized: String.LocalizationValue(key))
        return resolved == key ? nil : resolved
    }
}

// W52 extractions (kept this file under the length cap after the inline Vitals
// block landed): `tileGridCoveredKinds(_:)` → `Sub/InsightsScreen+Helpers.swift`
// (the `hasCorrelationSignal(_:)` gate retired in I-1 D when the correlation
// cards were relocated to the per-metric pages); `AIExplainerMetric` →
// `Sub/AIExplainerMetric.swift`.
// `InsightsBriefingHero` (the on-device Daily-Briefing wrapper, v0.9.0 W2) lives
// in `Sub/InsightsBriefingHero.swift` (extracted v0.11 W-C to cap this file).
