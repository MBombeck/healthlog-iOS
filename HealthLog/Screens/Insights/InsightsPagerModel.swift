import SwiftUI

/// Senior audit M1 — the Insights pager's scroll↔selection STATE MACHINE,
/// extracted out of `InsightsContainerScreen` so the View stays thin.
///
/// **What this owns.** Every piece of mutable pager state that used to live as a
/// `@State` field on the container (selection, the scroll position, the frozen
/// page order, the programmatic-scroll latch, the per-category in-page member
/// choice, the staged deep-link target, the availability latches, the realized
/// window, the re-tap counter) plus the *impure* transitions over that state.
///
/// **What it deliberately does NOT own.** Anything that reads `@Environment`
/// stores. The container's store-reading derivations (`liveOrderedSelections`,
/// `availableKinds`, `pagerPages`, …) stay as computed vars on
/// `InsightsContainerScreen+Ordering` so SwiftUI's `@Observable` dependency
/// tracking still fires the View body on store change. The View computes those
/// live inputs from its environment and PASSES THEM INTO the model methods — the
/// model never holds a store reference (that would break observation in a plain
/// class). The pure decision logic (`pageScrollTransition`,
/// `reconciledPagerOrder`) lives here as `nonisolated static` funcs, which is
/// what the unit tests drive.
///
/// `@MainActor @Observable` per the project state doctrine (no `ObservableObject`,
/// no Combine).
@MainActor
@Observable
final class InsightsPagerModel {
    // MARK: - State-machine state (owned, mutable)

    /// Selected surface. Defaults to `Übersicht` so the tab opens on the overview
    /// exactly like web (`pathname === "/insights"`).
    var selection: InsightsTabSelection = .overview

    /// #39 — the scroll-driven page position bound to the horizontal pager's
    /// `.scrollPosition(id:)`. Bridged to `selection` by two GUARDED one-way
    /// mirrors (never a feedback loop): a settled swipe lands this on a page id →
    /// we mirror it into `selection` so the strip pill follows; a pill tap sets
    /// `selection` → we mirror it back here to scroll the pager. Each mirror
    /// no-ops when the two already agree, so a swipe is never met by a competing
    /// programmatic scroll. Starts on `.overview`.
    ///
    /// v0152 I1 — typed as `InsightsPagerPageID`, which now mirrors
    /// `InsightsTabSelection` 1:1 (the flat-pager contract): every metric is its
    /// own page, so a swipe between two members of the same category IS a page
    /// change that moves this scroll position.
    var scrolledID: InsightsPagerPageID? = .overview

    /// V0150 (RCA-insights-swipe) — the FROZEN page list the pager `ForEach`, the
    /// strip, `realizeWindow`, and `tryApplyStagedMetric` all read. The live order
    /// grows asynchronously after mount (availability latch + `@Observable` churn);
    /// inserting a page before the current one shifts the visible content under a
    /// non-zero anchor. `reconcilePagerOrder` adopts a new order only when that is
    /// anchor-safe. Seeded on first reconcile (`.onAppear`).
    var pagerOrder: [InsightsTabSelection] = []

    /// V0150 (H2) — the page a PROGRAMMATIC scroll (pill tap / deep link) is
    /// driving `scrolledID` toward. While set, the `scrolledID → selection` mirror
    /// ignores resolver echoes that don't match it, so a layout-resolver write
    /// cannot bounce `selection` to a neighbour. Cleared when the resolver settles
    /// on the target. `nil` = a free user swipe drives the mirror.
    var programmaticScrollTarget: InsightsPagerPageID?

    /// v0152 W-RECONCILE H-1 — monotonic token bumped every time
    /// `mirrorSelectionIntoScroll` arms `programmaticScrollTarget`. The timeout
    /// backstop captures the token it armed and only clears the latch if no newer
    /// arming has happened since (and the same target is still latched). This stops
    /// a stuck latch from swallowing every subsequent user swipe forever when
    /// `scrollPosition(id:)` never delivers a settle write that EXACTLY equals the
    /// programmatic target (animation coalescing, reduce-motion flip mid-scroll, a
    /// page reshape that changes `scrollIdentity` between the set and the settle).
    var programmaticScrollGeneration = 0

    /// W-RECONCILE H-1 — clear the programmatic-scroll latch if it is still the
    /// SAME arming (`generation` unchanged) and still pointing at `target`. Called
    /// by the View's timeout backstop after a short deadline. A newer
    /// `mirrorSelectionIntoScroll` (bumped generation) or an already-cleared latch
    /// makes this a no-op, so a legitimately in-flight fresh scroll is never
    /// un-latched out from under itself. Returns `true` iff it cleared.
    @discardableResult
    func clearStaleProgrammaticScroll(generation: Int) -> Bool {
        guard programmaticScrollTarget != nil,
              programmaticScrollGeneration == generation else { return false }
        programmaticScrollTarget = nil
        return true
    }

    /// v0.12 W0-fix (review H1/M2) — a deep-linked metric target that has been
    /// CONSUMED from the router (one-shot) but not yet applied because its page
    /// isn't in `orderedSelections` yet (cold-start-from-tap, data still
    /// hydrating). Held so the retry can apply it once the page exists.
    var pendingMetricTarget: InsightsTabSelection?

    /// W-NAVANIM (operator-walk b190) — one-shot "the NEXT `selection` change is a
    /// DEEP-LINK jump". Set by the deep-link appliers before they mutate
    /// `selection`; `mirrorSelectionIntoScroll` reads+clears it to choose an
    /// INSTANT jump over the calm slide (the "gehetzte Blätter-Animation" fix).
    var pendingDeepLinkJump = false

    /// W29 — metric pages that have entered the build window at least once. Once a
    /// metric page is built we keep it built even after it leaves the ±1 window,
    /// so a visited page's vertical scroll position + warm `ChartDetailStore`
    /// survive the operator swiping several pages away and back (page-aliveness).
    var realizedMetrics: Set<MetricKind> = []

    /// #34 (W31 root cause) — latched availability. `measurementsStore.recent` is
    /// SWR-loaded and revalidates over the first seconds; a single transient
    /// revalidation can briefly drop a kind. We latch availability to the UNION of
    /// every kind seen this session, so a kind never leaves the ordered set once
    /// it has appeared — the page the selection points at can never vanish under
    /// it during a revalidation.
    var seenKinds: Set<MetricKind> = []

    /// W28c — the same latch, for the three special pages. The union only ever
    /// grows within a session, so once a special has shown data it keeps its pill
    /// + page.
    var seenSpecials: Set<InsightsSpecialPage> = []

    /// Q-insights-scroll — bumped each time the operator RE-TAPS the strip pill of
    /// the page that is ALREADY the active page. The active metric page observes
    /// this counter to animate its own vertical scroll back to the top.
    var activePageRetapCount = 0

    // MARK: - Pure transition policy (unit-testable, store-free)

    /// Where a programmatic `selection` change came from. A deep link (Home tile
    /// tap / inbound `.insights(metric:)`) is a teleport: the operator asked to BE
    /// on the target page, not to watch the pager travel there. An interactive
    /// change (pill tap / re-tap-to-root) is an in-Insights gesture that should
    /// feel like a calm slide.
    enum PageSelectionSource {
        case deepLink
        case interactive
    }

    /// How the pager should move its `scrollPosition` to a new page.
    enum PageTransition {
        /// Set the scroll position with no animation (the page is shown at once).
        case instant
        /// Animate the scroll with the calm in-Insights slide.
        case animated
    }

    /// Pure policy: a deep-link selection always jumps INSTANTLY (the
    /// operator-reported "gehetzte Blätter-Animation" fix — no riffling through
    /// intermediate pages); an interactive selection animates only when motion is
    /// allowed, otherwise it too jumps instantly (reduce-motion contract). Pure +
    /// `nonisolated` so it is unit-testable without spinning up the view.
    nonisolated static func pageScrollTransition(
        source: PageSelectionSource,
        reduceMotion: Bool
    ) -> PageTransition {
        switch source {
        case .deepLink:
            .instant
        case .interactive:
            reduceMotion ? .instant : .animated
        }
    }

    /// Pure reconcile policy for the pager's FROZEN page list (`pagerOrder`).
    /// `nonisolated` + store-free so it is unit-testable without the view.
    ///
    /// **Why a frozen list (RCA `RCA-insights-swipe.md`):** the pager is a non-lazy
    /// `HStack` two-way-bound to `.scrollPosition(id:)`. The live ordered list
    /// GROWS asynchronously after mount (availability latch hydration + `@Observable`
    /// churn). Inserting a page BEFORE the page the operator is currently on shifts
    /// the visible content under a non-zero anchor → the "earlier pages reappear
    /// while swiping forward" + "springt beim Zurückgehen" bugs. We therefore only
    /// adopt a new order when doing so cannot move the current anchor.
    ///
    /// Adoption rules (in order):
    /// 1. **First population / empty current** → take `live` verbatim.
    /// 2. **`settledAtOverview`** (pager resting at index 0) → take `live`
    ///    verbatim. Re-ordering while index 0 is the anchor cannot move a non-zero
    ///    anchor (there isn't one), so this is always safe and is the natural
    ///    settling point where deferred growth is folded in.
    /// 3. **Pure suffix-append** → `live` keeps every element of `current` at the
    ///    SAME index and only appends new trailing pages. Appending after the last
    ///    page cannot shift any already-shown page, so it is safe even mid-swipe.
    /// 4. **`requiredTargets`** (current selection + any pending deep-link target)
    ///    that are missing from `current` but present in `live` are appended to the
    ///    tail so the pager can always show the selected/target page, without
    ///    reordering the existing prefix.
    /// 5. Otherwise **keep `current`** — defer the disruptive re-order until the
    ///    operator next returns to overview (rule 2).
    nonisolated static func reconciledPagerOrder(
        current: [InsightsTabSelection],
        live: [InsightsTabSelection],
        settledAtOverview: Bool,
        requiredTargets: [InsightsTabSelection]
    ) -> [InsightsTabSelection] {
        // 1. First population.
        if current.isEmpty { return live }
        // No change at all — cheapest path, keeps identity stable.
        if current == live { return current }
        // 2. Safe to fully adopt the live order when settled at index 0. `live` is
        // already category-contiguous (`ordered(...)` folds it), so no extra
        // `categoryContiguous` call is needed here.
        if settledAtOverview { return live }
        // 3. Pure suffix-append: `live` == `current` + new trailing pages — adopt
        // it as-is.
        //
        // V0150 anchor stability preserved: because `ordered(...)` now returns a
        // category-contiguous order, a metric that gains its first datum mid-session
        // is INSERTED into its category block in `live` (not appended at the tail),
        // so `live` is no longer a pure suffix-append of `current` and this branch
        // deliberately does NOT match for it — it falls to rule 4/5, which keeps the
        // frozen order under the live anchor until the operator next returns to
        // Übersicht (rule 2). Only genuine trailing pages take this fast path.
        if live.count >= current.count, Array(live.prefix(current.count)) == current {
            return live
        }
        // 4/5. Keep the current order (defer the reorder), but guarantee any
        // required target is reachable by appending it from `live`, then re-cluster
        // so a required target of an existing category joins that category's block
        // rather than trailing as a stray page (v0153, restored after `c8f1aa3b`).
        // A deep-link target is an instant jump, so the relayout is invisible.
        var result = current
        let present = Set(current)
        let liveSet = Set(live)
        var appended = false
        for target in requiredTargets where !present.contains(target) && liveSet.contains(target) {
            result.append(target)
            appended = true
        }
        return appended ? InsightsTabSelection.categoryContiguous(result) : result
    }

    // MARK: - Impure transitions (own the state, take live inputs as params)

    /// V0150 — reconcile `pagerOrder` from the live list, adopting a new order only
    /// when it cannot move the current anchor (see `reconciledPagerOrder`). Required
    /// targets = current selection + pending deep-link target, so a programmatic
    /// page is always reachable even while a disruptive reorder is deferred.
    ///
    /// `liveOrderedSelections` is computed by the View from its `@Environment`
    /// stores and passed in (the model holds no store reference).
    func reconcilePagerOrder(
        liveOrderedSelections: [InsightsTabSelection],
        forceFull: Bool = false
    ) {
        var required: [InsightsTabSelection] = [selection]
        if let pendingMetricTarget { required.append(pendingMetricTarget) }
        let next = Self.reconciledPagerOrder(
            current: pagerOrder,
            live: liveOrderedSelections,
            settledAtOverview: forceFull || (selection == .overview && scrolledID == .overview),
            requiredTargets: required
        )
        if next != pagerOrder { pagerOrder = next }
    }

    /// Mark `center` and its immediate neighbours (±1 in the FLAT pager page list)
    /// as realized, so their metric pages build (and stay built). Realization is
    /// monotonic: a page never reverts to a placeholder, preserving its scroll +
    /// warm store once visited.
    ///
    /// v0152 I1 — the window is over the FLAT pages (one page per metric). For a
    /// metric page in the window we realize its kind; overview / special pages
    /// carry no `ChartDetailStore`, so they're skipped. `pages` is the
    /// View-computed flat list.
    func realizeWindow(around center: InsightsTabSelection, pages: [InsightsPagerPage]) {
        guard let centerPage = InsightsPagerPage.page(for: center, in: pages),
              let index = pages.firstIndex(of: centerPage) else { return }
        let lower = max(pages.startIndex, index - 1)
        let upper = min(pages.index(before: pages.endIndex), index + 1)
        var realized = realizedMetrics
        for page in pages[lower ... upper] {
            if case let .flat(kind) = page {
                realized.insert(kind)
            }
        }
        if realized != realizedMetrics {
            realizedMetrics = realized
        }
    }

    /// #39/W-NAVANIM — drive the horizontal pager's `scrollPosition` to the new
    /// `selection`. A settled swipe is guarded out upstream (the pager already sits
    /// on `newValue`). The one-shot `pendingDeepLinkJump` flag tags this change
    /// `.deepLink` → instant jump; otherwise it is an in-Insights `.interactive`
    /// tap → animated slide (reduce-motion → instant).
    ///
    /// `pages` is the View-computed folded list; `reduceMotion` is the View's
    /// `@Environment(\.accessibilityReduceMotion)` value.
    func mirrorSelectionIntoScroll(
        _ newValue: InsightsTabSelection,
        pages: [InsightsPagerPage],
        reduceMotion: Bool
    ) {
        // v0152 I1 — map the selection to its own flat page id (1:1 per metric).
        guard let targetID = InsightsPagerPage.page(for: newValue, in: pages)?.scrollIdentity else { return }
        guard scrolledID != targetID else { return }
        let source: PageSelectionSource = pendingDeepLinkJump ? .deepLink : .interactive
        pendingDeepLinkJump = false
        // V0150 — a programmatic scroll is now in flight; mark it so the
        // `scrolledID → selection` mirror ignores the resolver echo this write
        // provokes (H2). Cleared when the resolver settles back on `targetID`, OR
        // by the timeout backstop (W-RECONCILE H-1) if the settle never lands the
        // exact target id. Bump the generation so the backstop only clears THIS
        // arming.
        programmaticScrollTarget = targetID
        programmaticScrollGeneration &+= 1
        switch Self.pageScrollTransition(source: source, reduceMotion: reduceMotion) {
        case .instant:
            scrolledID = targetID
        case .animated:
            withAnimation(.easeInOut(duration: 0.25)) { scrolledID = targetID }
        }
    }

    /// Fold the live availability into the latched union. Monotonic: only ever
    /// inserts, never removes — that is the whole point of the latch.
    func mergeSeenKinds(_ live: Set<MetricKind>) {
        let merged = seenKinds.union(live)
        if merged != seenKinds {
            seenKinds = merged
        }
    }

    /// W28c — fold the live special availability into the latched union. Monotonic,
    /// same contract as `mergeSeenKinds`.
    func mergeSeenSpecials(_ live: Set<InsightsSpecialPage>) {
        let merged = seenSpecials.union(live)
        if merged != seenSpecials {
            seenSpecials = merged
        }
    }

    /// v0152 I1 — the `selection` a SETTLED swipe to a page id should produce. The
    /// pager is flat (one page per metric), so each landed page id maps 1:1 to its
    /// own selection. `nil` if the landed page id isn't in the current flat list.
    func selectionForLandedPage(_ id: InsightsPagerPageID, pages: [InsightsPagerPage]) -> InsightsTabSelection? {
        for page in pages where page.scrollIdentity == id {
            switch page {
            case .overview:
                return .overview
            case let .flat(kind):
                return .metric(kind)
            case let .special(special):
                return .special(special)
            }
        }
        return nil
    }

    // MARK: - Inbound deep-link resolution

    /// v0.12 W0-1 — resolve the router's parked Insights metric slug onto the pager
    /// `selection`. Chartable slugs map to `.metric(kind)`; the special slugs map
    /// to `.special(page)`; an unknown or `nil` slug falls back to `.overview`.
    ///
    /// W0-fix (H1) — consumes a FRESH deep-linked metric request from the router
    /// (one-shot per `insightsMetricRequestCount` bump). A bare re-appear with no
    /// new bump returns `.none` and is a no-op. `router` is the View's
    /// `@Environment(AppRouter.self)`, passed in; `liveOrderedSelections`/`pages`
    /// are the View-computed inputs `tryApplyStagedMetric` needs.
    func stageInsightsMetricIfRequested(
        router: AppRouter,
        liveOrderedSelections: [InsightsTabSelection],
        pages: [InsightsPagerPage]
    ) {
        guard let slug = router.consumePendingInsightsMetric() else { return }
        guard let slug else {
            pendingMetricTarget = nil
            if selection != .overview { pendingDeepLinkJump = true } // W-NAVANIM jump
            selection = .overview
            return
        }
        let target: InsightsTabSelection
        if let kind = InsightsTabSlug.metricKind(forSlug: slug) {
            target = .metric(kind)
        } else if let page = InsightsSpecialPage.page(forSlug: slug) {
            target = .special(page)
        } else {
            pendingMetricTarget = nil
            if selection != .overview { pendingDeepLinkJump = true } // W-NAVANIM jump
            selection = .overview
            return
        }
        pendingMetricTarget = target
        tryApplyStagedMetric(liveOrderedSelections: liveOrderedSelections, pages: pages)
    }

    /// W0-fix (M2) — apply the staged deep-link target once its page exists in the
    /// ordered set. Never strands the pager on a missing page: if the target isn't
    /// available yet it stays staged and retries on the next ordered-set change.
    ///
    /// The View passes the live ordered list + folded pages; the model derives the
    /// frozen `orderedSelections` from its own `pagerOrder` (falling back to live).
    func tryApplyStagedMetric(
        liveOrderedSelections: [InsightsTabSelection],
        pages: [InsightsPagerPage]
    ) {
        guard let target = pendingMetricTarget else { return }
        let ordered = pagerOrder.isEmpty ? liveOrderedSelections : pagerOrder
        // V0150 — a deep link is an INSTANT jump, so a relayout under it is
        // invisible: force the frozen order to adopt the full live list now, so the
        // target page is guaranteed present before the jump.
        if !ordered.contains(target) {
            reconcilePagerOrder(liveOrderedSelections: liveOrderedSelections, forceFull: true)
        }
        let resolvedOrder = pagerOrder.isEmpty ? liveOrderedSelections : pagerOrder
        guard resolvedOrder.contains(target) else { return }
        // v0152 I1 — a deep link to a metric lands on that metric's OWN flat page
        // (the pager is one-page-per-metric); the strip then highlights the metric's
        // owning category pill, derived from the current selection. No per-group
        // member bookkeeping is needed any more.
        // W-NAVANIM — deep-link application: tag the selection change a one-shot
        // jump so the pager lands on the target page INSTANTLY (no riffle).
        if selection != target {
            pendingDeepLinkJump = true
            selection = target
        } else {
            // W-RECONCILE M-2 — deep-link to the metric that is ALREADY the
            // selection. `selection = target` would be a no-op `@Observable`
            // write, so the `onChange(of: selection)` mirror never fires and a
            // drifted `scrolledID` (mid-swipe / page reshape) is never re-aligned —
            // the jump silently does nothing. Force the scroll re-align directly.
            pendingDeepLinkJump = true
            mirrorSelectionIntoScroll(target, pages: pages, reduceMotion: false)
        }
        pendingMetricTarget = nil
    }
}
