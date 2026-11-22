import SwiftUI

/// The Insights tab root, rebuilt to mirror the web app's
/// tab-strip framing (`src/app/insights/layout.tsx:35-42` — every `/insights/**`
/// route is wrapped in the `<InsightsTabStrip>`).
///
/// The container hosts:
/// 1. The `InsightsMetricTabStrip` (`Übersicht · Blutdruck · Puls · …`), ONE
///    strip over the pager under the active page's pinned head
///    (`InsightsChromeStrip`, `insightsPageHead`). Its chosen pill follows
///    the page.
/// 2. The selected surface: `Übersicht` renders the EXISTING `InsightsScreen`
///    body verbatim (reused, not rewritten — it keeps its own navigation stack
///    and all its loading/sheets), and a metric pill opens that metric's
///    `ChartDetailScreen`.
///
/// **Senior audit M1** — the pager's scroll↔selection STATE MACHINE was extracted
/// into the dedicated `@Observable @MainActor InsightsPagerModel`. The View is now
/// thin: it owns the model (`@State var pager`), computes the store-derived
/// availability/order inputs in `+Ordering`, and DELEGATES every `onChange`/
/// `onAppear` glue into `pager.<method>(…)` passing those inputs. The model owns
/// all the mutable pager state + the impure transitions + the two pure decision
/// funcs the unit tests drive.
struct InsightsContainerScreen: View {
    /// Server-synced Insights tile order + visibility — drives the strip's pill
    /// order/visibility (the operator's curated layout, one source of truth).
    @Environment(InsightsLayoutStore.self) var layoutStore

    /// Availability source. The Insights `.task` already warms `recent`; the
    /// strip gates each metric pill on ≥1 measurement of that kind (web parity).
    @Environment(MeasurementsStore.self) var measurementsStore

    /// The three special-page data sources. Each special pill self-gates
    /// on "has data" (mood entries / medications / workouts), mirroring how a
    /// metric pill gates on `availableKinds`.
    @Environment(MoodStore.self) var moodStore
    @Environment(MedicationsStore.self) var medicationsStore
    @Environment(WorkoutsStore.self) var workoutsStore
    /// Recovery family store (server-derived).
    @Environment(RecoveryInsightsStore.self) var recoveryStore
    /// P8 (v0141 parity) — the ECG recording list. `hasRecordings` is the ECG
    /// pill's data gate; the warm load below lights it up before first visit.
    @Environment(EcgStore.self) var ecgStore

    /// Single `ChartDetailStore` factory for the interim per-metric destination.
    @Environment(\.appContainer) var appContainer

    /// Observes the Insights re-tap-to-root signal + the parked Insights
    /// metric slug (deep links).
    @Environment(AppRouter.self) var router

    /// Senior audit M1 — the extracted pager state machine. The View owns it as
    /// view-local `@State` (one per container instance) and delegates all the
    /// scroll↔selection glue into it. `internal` (not `private`) so the
    /// same-module `+Ordering` / `+GroupedPage` extensions can read its owned state.
    @State var pager = InsightsPagerModel()

    /// Reduce-motion gate for the programmatic tap-jump scroll (passed into
    /// `pager.mirrorSelectionIntoScroll`). A swipe is always direct.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// The heights of the fixed top (the active head, the strip).
    @State private var chrome = InsightsChromeMetrics()

    /// Drives the strip-customise sheet (reorder + show/hide the top
    /// tab-strip tabs), reached via the trailing affordance on the strip itself.
    /// View-local sheet flag, NOT pager state-machine state.
    @State private var showStripCustomize = false

    /// 22-01 (R4) — where the availability read stands, as this VIEW sees it.
    ///
    /// View-owned on purpose: `MeasurementsStore` sits against the frozen
    /// Phase-06 effect census and publishes nothing new for this. The `.task`
    /// below already brackets the read, so its own `await` returning is the
    /// only signal needed — combined with whether the latch holds any kind at
    /// all, that is enough for the strip to stop being silent about a
    /// composition it knows is incomplete.
    @State private var availabilityResolution = InsightsAvailabilityStatement.Resolution.pending

    var body: some View {
        // `@Bindable` so the strip + the pager's `.scrollPosition(id:)` can bind to
        // the model's `selection` / `scrolledID`.
        @Bindable var pager = pager
        // The stack's own path, so a push from a page (the timeline row)
        // lands on the stack itself rather than on a destination the page
        // declares inside the pager.
        @Bindable var router = router
        // ONE shared NavigationStack hosts the whole Insights tab. The content
        // area is a horizontally PAGED `ScrollView` bound to the SAME
        // `selection` the strip drives (see `pager` builder).
        let strip = InsightsStripContext(
            selection: $pager.selection,
            selected: pager.selection,
            orderedSelections: orderedSelections,
            onPillTap: { tapped in
                // Q-insights-scroll — a re-tap of the ALREADY-active pill is
                // the only case that carries the "scroll the visible page to
                // the top" intent.
                if tapped == pager.selection {
                    pager.activePageRetapCount += 1
                }
            },
            onCustomize: { showStripCustomize = true },
            // 22-01 (R4) — the honest note, carried in the strip's own row so
            // it displaces no content.
            availabilityNote: InsightsAvailabilityStatement.text(
                for: availabilityResolution,
                latchedKindsAreEmpty: availableKinds.isEmpty
            )
        )
        return NavigationStack(path: $router.insightsPath) {
            // The fixed top: each page pins its own head; the ONE strip
            // stands under the active page's head, over the pager, so the
            // pages page underneath it and its chosen pill follows the page.
            ZStack(alignment: .top) {
                pagerView
                    .environment(\.insightsChrome, chrome)
                InsightsChromeStrip(context: strip, chrome: chrome, pager: pager)
            }
            // The pager clips its pages at the sides, so behind the side
            // safe area (the open Duo's upright bar and clock) the stack's
            // own white showed. The canvas fills the window under it.
            .background(HLSurface.primary)
            // The pages know they stand in the pager (Cmd-R, the Period
            // menu); the strip context itself is drawn once, above.
            .environment(\.insightsInPager, true)
            // A re-tap of the active pill: the active page goes to its top.
            .environment(\.insightsPageRetapSignal, pager.activePageRetapCount)
            // Regular: Log as the "+" of this tab root.
            .hlShellCaptureItem(.insights)
            // Pushed by value from the pages (``InsightsRoute``), registered
            // at the root of the stack, outside the pager.
            .navigationDestination(for: InsightsRoute.self) { route in
                switch route {
                case .timeline:
                    TimelineScreen()
                }
            }
        }
        .hlScreenBackground()
        // Realize the current page + its immediate neighbours on first
        // approach (initial appearance + every selection change).
        .onAppear {
            // Seed the frozen pager order before first layout, then realize.
            pager.reconcilePagerOrder(liveOrderedSelections: liveOrderedSelections)
            pager.realizeWindow(around: pager.selection, pages: pagerPages)
        }
        .onChange(of: pager.selection) { _, newValue in
            pager.realizeWindow(around: newValue, pages: pagerPages)
            // #39/W-NAVANIM — mirror tap / deep link into scroll.
            pager.mirrorSelectionIntoScroll(newValue, pages: pagerPages, reduceMotion: reduceMotion)
            // Timeout backstop. `scrollPosition(id:)` is NOT
            // guaranteed to deliver a settle write that exactly equals the
            // programmatic target (animation coalescing, reduce-motion flip, a page
            // reshape that re-keys `scrollIdentity`); without this the H2 latch can
            // stay armed forever and swallow every later user swipe. Capture the
            // generation we just armed and clear the latch after a short deadline
            // ONLY if no newer arming happened meanwhile. A normal settle clears it
            // first (line ~165), making this a no-op.
            let armed = pager.programmaticScrollGeneration
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                pager.clearStaleProgrammaticScroll(generation: armed)
            }
        }
        // Reconcile the frozen order whenever the LIVE list changes
        // (availability latch hydration / layout edit). The reconcile defers any
        // anchor-shifting insertion until the pager is settled at overview.
        .onChange(of: liveOrderedSelections) { _, _ in
            pager.reconcilePagerOrder(liveOrderedSelections: liveOrderedSelections)
            // v0150 arch-L2 — un-latch a stranded programmatic scroll. If the
            // target page vanished from the pager order mid-scroll, clear the target
            // so the swipe→selection mirror recovers immediately.
            if let target = pager.programmaticScrollTarget,
               !pagerPages.contains(where: { $0.scrollIdentity == target })
            {
                pager.programmaticScrollTarget = nil
            }
        }
        // The settled-swipe mirror (`scrolledID` → `selection`) lives on the
        // paged scroll view itself (`InsightsPagedScroll`).
        // Keep the latched availability union current (monotonic; only grows).
        .onAppear { pager.mergeSeenKinds(liveAvailableKinds) }
        .onChange(of: liveAvailableKinds) { _, _ in pager.mergeSeenKinds(liveAvailableKinds) }
        // Keep the special-page availability latch current the same way.
        .onAppear { pager.mergeSeenSpecials(liveAvailableSpecials) }
        .onChange(of: liveAvailableSpecials) { _, _ in pager.mergeSeenSpecials(liveAvailableSpecials) }
        // And the recovery members the same way.
        .onAppear { pager.mergeSeenRecoveryKinds(liveRecoveryKinds) }
        .onChange(of: liveRecoveryKinds) { _, live in pager.mergeSeenRecoveryKinds(live) }
        // A link to the Recovery category on an account without a recovery
        // page lands on Übersicht once the family has answered.
        .onChange(of: recoveryStore.hasSettledOnce) { _, settled in
            guard settled else { return }
            pager.abandonStagedCategoryIfEmpty(.recovery, liveOrderedSelections: liveOrderedSelections)
        }
        // Warm the three special-page stores so their pills can light up
        // without first visiting Mood / Medications / Workouts elsewhere. Each
        // `load()` is SWR-deduped (no-op when already hydrated).
        // Refresh the per-kind has-data availability from the all-time
        // summaries slice so low-frequency kinds (BP / weight) light up their pill.
        .task {
            availabilityResolution = .pending
            // 22-01 (R4) — the read reports whether it PUBLISHED, which is not
            // the same question as whether any kind came back. An account with
            // no measurements published an honest empty answer and needs no
            // commentary; a refused, failed or interrupted read published
            // nothing and is exactly what the strip must not stay silent about.
            //
            // Read off the return value rather than off `availableKinds`
            // (22-02's UI gate caught the difference): deriving "unresolved"
            // from an empty set made the statement permanent for every
            // measurement-less account, and at accessibility text sizes that
            // permanent line pushed the overview's own content out of the
            // layout — 217pt of chrome to explain an absence that was not a
            // failure.
            availabilityResolution = await measurementsStore.loadAvailability() ? .resolved : .unresolved
        }
        // Each data-gated source reports when it has answered, so a
        // deep link to its page can land on the empty state (`settleSpecial`).
        .task {
            if moodStore.entries.isEmpty { await moodStore.load() }
            if moodStore.error == nil { settleSpecial(.mood) }
        }
        .task {
            if medicationsStore.medications.isEmpty { await medicationsStore.load() }
            if medicationsStore.error == nil { settleSpecial(.medications) }
        }
        .task {
            if workoutsStore.workouts.isEmpty { await workoutsStore.load() }
        }
        // Warm the recovery family so the pill can light up before
        // first visit. Cloud-gated + SWR-deduped (no-op offline / already warm).
        .task {
            if recoveryStore.family == nil {
                await recoveryStore.load()
            }
        }
        // P8 (v0141 parity) — warm the ECG list so the data-gated pill can light
        // up without first visiting the page. Cloud-gated + SWR-deduped; a
        // gated-off read resolves to `nil` and the pill simply never appears.
        .task {
            if ecgStore.list == nil { await ecgStore.load() }
            if ecgStore.list != nil { settleSpecial(.ecg) }
        }
        // If the visible page falls out of the ordered set, snap back to
        // Übersicht so the pager never strands on a now-missing page with no pill.
        .onChange(of: orderedSelections) { _, newOrder in
            if !newOrder.contains(pager.selection) {
                pager.selection = .overview
            }
            // Retry a deep link that arrived before its page existed.
            pager.tryApplyStagedMetric(liveOrderedSelections: liveOrderedSelections, pages: pagerPages)
        }
        // Re-tap-to-root. The shell bumps `insightsRootRequestCount`; reset
        // the pager to Übersicht (index 0).
        .onChange(of: router.insightsRootRequestCount) { _, _ in
            if pager.selection != .overview {
                pager.selection = .overview
            }
        }
        // v0.12 W0-1/W0-3 — inbound `.insights(metric:)` deep link. The router parks
        // the requested slug + bumps `insightsMetricRequestCount`; we map the slug
        // onto `selection` and let `.onChange(of: selection)` mirror the scroll.
        .onChange(of: router.insightsMetricRequestCount) { _, _ in
            stageDeepLink()
        }
        // Cold-start-from-tap: the parked slug may already be set by the time this
        // view first appears, so resolve it once on appear too (one-shot consume).
        .onAppear {
            stageDeepLink()
        }
        // Strip-customise sheet (reorder + show/hide the top tab-strip
        // tabs). Reuses the server-first `SettingsInsightsCustomizationScreen`.
        .sheet(isPresented: $showStripCustomize) {
            // The changes take effect as they are made; the bar says "Done".
            HLSheetScaffold("Customize tab strip", action: .done()) {
                SettingsInsightsCustomizationScreen()
            }
        }
    }

    /// The horizontally-paged swipe container. Built on the iOS-17 paged
    /// `ScrollView` (NOT `TabView(.page)`): a swipe settles `scrolledID` on a page
    /// (→ mirrored into `selection`, so the strip pill follows), a pill tap sets
    /// `selection` (→ mirrored into `scrolledID`, so the pager scrolls). The two
    /// mirrors live in `body`'s `onChange`s and are guarded so neither re-drives
    /// the other.
    ///
    /// `.scrollTargetBehavior(.paging)` over container-width pages snaps to a whole
    /// page deterministically and the gesture is never fought by a programmatic
    /// animation (the tap-jump is guarded out during a swipe).
    private var pagerView: some View {
        // The page of the selection is the active one: one signal for the
        // strips, the pin report and the page's own reset, and it changes once
        // per swipe, when the pager rests.
        let activePage = pageForSelection?.scrollIdentity
        return InsightsPagedScroll(
            pager: pager,
            pages: pagerPages,
            liveOrderedSelections: liveOrderedSelections,
            activePage: activePage
        ) { entry in
            page(for: entry)
        }
    }

    @ViewBuilder
    private func page(for entry: InsightsPagerPage) -> some View {
        switch entry {
        case .overview:
            // Reuse the existing overview verbatim — it resolves its pushes/
            // sheets against the container's single shared stack.
            InsightsScreen()
                .accessibilityIdentifier("insights.page.overview")
        case let .flat(kind):
            metricPage(kind: kind)
        case let .special(special):
            specialPage(special)
        }
    }

    /// A metric page — W22-W2 web-mirror `InsightsMetricScreen`.
    ///
    /// **Laziness (W29 perf):** the heavy screen + its `ChartDetailStore` are
    /// built ONLY when this page is the current one or an immediate neighbour
    /// (±1 of the selected index), so a 10-pill strip does not construct 10 chart
    /// stores up front. Off-window pages render a cheap placeholder; the page
    /// identity (`.tag`) stays stable so the system keeps the slot.
    ///
    /// The page slot stays `kind`, but the measure shown can differ:
    /// the HRV page shows RMSSD once SDNN has no reading in the last 30 days
    /// (`RecoveryInsightsStore.displayKind(for:)`), so it never stands on a
    /// series that stopped. The page's own title then names the measure.
    @ViewBuilder
    private func metricPage(kind: MetricKind) -> some View {
        if let container = appContainer, pager.realizedMetrics.contains(kind) {
            let shown = recoveryStore.displayKind(for: kind)
            // The page learns whether it is the active one, and of a re-tap,
            // from the environment, so a page change does not rebuild it.
            InsightsMetricScreen(
                kind: shown,
                store: pager.chartStore(for: shown) { container.makeChartDetailStore(kind: shown) }
            )
            // `.id(shown)` keeps each metric's `@State` store distinct, and
            // rebuilds the HRV page when its measure switches.
            .id(shown)
            .accessibilityIdentifier("insights.page.\(kind.rawValue)")
        } else {
            // Off-window placeholder — keeps the page slot + tag alive without
            // building a chart store.
            Color.clear
                .background(HLSurface.primary.ignoresSafeArea())
                .accessibilityHidden(true)
        }
    }

    // MARK: - Ordering + prefetch window

    // The store-reading ordering + availability-latch cluster
    // (`liveOrderedSelections`, `orderedSelections`, `pagerPages`,
    // `pageForSelection`, `liveAvailableKinds`, `availableKinds`,
    // `moduleDisabledMetricKinds`, `liveAvailableSpecials`, `availableSpecials`)
    // lives in `InsightsContainerScreen+Ordering.swift`. These read `@Environment`
    // stores (so they STAY on the View for `@Observable` tracking) + the model's
    // owned `pager.pagerOrder`/`pager.seenKinds`/`pager.seenSpecials`, forwarding
    // the decision logic into `InsightsPagerModel`.
}
