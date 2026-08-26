import SwiftUI

/// v0.11 W22-W1 — the Insights tab root, rebuilt to mirror the web app's
/// tab-strip framing (`src/app/insights/layout.tsx:35-42` — every `/insights/**`
/// route is wrapped in the sticky `<InsightsTabStrip>`).
///
/// The container hosts:
/// 1. The sticky `InsightsMetricTabStrip` (`Übersicht · Blutdruck · Puls · …`),
///    pinned under the navigation so it persists while the operator moves between
///    surfaces — just like the web strip.
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

    /// W28c — the three special-page data sources. Each special pill self-gates
    /// on "has data" (mood entries / medications / workouts), mirroring how a
    /// metric pill gates on `availableKinds`.
    @Environment(MoodStore.self) var moodStore
    @Environment(MedicationsStore.self) var medicationsStore
    @Environment(WorkoutsStore.self) var workoutsStore
    /// W-B189 (#23) — recovery family store + the cloud-surface gate (recovery is
    /// server-derived → hidden in standalone / no-server).
    @Environment(RecoveryInsightsStore.self) var recoveryStore
    /// P8 (v0141 parity) — the ECG recording list. `hasRecordings` is the ECG
    /// pill's data gate; the warm load below lights it up before first visit.
    @Environment(EcgStore.self) var ecgStore
    @Environment(BackendAvailability.self) private var backend

    /// Single `ChartDetailStore` factory for the interim per-metric destination.
    @Environment(\.appContainer) var appContainer

    /// #34 — observes the Insights re-tap-to-root signal + the parked Insights
    /// metric slug (deep links).
    @Environment(AppRouter.self) var router

    /// Senior audit M1 — the extracted pager state machine. The View owns it as
    /// view-local `@State` (one per container instance) and delegates all the
    /// scroll↔selection glue into it. `internal` (not `private`) so the
    /// same-module `+Ordering` / `+GroupedPage` extensions can read its owned state.
    @State var pager = InsightsPagerModel()

    /// #39 — reduce-motion gate for the programmatic tap-jump scroll (passed into
    /// `pager.mirrorSelectionIntoScroll`). A swipe is always direct.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Still injected into the environment so the inner pages
    /// (`InsightsScreen` / `InsightsMetricScreen` / the three special pages) keep
    /// resolving `@Environment(InsightsStripVisibility.self)` and compile
    /// unchanged. As of v0.11 the strip is PERMANENTLY PINNED, so the container no
    /// longer reads `hidden` — the pages' `report(offset:)` calls are inert. This
    /// is view-local chrome, NOT pager state-machine state, so it stays on the
    /// View as `@State`.
    @State private var stripVisibility = InsightsStripVisibility()

    /// v0.14.1 — drives the strip-customise sheet (reorder + show/hide the top
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
        // W22-W22 — ONE shared NavigationStack hosts the whole Insights tab. The
        // sticky strip pins via `.safeAreaInset(edge: .top)`. The content area is
        // a horizontally PAGED `ScrollView` bound to the SAME `selection` the strip
        // drives (see `pager` builder).
        return NavigationStack {
            pagerView
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        InsightsMetricTabStrip(
                            selection: $pager.selection,
                            orderedSelections: orderedSelections,
                            onPillTap: { tapped in
                                // Q-insights-scroll — a re-tap of the ALREADY-active
                                // pill is the only case that carries the "scroll the
                                // visible page to the top" intent.
                                if tapped == pager.selection {
                                    pager.activePageRetapCount += 1
                                }
                            },
                            // v0.14.1 — trailing strip-customise affordance.
                            onCustomize: { showStripCustomize = true },
                            // 22-01 (R4) — the honest note, carried in the
                            // strip's own row so it displaces no content. See
                            // `InsightsMetricTabStrip.availabilityNote`.
                            availabilityNote: InsightsAvailabilityStatement.text(
                                for: availabilityResolution,
                                latchedKindsAreEmpty: availableKinds.isEmpty
                            )
                        )
                        // Quiet hairline so the strip reads as chrome above the
                        // content, matching the web strip's bottom border.
                        Divider()
                            .overlay(HLText.tertiary.opacity(0.15))
                    }
                    .background(.bar)
                    // v0.11 — the strip is PERMANENTLY PINNED at the top (the W44
                    // hang lever stays pinned — no scroll-driven layout change here).
                }
        }
        // W52-3 — make the visibility model available to the inner pages.
        .environment(stripVisibility)
        .hlScreenBackground()
        // W29 — realize the current page + its immediate neighbours on first
        // approach (initial appearance + every selection change).
        .onAppear {
            // V0150 — seed the frozen pager order before first layout, then realize.
            pager.reconcilePagerOrder(liveOrderedSelections: liveOrderedSelections)
            pager.realizeWindow(around: pager.selection, pages: pagerPages)
        }
        .onChange(of: pager.selection) { _, newValue in
            pager.realizeWindow(around: newValue, pages: pagerPages)
            // #39/W-NAVANIM — mirror tap / deep link into scroll.
            pager.mirrorSelectionIntoScroll(newValue, pages: pagerPages, reduceMotion: reduceMotion)
            // W-RECONCILE H-1 — timeout backstop. `scrollPosition(id:)` is NOT
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
        // V0150 — reconcile the frozen order whenever the LIVE list changes
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
        // #39 — mirror a settled swipe back into `selection` so the strip pill
        // highlight follows the page the operator landed on, AND fold in deferred
        // availability growth when the pager settles back at overview (V0150).
        //
        // `scrollPosition(id:)` ALSO fires for the transient ids a layout resolver
        // writes (W44). Guards:
        //   1. A programmatic scroll (pill tap / deep link) sets
        //      `programmaticScrollTarget`; until the resolver settles back on that
        //      target we ignore writes so a resolver echo can't bounce `selection`
        //      to a neighbour (H2). The target write clears the guard.
        //   2. Only a settled id that differs from `selection` moves `selection`.
        .onChange(of: pager.scrolledID) { _, newID in
            guard let newID else { return }
            // H2 — a programmatic scroll is in flight: accept ONLY the write that
            // lands on the intended target (which clears the guard); ignore echoes.
            if let target = pager.programmaticScrollTarget {
                if newID == target { pager.programmaticScrollTarget = nil }
                return
            }
            // V0150 — settled back at overview: safe to adopt deferred growth.
            if newID == .overview, pager.selection == .overview {
                pager.reconcilePagerOrder(liveOrderedSelections: liveOrderedSelections)
                return
            }
            // V0151 — a genuine settled user swipe → follow it. Map the landed PAGE
            // id back to a selection (a group page → its current in-page member).
            // No-op when the selection already lives on this page.
            guard let landed = pager.selectionForLandedPage(newID, pages: pagerPages) else { return }
            guard landed != pager.selection else { return }
            pager.selection = landed
        }
        // #34 — keep the latched availability union current (monotonic; only grows).
        .onAppear { pager.mergeSeenKinds(liveAvailableKinds) }
        .onChange(of: liveAvailableKinds) { _, _ in pager.mergeSeenKinds(liveAvailableKinds) }
        // W28c — keep the special-page availability latch current the same way.
        .onAppear { pager.mergeSeenSpecials(liveAvailableSpecials) }
        .onChange(of: liveAvailableSpecials) { _, _ in pager.mergeSeenSpecials(liveAvailableSpecials) }
        // W28c — warm the three special-page stores so their pills can light up
        // without first visiting Mood / Medications / Workouts elsewhere. Each
        // `load()` is SWR-deduped (no-op when already hydrated).
        // v0.13.1 IC — refresh the per-kind has-data availability from the all-time
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
        .task {
            if moodStore.entries.isEmpty { await moodStore.load() }
        }
        .task {
            if medicationsStore.medications.isEmpty { await medicationsStore.load() }
        }
        .task {
            if workoutsStore.workouts.isEmpty { await workoutsStore.load() }
        }
        // W-B189 (#23) — warm the recovery family so the pill can light up before
        // first visit. Cloud-gated + SWR-deduped (no-op offline / already warm).
        .task {
            if backend.canShowCloudInsights, recoveryStore.family == nil {
                await recoveryStore.load()
            }
        }
        // P8 (v0141 parity) — warm the ECG list so the data-gated pill can light
        // up without first visiting the page. Cloud-gated + SWR-deduped; a
        // gated-off read resolves to `nil` and the pill simply never appears.
        .task {
            if backend.canShowCloudInsights, ecgStore.list == nil {
                await ecgStore.load()
            }
        }
        // W29 — if the visible page falls out of the ordered set, snap back to
        // Übersicht so the pager never strands on a now-missing page with no pill.
        .onChange(of: orderedSelections) { _, newOrder in
            if !newOrder.contains(pager.selection) {
                pager.selection = .overview
            }
            // W0-fix (M2) — retry a deep link that arrived before its page existed.
            pager.tryApplyStagedMetric(liveOrderedSelections: liveOrderedSelections, pages: pagerPages)
        }
        // #34 — re-tap-to-root. The shell bumps `insightsRootRequestCount`; reset
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
            pager.stageInsightsMetricIfRequested(
                router: router,
                liveOrderedSelections: liveOrderedSelections,
                pages: pagerPages
            )
        }
        // Cold-start-from-tap: the parked slug may already be set by the time this
        // view first appears, so resolve it once on appear too (one-shot consume).
        .onAppear {
            pager.stageInsightsMetricIfRequested(
                router: router,
                liveOrderedSelections: liveOrderedSelections,
                pages: pagerPages
            )
        }
        // v0.14.1 — strip-customise sheet (reorder + show/hide the top tab-strip
        // tabs). Reuses the server-first `SettingsInsightsCustomizationScreen`.
        .sheet(isPresented: $showStripCustomize) {
            NavigationStack {
                SettingsInsightsCustomizationScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { showStripCustomize = false }
                        }
                    }
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
        // `@Bindable` so `.scrollPosition(id:)` binds to the model's `scrolledID`.
        @Bindable var pager = pager
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // V0151 — page on the FOLDED page list (one page per strip pill),
                // NOT the flat `orderedSelections`. A category is ONE page hosting
                // an in-page member switch, so strip pill `i` ↔ pager page `i`.
                ForEach(pagerPages, id: \.scrollIdentity) { pagePage in
                    page(for: pagePage)
                        // #34/#39 — pin every page to the EXACT container WIDTH:
                        // that is what makes the paging snap target exactly one
                        // screen, so a swipe always lands on a whole page.
                        //
                        // W44 hang-fix — the `.vertical` axis was REMOVED. Pinning
                        // each page to the container HEIGHT forced the overview's
                        // inner vertical `ScrollView` to be re-measured against the
                        // container on every layout pass, and that re-measure
                        // re-triggered the horizontal pager's `.scrollPosition(id:)`
                        // resolver → AttributeGraph never converged → main-thread
                        // hang on entering Insights. Width-only pinning still snaps
                        // each swipe to a whole page; each page sizes its own height.
                        .containerRelativeFrame(.horizontal)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .id(pagePage.scrollIdentity)
                }
            }
            .scrollTargetLayout()
        }
        // #39 — `.paging` forces a full-page snap on every swipe; a page can never
        // settle between two. `.scrollPosition` two-way-bridges to `selection` via
        // the guarded `onChange` mirrors in `body`. The non-lazy `HStack` keeps
        // every mounted page alive (far metric pages are cheap `Color.clear`
        // placeholders until realized). Indicators hidden — the strip IS it.
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pager.scrolledID)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("insights.pager")
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
    @ViewBuilder
    private func metricPage(kind: MetricKind) -> some View {
        if let container = appContainer, pager.realizedMetrics.contains(kind) {
            InsightsMetricScreen(
                kind: kind,
                store: container.makeChartDetailStore(kind: kind),
                // v0.14.6 N3 — tell the page when it is the pager's current page so
                // it can scroll itself back to the top on activation (INSTANT reset).
                isActivePage: pager.selection == .metric(kind),
                // Q-insights-scroll — forward the active-page re-tap counter so a
                // deliberate re-tap of THIS page's pill animates it to the top.
                retapSignal: pager.activePageRetapCount
            )
            // `.id(kind)` keeps each metric's `@State` store distinct.
            .id(kind)
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
