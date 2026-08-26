import SwiftUI

/// v0.11 W22-W2 / I-1 / v0.14.3 C — the **canonical per-metric Insights page**.
/// The single screen behind every charted metric, standardised to ONE card stack
/// (Blutdruck reference), top→bottom:
///
///   1. **Heading** — metric title + gear (editable target) + `✦` Coach.
///   2. **Description** — the static web explainer copy (`descriptionSlot`).
///      **Self-suppresses** when absent.
///   3. **Letzte Messung** — a dedicated "Letzte Messung" heading above the
///      EXISTING `HeroStrip` tile (latest value + unit + delta chip, weekday +
///      day + time, and the server 7/30/90-day trend slopes), DIRECTLY under the
///      intro (v0.14.3 C1). v0.14.1 §5 retired the bespoke
///      `InsightsLastMeasurementCard` — the canonical template reuses the
///      HeroStrip + adds only the heading (`lastMeasurementBlock`).
///   4. **30 Tage Durchschnitt** — a "30-day average" section heading above the
///      ONE canonical `InsightsMetricStatusCard` (`statusBlock`), used by EVERY
///      metric (BP, Puls, Gewicht, BMI, Ruhepuls, …). v0.14.3 C4 collapsed the
///      old `kind == .bloodPressure` fork (rich `BPStatusCard` vs thin
///      `InsightsPrimaryTile`) into this single primitive: assessment chip
///      top-right, 30-day-average headline, "Im Zielbereich" bar, Zielband —
///      each slot honest-only (self-suppresses without server signal).
///   5. **Einschätzung / Assessment** — `AssessmentCard`, after the 30-day card,
///      BEFORE the stat tiles + chart. The prose reads in the grey flowing intro
///      voice (`HLText.secondary`), not a white block.
///   6. **StatStrip** — Min/Ø/Max/Median (`StatsRow`).
///   7. **Chart** — the reused `ChartCard` block, composed from the SHARED
///      `ChartDetailComponents` primitives — NOT duplicated.
///   8. **Zusammenhänge / Correlation** — the cross-metric combo this metric
///      owns (`correlationBlock`), relocated off the overview (I-1 D), rendered
///      v0.14.1 §5 as grey flowing prose + inline scatter (no loud card).
///
/// **I-1 C:** the legacy duplicate "Zielbereich" card
/// (`InsightsTargetReferencePanel`) was removed from this stack — its range +
/// 30-day avg now live in the primary tile, and the editable band stays
/// reachable via the header gear. (The panel itself survives, still rendered by
/// the legacy `ChartDetailScreen`.)
///
/// **Adaptive (doctrine §6):** every block self-suppresses when its data is
/// absent, so a sparse metric reads as a clean heading + chart, not a wall of
/// empty sections.
///
/// **W2 scope:** reachable ONLY via the Insights tab strip (the W1
/// `InsightsContainerScreen` `.metric` arm now routes here). The global cutover
/// that retires `ChartDetailScreen` from Dashboard / tiles / BMIDetail is W4 —
/// this screen is additive so the operator can walk it first.
struct InsightsMetricScreen: View {
    let kind: MetricKind

    /// Splitting note: the section blocks + target-band helpers live in
    /// `InsightsMetricScreen+Sections.swift` (file_length split, pure code
    /// movement). Members below that are internal instead of `private` are
    /// accessed from that sibling extension file.
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(InsightsTargetsStore.self) var insightsTargetsStore
    /// v0.11 W35 — the BP rich status card (`BPStatusCard`) was relocated here
    /// off the Insights overview. It reads the server `comprehensive` digest
    /// (BP classification / 30-day avg / % in target / band), so the BP metric
    /// page needs the `InsightsStore`. Injected at the app root, available on
    /// every pushed Insights screen.
    @Environment(InsightsStore.self) var insightsStore
    @Environment(BackendAvailability.self) var backend
    /// P8 (v0141 parity) — the ECG recording list. Drives the pulse page's
    /// data-gated cross-link into the ECG surface (`ecgCrossLinkRow`); app-root
    /// injected, so it resolves on the drill-down path too.
    @Environment(EcgStore.self) var ecgStore
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) var appContainer
    /// v0.14.1 — re-trigger the assessment warm-poll on app-foreground. The
    /// per-metric assessment poll (`pollUntilReady`) is bounded (~48s); a server
    /// warm that takes longer than the poll window would otherwise leave the
    /// card empty until the operator manually re-enters the page. Re-running
    /// `loadAssessment()` on `.active` resolves a slow warm without a manual
    /// re-entry. Idempotent (cache-first; a ready card just re-paints).
    @Environment(\.scenePhase) private var scenePhase
    /// W52-3 / Task #48 — the container's hide-on-scroll model. When this screen
    /// renders INSIDE the Insights pager (`InsightsContainerScreen`) the container
    /// injects it, and this page reports its OWN inner-scroll offset up so the
    /// sticky strip hides on scroll-down / reveals on scroll-up.
    ///
    /// **W36/#22 — OPTIONAL.** Since the v0.11 chart-detail cutover this same
    /// screen is ALSO the canonical Dashboard / Insights-tile drill-down
    /// destination. Those surfaces push it from a stack with NO Insights tab
    /// strip, so the model is absent there — read as OPTIONAL: when present
    /// (pager) the offset report drives the strip; when absent (drill-down) the
    /// report is a harmless no-op. The ONLY pager-coupled dependency; every other
    /// `@Environment` here is app-root injected, so one screen serves both.
    @Environment(InsightsStripVisibility.self) private var stripVisibility: InsightsStripVisibility?

    @State var store: ChartDetailStore
    /// v0.11 W46 — the per-metric assessment is fetched HERE (un-gated read)
    /// rather than read off `store.findings`. The web-mirror page must mirror
    /// the web exactly: show the assistant assessment whenever the user is
    /// online with a provider configured, regardless of the on-device
    /// AI-consent grant. `ChartDetailStore.findings` is gated behind that local
    /// consent grant (correct for the legacy `ChartDetailScreen` "Befunde"
    /// surface, which can trigger generation), which suppressed the BP
    /// assessment on this page even when the server had it (operator P1).
    /// `MetricInsightsRepository.fetchAssessment` skips the consent gate because
    /// the underlying GET is read-only and transmits no new health data — see
    /// its doc-comment. Hide/show gating is then carried purely by `hasServer`
    /// (standalone) + the server envelope's `hasProvider` (no provider).
    /// Internal (not `private`) so the assessment warm-poll in the
    /// `InsightsMetricScreen+Assessment.swift` extension can drive it.
    @State var assessment: MetricStatusDTO?
    @State var assessmentLoading = false
    /// QoS-3 (A360-4) — set when the assessment warm-poll exhausts its bounded
    /// window or stops on a transient error while still `preparing` (or the very
    /// first fetch fails before any envelope lands). Drives `AssessmentCard`'s
    /// terminal "couldn't load — pull to refresh" caption instead of leaving the
    /// indefinite "preparing" skeleton up with no recovery. Reset at the start of
    /// every `loadAssessment` so a pull-to-refresh / foreground retry clears it.
    /// Internal so the extension file can set it.
    @State var assessmentFailed = false
    @State var selectedDate: Date?
    @State var presentFullscreenChart = false
    /// v0152 C4 — drives the inline `AskCoachSheet` from the per-page coach button.
    /// The sheet routes to the correct arm per user — see the header in `+Sections`.
    @State var presentAskCoach = false
    /// A360 H2 (v0156) — a correlation card's pair-specific seed + scope override
    /// the page's metric handoff (`nil` → page metric). Reset on dismiss.
    @State var coachSeedOverride: String?
    @State var coachScopeOverride: CoachLaunchScope?
    /// W22-W22 (operator felt-refine #2) — the contextual target-band editor,
    /// now opened from a header gear button (next to the `✦`) instead of an
    /// in-card "Adjust target range" affordance.
    @State var presentTargetEditor = false
    /// v0.14.6 H4 — guards a single corrective targets reload per appearance
    /// when this targeted kind's band is missing from an already-warm response
    /// (so a partial/early warm can't leave Sleep — or any targeted page the
    /// user swiped to — without its Zielband).
    @State private var didRewarmTargets = false
    /// v0.14.6 N3 — gates the activation scroll-reset animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// W22-W2 — a distinct zoom namespace + id from `ChartDetailScreen` so the
    /// two screens' fullscreen covers never share a transition source.
    @Namespace var fullscreenZoomNamespace
    static let zoomSourceID = "insightsMetric.fullscreen.zoom"

    /// W36/#22 — the presenting screen's matched-geometry namespace, forwarded
    /// onto the `HeroStrip` number so the Dashboard tile→detail hero zoom keeps
    /// lifting the tile's value into this screen's hero (the SAME contract the
    /// legacy `ChartDetailScreen` honoured). `nil` for the Insights pager + tile
    /// surfaces (they never owned a hero matched-geometry), which falls through
    /// to the `HeroStrip` no-op branch — no implicit frame animation runs.
    let matchedNamespace: Namespace.ID?

    /// v0.14.6 N3 — `true` while this metric page is the pager's CURRENT page.
    /// The container flips it as the selection settles on a swipe/tap; the page
    /// scrolls itself back to the top whenever it (re)becomes active, so swiping
    /// into a metric card always starts at its top instead of inheriting a
    /// previously-scrolled offset (page-aliveness otherwise preserves scroll).
    /// Defaults to `true` so the standalone drill-down use keeps its scroll.
    private let isActivePage: Bool
    /// Q-insights-scroll — a per-tap counter the container bumps when the operator
    /// RE-TAPS the strip pill of this (already-active) page. Distinct from
    /// `isActivePage`: that flips on a swipe-in (→ INSTANT reset, so no animated
    /// vertical scroll races the horizontal paging deceleration), whereas a bump
    /// here is a deliberate "return to the top" gesture (→ a single clean
    /// `.easeInOut`, reduce-motion → instant). `0` for the standalone drill-down,
    /// where no strip exists to re-tap. Splitting the two signals is the fix for
    /// the "ruckeln hin und her" stutter: the swipe path no longer animates.
    private let retapSignal: Int
    /// v0.14.6 N3 — top anchor the activation reset scrolls to.
    private static let topAnchorID = "insightsMetric.top"

    init(
        kind: MetricKind,
        store: ChartDetailStore,
        matchedNamespace: Namespace.ID? = nil,
        isActivePage: Bool = true,
        retapSignal: Int = 0
    ) {
        self.kind = kind
        _store = State(initialValue: store)
        self.matchedNamespace = matchedNamespace
        self.isActivePage = isActivePage
        self.retapSignal = retapSignal
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollBody
                // v0.14.6 N3 / Q-insights-scroll — when this page (re)becomes the
                // pager's current page via a SWIPE, snap its own vertical scroll
                // back to the top so swiping into a metric card always starts at
                // its top (page-aliveness otherwise keeps the prior offset).
                //
                // CRITICAL (Q-insights-scroll fix): this reset is now ALWAYS
                // INSTANT (no `withAnimation`). The previous animated reset fired
                // here as `selection` settled mid-swipe, so a vertical
                // scroll-to-top animation ran WHILE the horizontal paging
                // deceleration was still in flight — the two animations fought and
                // the operator felt the "ruckeln hin und her" stutter. An instant
                // jump on the incoming page is invisible (the page isn't on-screen
                // yet / is just arriving) and never competes with the page snap.
                // No-op for the standalone drill-down (isActivePage defaults true
                // and never toggles).
                .onChange(of: isActivePage) { _, active in
                    guard active else { return }
                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
                // Q-insights-scroll — the DELIBERATE "re-tap the active pill to
                // return to the top" gesture. The container bumps `retapSignal`
                // only on a re-tap of this already-active page (never on a swipe,
                // never on a page-changing tap), so this is the ONLY place a
                // single clean animated scroll-to-top runs — it can never race the
                // pager because the page is already settled when a re-tap happens.
                // Reduce-motion → instant.
                .onChange(of: retapSignal) { _, _ in
                    guard isActivePage else { return }
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

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                // v0.14.6 N3 — zero-height top anchor for the activation reset.
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                // #33 — in-content header mirroring the Übersicht
                // (`InsightsScreen.insightsHeader`): metric title LEFT-aligned,
                // the two EQUAL-sized trailing circles (gear + `✦` Coach), and
                // the description BELOW. Replaces the prior nav-title +
                // differently-sized toolbar buttons the operator flagged.
                metricHeader
                descriptionSlot
                // v0.14.3 C1/C5 — canonical order: the **"Letzte Messung"** block
                // (heading + `HeroStrip` tile) sits DIRECTLY under the intro, above
                // the 30-day status card. Self-suppresses with no latest point.
                lastMeasurementBlock
                // v0.14.3 C4 — the ONE canonical **"30 Tage Durchschnitt"** status
                // card, used by EVERY metric (BP, Puls, Gewicht, BMI, Ruhepuls, …).
                // Replaces the old `kind == .bloodPressure` fork (rich BPStatusCard
                // vs thin InsightsPrimaryTile). A "30 Tage Durchschnitt" section
                // heading sits ABOVE the card (C2 removed the in-card avg hint).
                // Honest-only: every slot self-suppresses without server signal, so
                // a sparse metric reads as a clean reduced card.
                statusBlock
                // v1.18.6 parity — BP-only calm derived context (pulse pressure
                // + mean arterial pressure) from the latest reading, mirroring the
                // web BP sub-page caption that sits between the target summary and
                // the assessment. Self-suppresses for every non-BP metric.
                bpDerivedBlock
                // v0.14.1 (#135) — **Einschätzung** sits after the 30-day card,
                // BEFORE the Min/Ø/Max/Median tiles + the chart. New canonical
                // order: Header → Intro → Letzte Messung → 30 Tage Durchschnitt →
                // Einschätzung → Min/Ø/Max/Median → Chart → Zusammenhänge. The grey
                // flowing styling from FB5 (`AssessmentBody` → `HLText.secondary`)
                // is kept.
                //
                // I-1 C — the duplicate "Zielbereich" card
                // (`InsightsTargetReferencePanel`) was removed here: the target
                // range + 30-day avg now live in the primary tile / `BPStatusCard`
                // at the top, and the editable band stays reachable via the header
                // gear (`canEditTargetBand` → `presentTargetEditor`). No second
                // divergent "% in target" card.
                AssessmentCard(
                    assessment: assessment,
                    isLoading: assessmentLoading && assessment == nil,
                    // QoS-3 — terminal failure caption when the poll gave up
                    // while preparing (never while a fetch is still in flight).
                    failed: assessmentFailed && !assessmentLoading,
                    // W46 — this read path is NOT consent-gated (read-only GET,
                    // no new transmission). The consent CTA arm never fires
                    // here; gating is server-driven (`hasProvider`) + standalone
                    // (`hasServer`), matching the web exactly.
                    consentClosed: false,
                    hasServer: backend.hasServer,
                    onRequestConsent: { appContainer?.aiConsentStore.requestExplicitPrompt() },
                    onConnectServer: backend.hasServer ? nil : { authStore.beginServerPairing() }
                )
                // b146 M4 — suppress the Min/Ø/Max strip for event-count kinds
                // (falls / breathing-disturbances) where a sparse single point
                // makes Min == Ø == Max degenerate, matching the web sub-pages.
                if store.stats != nil, store.dataState.hasValue, !kind.suppressesAggregateStats {
                    if kind == .bloodPressure, store.diastolicStats != nil {
                        // I4 — BP carries two components. The server `SeriesStats`
                        // covers systolic only; diastolic is aggregated on-device
                        // (`diastolicStats`/`diastolicMedian`). Stack a labelled
                        // systolic row over a labelled diastolic row so the operator
                        // can tell them apart, matching the web BP sub-page.
                        let prefs = settingsStore.unitPreferences
                        VStack(alignment: .leading, spacing: HLSpace.sm) {
                            labelledStatsRow(
                                title: String(localized: "insights.bp.stats.systolic"),
                                stats: store.stats,
                                median: store.median,
                                units: prefs
                            )
                            labelledStatsRow(
                                title: String(localized: "insights.bp.stats.diastolic"),
                                stats: store.diastolicStats,
                                median: store.diastolicMedian,
                                units: prefs
                            )
                        }
                    } else {
                        // A360-5 C-1 — convert stats + flip the label to the
                        // user's chosen unit (kg→lb, mmHg→kPa); glucose stays on
                        // the server-converted series unit.
                        let prefs = settingsStore.unitPreferences
                        StatsRow(stats: store.stats, median: store.median, unit: store.displayUnit(units: prefs), kind: kind, units: prefs)
                    }
                }
                chartBlock
                // P7 (v0141 parity) — pulse-only: the intraday day curve sits
                // DIRECTLY under the range chart, exactly where the web pulse
                // page puts it (`pulse/page.tsx:163-166`), so the page narrows
                // from "the range" to "this day". Self-suppresses everywhere else.
                intradayPulseBlock
                // CU-30 (C5) — cumulative-metric pages only: today's running
                // total against the usual day AT THE SAME HOUR. Sits beside the
                // intraday curve for the same reason it does: the page narrows
                // from "the range" to "today so far". Self-suppresses on every
                // metric the server does not baseline.
                sameTimeBaselineBlock
                // #124 / W-SLEEP (v0.14.8) — sleep-only: the tappable row into
                // the hypnogram detail (stage bands over the night) sits
                // DIRECTLY under the chart so it is findable — it previously
                // hid below the Zusammenhänge prose near the page bottom and
                // the operator never discovered it. Self-suppresses for every
                // other metric. Defaults to the server's most-recent night.
                sleepHypnogramRow
                // parity 4.7 — the derived sleep block (debt / chronotype /
                // average + the multi-night stage composition). Directly under
                // the single-night entry so the page widens its span
                // downward: one night → recent nights → standing rhythm.
                // Self-suppresses for every non-sleep metric.
                sleepDerivedBlock
                rangeDeltaSlot
                // v0.14.1 §5 (canonical order 8) — **Zusammenhänge** under the
                // Einschätzung. The relocated cross-metric correlation pair(s)
                // this metric owns (BP, Puls, Gewicht here; Stimmung/Medikamente on
                // their special pages), now rendered as grey flowing prose + an
                // inline scatter (no loud card), matching the intro voice.
                correlationBlock
                // P8 (v0141 parity) — pulse-only: the cross-link into the ECG
                // recordings, mirroring the web pulse page's `EcgCrossLink`
                // slot (`pulse/page.tsx:182-186`). Un-mounts entirely without
                // recordings. Never shows the curve — only that recordings
                // exist and what the DEVICE last reported.
                ecgCrossLinkRow
                // W22-audit Finding #5 — the path to the raw readings. The web
                // sub-page ends in a "Show all readings" link; the iOS equivalent
                // is `DrillDownRow → MeasurementListScreen`, the SAME shared
                // component `ChartDetailScreen` renders (reused, not duplicated),
                // so after W4 retires that screen the drill-down does not vanish.
                // Count uses the SAME `recentInRange` page the list endpoint lands
                // on (web-parity with ChartDetailScreen). The provenance
                // `SourcesRow` ("Daten von Withings") was dropped here per
                // operator override — the per-metric page needs no sources card.
                // v0.14.4 D2 — flag the "data exists, just not in this period"
                // case so the row never reads "keine Daten" while the tap reveals
                // the full all-time list.
                DrillDownRow(
                    kind: kind,
                    count: store.recentInRange.count,
                    hasDataOutsideRange: store.dataState.isOutsideRange
                )
            }
            .padding(.horizontal, HLSpace.lg)
            // Operator felt-refine — "fünf Pixel mehr Platz von oben". No token
            // lands exactly +5pt above `HLSpace.lg` (16; `xl` is 20) → literal 5pt.
            .padding(.top, HLSpace.lg + 5)
            .padding(.bottom, HLSpace.xxxxl)
        }
        // W52-3 / Task #48 — report THIS metric page's own inner vertical scroll
        // offset up to the container's strip-visibility model (hide-on-scroll).
        // Observes ONLY this page's vertical scroll — never the horizontal pager
        // — so it introduces no vertical coupling into the pager's layout
        // resolver (the W44 hang lever).
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            // W36/#22 — no-op when there is no Insights strip to drive (the
            // standalone Dashboard / tile drill-down path). Optional-chained so
            // the same screen serves both surfaces without a crash or a behaviour
            // change for the pager.
            stripVisibility?.report(offset: newOffset)
        }
        // W22-W22 #4 — route the canvas through the `HLSurface.primary`
        // chokepoint (audit P2-1) so it harmonizes with neighbouring cards +
        // survives a future canonical palette flip, instead of the legacy
        // `HLColor.background` asset.
        .background(HLSurface.primary.ignoresSafeArea())
        .hlScrollEdgeSoft()
        // QoS-2 (A360-4) — every other primary surface has pull-to-refresh; this
        // metric page lacked one, so a stale/failed metric or a stuck "preparing"
        // assessment (QoS-3) had no recovery but navigating away. Re-drive the
        // metric load AND the assessment warm-poll so a pull resolves both. Uses
        // the canonical WHOOP-style modifier the sibling Insights pages use.
        .hlPullToRefresh {
            await store.load()
            await loadAssessment()
        }
        // W22-W22 (operator felt-refine #1) — the period control moved OFF the
        // fixed top (the operator found the pinned-top bar "komisch") to the
        // BOTTOM as a floating Liquid-Glass capsule, reusing the canonical
        // `HLFloatingPeriodControl` the Mood analysis screen already hosts. The
        // range still drives the chart through the same `rangeBinding`.
        .safeAreaInset(edge: .bottom) {
            HLFloatingPeriodControl(selection: rangeBinding, accessibilityLabelText: "Time range")
        }
        // #33 — the metric name now renders in the in-content `metricHeader`
        // (left-aligned, above the description, mirroring the Übersicht), so the
        // nav bar title + the two differently-sized toolbar buttons are gone.
        // The `✦` Coach + gear actions live in the header row as the SHARED
        // equal-sized circles. The nav bar is hidden so the inline title is the
        // only one (matches `InsightsScreen`'s `.toolbar(.hidden)`).
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: store.queryKey) {
            HLPerfSignpost.endTapToDetailIfPending() // v0.14 audit #17 — close tap-to-detail interval (begun in DashboardScreen.openDetail)
            await store.load()
        }
        // W46 / Task #49 — load the per-metric assessment through the
        // consent-gated read path (see `loadAssessment` doc-comment). Keyed on
        // both `kind` AND the master remote-AI opt-in so toggling the Settings
        // switch while this page is open re-evaluates: OFF clears the card,
        // ON fetches and paints. Only fires when a server is paired; standalone
        // resolves to the calm placeholder via `hasServer` without a round-trip.
        .task(id: AssessmentLoadKey(kind: kind, remoteAIEnabled: externalAIChosen)) {
            await loadAssessment()
        }
        // v0.14.1 — re-trigger the assessment warm-poll on app-foreground so a
        // server warm that exceeded the bounded ~48s poll window still resolves
        // without a manual page re-entry. Cache-first + idempotent (a ready
        // card simply re-paints); standalone resolves to the calm placeholder
        // inside `loadAssessment` without a round-trip.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadAssessment() }
        }
        // Warm the targets payload so the Ziel panel paints (only when this
        // metric actually has a target type — else skip the call). On the
        // Insights tab it's usually already warm (W3 cache-first).
        //
        // v0.14.6 H4 — keyed on `kind` (defensive: each pager page has a fixed
        // `.id(kind)` identity, so this runs once per page today, but the key
        // keeps it correct if a page ever reuses identity) and made warm-robust:
        // load when the store is cold, OR do ONE corrective reload when this
        // targeted kind's row is
        // absent from an already-warm response. Previously the bare
        // `response == nil` guard meant a page the user swiped to (e.g. Sleep)
        // could inherit a warm-but-partial store and never get its Zielband.
        .task(id: kind) {
            guard let type = MetricChartMath.targetType(for: kind) else { return }
            if insightsTargetsStore.response == nil {
                await insightsTargetsStore.load()
            } else if insightsTargetsStore.target(forType: type) == nil, !didRewarmTargets {
                didRewarmTargets = true
                await insightsTargetsStore.load()
            }
        }
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.load() }
            }
        }
        .sensoryFeedback(.selection, trigger: store.range)
        .sensoryFeedback(.selection, trigger: selectedDate)
        .fullScreenCover(isPresented: $presentFullscreenChart) {
            FullscreenChartCover(kind: kind, store: store, selectedDate: $selectedDate)
                .navigationTransition(.zoom(sourceID: Self.zoomSourceID, in: fullscreenZoomNamespace))
        }
        // v0152 C4 — the inline per-page Coach button opens the canonical
        // `AskCoachSheet` (same sheet as the overview); it routes per user. A360 H2
        // hands off the metric/correlation scope (see `askCoachSheet` in +Sections).
        .sheet(isPresented: $presentAskCoach, onDismiss: {
            coachSeedOverride = nil
            coachScopeOverride = nil
        }, content: { askCoachSheet })
        // W22-W22 (operator felt-refine #2) — the contextual target-band editor,
        // opened from the header gear. On save the targets payload is refreshed
        // so the Ziel panel + the Insights tiles repaint against the new band.
        .sheet(isPresented: $presentTargetEditor) {
            Task { await insightsTargetsStore.refresh() }
        } content: {
            if targetItem != nil {
                // #51 — pass the LOCALIZED metric title (`kind.displayName`,
                // `Measurement.swift:240`), NOT the server `targetItem.label`
                // (an English wire string). On a German device the sheet now
                // reads "Blutdruck", not "Blood Pressure".
                InsightsTargetBandEditorSheet(
                    metrics: editableTargetMetrics,
                    titleText: kind.displayName,
                    currentValues: editorCurrentValues
                )
                .hlSheetPresentation(.form)
            }
        }
    }

    // MARK: - Range binding

    private var rangeBinding: Binding<ChartDetailStore.Range> {
        Binding(
            get: { store.range },
            set: { store.range = $0 }
        )
    }
}

/// Task #49 — composite `.task(id:)` key so the assessment reload fires on both
/// a metric change AND a flip of the master remote-AI opt-in (the operator
/// toggling Settings → "Enable remote AI tools" while this page is open).
private struct AssessmentLoadKey: Equatable {
    let kind: MetricKind
    let remoteAIEnabled: Bool
}
