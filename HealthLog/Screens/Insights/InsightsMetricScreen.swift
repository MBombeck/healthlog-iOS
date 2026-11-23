import SwiftUI

/// v0.11 W22-W2 / I-1 / v0.14.3 C — the **canonical per-metric Insights page**.
/// The single screen behind every charted metric, standardised to ONE card stack
/// (Blutdruck reference), top→bottom:
///
///   1. **Heading** — metric title + (i) + gear (editable target) + `✦` Coach.
///   2. *(1.4 B2: the explainer paragraph, its "Mehr erfahren / Quellen" row,
///      the pulse-pressure sentences and the card captions moved behind the
///      (i), see `InsightsMetricInfo`.)*
///   3. **Letzte Messung** — a dedicated "Letzte Messung" heading above the
///      EXISTING `HeroStrip` tile (latest value + unit + delta chip, weekday +
///      day + time, and the server 7/30/90-day trend slopes), DIRECTLY under the
///      intro. v0.14.1 §5 retired the bespoke
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
/// **I-1 C:** the legacy duplicate "Zielbereich" card was removed from this
/// stack — its range + 30-day avg now live in the primary tile, and the
/// editable band stays reachable via the header gear. (The panel outlived its
/// last host, the legacy `ChartDetailScreen`, and was deleted in 1.4 B4.)
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
    @Environment(SettingsStore.self) var settingsStore
    @Environment(InsightsTargetsStore.self) var insightsTargetsStore
    /// The BP rich status card (`BPStatusCard`) was relocated here
    /// off the Insights overview. It reads the server `comprehensive` digest
    /// (BP classification / 30-day avg / % in target / band), so the BP metric
    /// page needs the `InsightsStore`. Injected at the app root, available on
    /// every pushed Insights screen.
    @Environment(InsightsStore.self) var insightsStore
    /// P8 (v0141 parity) — the ECG recording list. Drives the pulse page's
    /// data-gated cross-link into the ECG surface (`ecgCrossLinkRow`); app-root
    /// injected, so it resolves on the drill-down path too.
    @Environment(EcgStore.self) var ecgStore
    @Environment(\.appContainer) var appContainer
    /// Re-trigger the assessment warm-poll on app-foreground. The
    /// per-metric assessment poll (`pollUntilReady`) is bounded (~48s); a server
    /// warm that takes longer than the poll window would otherwise leave the
    /// card empty until the operator manually re-enters the page. Re-running
    /// `loadAssessment()` on `.active` resolves a slow warm without a manual
    /// re-entry. Idempotent (cache-first; a ready card just re-paints).
    @Environment(\.scenePhase) private var scenePhase

    @State var store: ChartDetailStore
    /// The per-metric assessment is fetched HERE (un-gated read)
    /// rather than read off `store.findings`. The web-mirror page must mirror
    /// the web exactly: show the assistant assessment whenever the user is
    /// online with a provider configured, regardless of the on-device
    /// AI-consent grant. `ChartDetailStore.findings` is gated behind that local
    /// consent grant (correct for the legacy `ChartDetailScreen` "Befunde"
    /// surface, which can trigger generation), which suppressed the BP
    /// assessment on this page even when the server had it (operator P1).
    /// `MetricInsightsRepository.fetchAssessment` skips the consent gate because
    /// the underlying GET is read-only and transmits no new health data — see
    /// its doc-comment. Hide/show gating is then carried purely by the server
    /// envelope's `hasProvider` (no provider).
    /// Internal (not `private`) so the assessment warm-poll in the
    /// `InsightsMetricScreen+Assessment.swift` extension can drive it.
    @State var assessment: MetricStatusDTO?
    @State var assessmentLoading = false
    /// QoS-3 — set when the assessment warm-poll exhausts its bounded
    /// window or stops on a transient error while still `preparing` (or the very
    /// first fetch fails before any envelope lands). Drives `AssessmentCard`'s
    /// terminal "couldn't load — pull to refresh" caption instead of leaving the
    /// indefinite "preparing" skeleton up with no recovery. Reset at the start of
    /// every `loadAssessment` so a pull-to-refresh / foreground retry clears it.
    /// Internal so the extension file can set it.
    @State var assessmentFailed = false
    /// The summaries slice's 30-day mean for this kind, the "30 Tage
    /// Durchschnitt" card's source when the (consent-gated) digest has none.
    @State var serverAverage30: Double?
    /// `coach-read` line one, the chart card's usual-range sentence (`+LabOverlay`).
    @State var coachRead: CoachReadStrip?
    @State var selectedDate: Date?
    @State var presentFullscreenChart = false
    /// Drives the inline `AskCoachSheet` from the per-page coach button.
    /// The sheet routes to the correct arm per user — see the header in `+Sections`.
    @State var presentAskCoach = false
    /// The coach sheet grows out of the coach button in the bar.
    @Namespace private var coachZoom
    /// A correlation card's pair-specific seed + scope override
    /// the page's metric handoff (`nil` → page metric). Reset on dismiss.
    @State var coachSeedOverride: String?
    @State var coachScopeOverride: CoachLaunchScope?
    /// W22-W22 (operator felt-refine #2) — the contextual target-band editor,
    /// now opened from a header gear button (next to the `✦`) instead of an
    /// in-card "Adjust target range" affordance.
    @State var presentTargetEditor = false
    /// Guards a single corrective targets reload per appearance
    /// when this targeted kind's band is missing from an already-warm response
    /// (so a partial/early warm can't leave Sleep — or any targeted page the
    /// user swiped to — without its Zielband).
    @State private var didRewarmTargets = false
    /// Observed only to retire the zoom cover when its source
    /// card leaves the window (see the `.onChange` beside the cover). Optional so
    /// previews and hosts without a router keep working.
    @Environment(AppRouter.self) private var router: AppRouter?
    /// A distinct zoom namespace + id from `ChartDetailScreen` so the
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

    /// The page's own scroll position; a reset goes to the very top of the
    /// page, the page's top room above the head included.
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// In the Insights pager the head is pinned above the strip.
    @Environment(\.insightsInPager) private var inPager

    init(
        kind: MetricKind,
        store: ChartDetailStore,
        matchedNamespace: Namespace.ID? = nil
    ) {
        self.kind = kind
        _store = State(initialValue: store)
        self.matchedNamespace = matchedNamespace
    }

    var body: some View {
        // In the pager the page goes back to its top once it is left and out
        // of view, and to its top on a re-tap of its pill. Shown on its own,
        // nothing changes the activation and the page keeps its scroll.
        scrollBody
            .modifier(InsightsPageScrollReset(position: $scrollPosition))
            // In the pager the head stands fixed at the top, over the strip.
            .insightsPageHead(enabled: inPager) {
                // The coach sheet grows out of the coach button here too.
                metricHeader.environment(\.hlActionZoomNamespace, coachZoom)
            }
    }

    private var scrollBody: some View {
        // One column for the whole page: head, statistics, chart and links
        // share the readable width and its outer edges. A pair inside it
        // measures that column, so it stacks in the phone's order.
        HLPage {
            // The head mirrors the Übersicht: metric title, the trailing
            // circles ((i), gear, `✦` Coach). In the pager it stands fixed
            // above the strip instead (`insightsPageHead`).
            if !inPager {
                metricHeader
            }
            // The canonical order: Letzte Messung, 30 Tage Durchschnitt,
            // Einschätzung, Min/Ø/Max/Median as tiles, then the chart under
            // the line of its period, then the relationships. The period
            // choice is the floating bar at the bottom.
            // Without a reading, a status, an assessment or statistics the
            // pair is not there at all, so it adds no gap.
            if hasReadingColumn || hasStatisticsColumn {
                HLPageColumnsContent(
                    columns: InsightsMetricColumns.columns(leading: hasReadingColumn, trailing: hasStatisticsColumn),
                    primary: readingColumn,
                    secondary: statisticsColumn
                )
            }
            chartBlock
            // Under "Erweitert": a lab marker, the blood pressure part of the day.
            InsightsChartExtras(kind: kind, store: store)
            // Blood pressure only, server 1.47+: the chart's range by part of the day.
            BloodPressureTimeOfDaySection(kind: kind, days: store.range.rawValue)
            // P7 (v0141 parity) — pulse-only: the intraday day curve sits
            // DIRECTLY under the range chart, where the web pulse page puts it.
            intradayPulseBlock
            // Cumulative-metric pages only: today's running total against the
            // usual day at the same hour.
            sameTimeBaselineBlock
            // Sleep-only: the row into the hypnogram, directly under the chart.
            sleepHypnogramRow
            // The derived sleep block, night → recent nights → rhythm.
            sleepDerivedBlock
            HLPageColumnsContent(
                columns: InsightsMetricColumns.columns(leading: correlationPanel != nil, trailing: true),
                primary: correlationBlock,
                secondary: linksColumn
            )
        }
        .scrollPosition($scrollPosition)
        // QoS-2 — every other primary surface has pull-to-refresh; this
        // metric page lacked one, so a stale/failed metric or a stuck "preparing"
        // assessment (QoS-3) had no recovery but navigating away. Re-drive the
        // metric load AND the assessment warm-poll so a pull resolves both. Uses
        // the canonical WHOOP-style modifier the sibling Insights pages use.
        .hlPullToRefresh {
            await store.load()
            await loadAssessment()
        }
        // The metric name is the in-content `metricHeader`; the bar stays
        // empty and inline as on every tab, so the title stands at the same
        // height, and pushed from Home or More the page keeps its back button.
        .navigationBarTitleDisplayMode(.inline)
        // Loads once per metric, period and source; paging never reloads.
        .modifier(InsightsMetricLoadTask(store: store))
        // Load the per-metric assessment through the
        // consent-gated read path (see `loadAssessment` doc-comment). Keyed on
        // both `kind` AND the master remote-AI opt-in so toggling the Settings
        // switch while this page is open re-evaluates: OFF clears the card,
        // ON fetches and paints.
        .task(id: AssessmentLoadKey(kind: kind, remoteAIEnabled: externalAIChosen)) {
            await loadAssessment()
        }
        // Re-trigger the assessment warm-poll on app-foreground so a
        // server warm that exceeded the bounded ~48s poll window still resolves
        // without a manual page re-entry. Cache-first + idempotent (a ready
        // card simply re-paints).
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadAssessment() }
        }
        // Warm the targets payload so the Ziel panel paints (only when this
        // metric actually has a target type — else skip the call). On the
        // Insights tab it's usually already warm (W3 cache-first).
        //
        // Keyed on `kind` (defensive: each pager page has a fixed
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
        .task(id: kind) {
            serverAverage30 = await appContainer?.measurementsRepo.average30(for: kind)
        }
        .task(id: kind) { await loadCoachRead() }
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(store.error)
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
        // The cover zooms back into the chart card on dismiss.
        // A deep link, notification or Quick Action that switches the tab while
        // the cover is up takes that card out of the window; an animated zoom
        // dismissal from a detached source aborts inside UIKit's morph
        // (`_morphPreviewFromCurrentState`, the 286 crash). Retire the cover
        // without animation the moment the Insights tab is left, so no zoom
        // morph ever runs against a vanished source.
        .onChange(of: router?.selectedTab) { _, tab in
            guard presentFullscreenChart, let tab, tab != .insights else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentFullscreenChart = false }
        }
        // The period bar at the bottom edge: the capsule floats free over
        // the page, with room for the last card above it. The
        // range drives the chart through `rangeBinding`.
        .hlPeriodBar(selection: rangeBinding, label: "Time range")
        // The inline per-page Coach button opens the canonical
        // `AskCoachSheet` (same sheet as the overview); it routes per user. A360 H2
        // hands off the metric/correlation scope (see `askCoachSheet` in +Sections).
        .sheet(isPresented: $presentAskCoach, onDismiss: {
            coachSeedOverride = nil
            coachScopeOverride = nil
        }, content: {
            askCoachSheet
                .hlZoomTransition(from: HLTabHeaderAction.Role.coach, in: coachZoom)
        })
        .environment(\.hlActionZoomNamespace, coachZoom)
        // W22-W22 (operator felt-refine #2) — the contextual target-band editor,
        // opened from the header gear. On save the targets payload is refreshed
        // so the Ziel panel + the Insights tiles repaint against the new band.
        .sheet(isPresented: $presentTargetEditor) {
            Task { await insightsTargetsStore.refresh() }
        } content: {
            if targetItem != nil {
                // Pass the LOCALIZED metric title (`kind.displayName`,
                // `Measurement.swift:240`), NOT the server `targetItem.label`
                // (an English wire string). On a German device the sheet now
                // reads "Blutdruck", not "Blood Pressure".
                InsightsTargetBandEditorSheet(
                    metrics: editableTargetMetrics,
                    titleText: kind.displayName,
                    currentValues: editorCurrentValues
                )
            }
        }
    }

    // MARK: - Range binding

    var rangeBinding: Binding<ChartDetailStore.Range> {
        Binding(
            get: { store.range },
            set: { store.range = $0 }
        )
    }
}

/// Composite `.task(id:)` key so the assessment reload fires on both
/// a metric change AND a flip of the master remote-AI opt-in (the operator
/// toggling Settings → "Enable remote AI tools" while this page is open).
private struct AssessmentLoadKey: Equatable {
    let kind: MetricKind
    let remoteAIEnabled: Bool
}
