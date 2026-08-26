import Foundation
@testable import HealthLog
import Testing

/// W-NAVANIM (operator-walk b190) — the Insights pager's page-scroll transition
/// policy. The operator reported that tapping a Home tile (e.g. Blutdruck) lands
/// in Insights/Blutdruck but with a "gehetzte" paging animation: the pager
/// visibly riffles through every intermediate page to the target. The fix is a
/// one-shot deep-link jump that sets the pager position WITHOUT animation, while
/// an in-Insights pill tap keeps its calm animated slide.
///
/// `InsightsPagerModel.pageScrollTransition(source:reduceMotion:)` is the
/// pure decision the view's `onChange(of: selection)` mirror uses to choose
/// between an animated scroll and a direct (instant) jump. Testing it directly
/// pins the policy that the SwiftUI plumbing cannot easily assert.
@Suite("Insights pager transition policy (W-NAVANIM)")
struct InsightsPagerTransitionTests {
    /// A deep-link jump (Home tile tap / inbound `.insights(metric:)`) must be
    /// INSTANT — no paging-through-intermediate-pages animation. This is the
    /// operator-reported "gehetzt" fix.
    @Test("deep-link source → instant jump, never animated")
    func deepLinkIsInstant() {
        #expect(InsightsPagerModel.pageScrollTransition(source: .deepLink, reduceMotion: false) == .instant)
        #expect(InsightsPagerModel.pageScrollTransition(source: .deepLink, reduceMotion: true) == .instant)
    }

    /// An in-Insights pill tap (or re-tap-to-root) keeps the calm animated slide
    /// when motion is allowed — the deliberate, swipe-like feel WITHIN Insights.
    @Test("interactive source + motion → animated slide")
    func interactiveAnimatesWithMotion() {
        #expect(InsightsPagerModel.pageScrollTransition(source: .interactive, reduceMotion: false) == .animated)
    }

    /// Reduce-motion downgrades the interactive slide to an instant jump — never
    /// animate when the operator has asked the system not to.
    @Test("interactive source + reduce-motion → instant jump")
    func interactiveInstantUnderReduceMotion() {
        #expect(InsightsPagerModel.pageScrollTransition(source: .interactive, reduceMotion: true) == .instant)
    }
}

/// V0150 (RCA-insights-swipe) — the FROZEN pager-order reconcile policy. The pager
/// is a non-lazy `HStack` two-way-bound to `.scrollPosition(id:)`; the live ordered
/// list grows asynchronously after mount (availability latch hydration), and
/// inserting a page BEFORE the page the operator is on shifts the visible content
/// under a non-zero anchor — the operator's "earlier pages reappear while swiping
/// forward" + "springt beim Zurückgehen" bugs. `reconciledPagerOrder` adopts a new
/// order only when doing so cannot move the current anchor. These tests pin that
/// invariant (selection stable under simulated latch growth; ordered list stable).
@Suite("Insights pager frozen-order reconcile (V0150)")
struct InsightsPagerOrderReconcileTests {
    private let overview = InsightsTabSelection.overview
    private let bmi = InsightsTabSelection.metric(.bmi)
    private let weight = InsightsTabSelection.metric(.weight)
    private let energy = InsightsTabSelection.metric(.activeEnergy)
    private let pulse = InsightsTabSelection.metric(.pulse)

    /// First population: an empty current order takes the live list verbatim.
    @Test("first population adopts the live list")
    func firstPopulationAdoptsLive() {
        let live = [overview, bmi, weight]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: [], live: live, settledAtOverview: false, requiredTargets: [overview]
        )
        #expect(result == live)
    }

    /// THE BUG: while the operator sits on a non-overview page (BMI), a newly-lit
    /// kind that sorts BEFORE BMI must NOT be inserted — that is the insertion that
    /// shifts the anchor and reappears earlier pages. The frozen order is kept.
    @Test("mid-swipe insertion before current page is deferred (anchor stable)")
    func insertionBeforeCurrentIsDeferred() {
        let current = [overview, bmi]
        // Availability hydration lights up active energy + pulse, which sort BEFORE
        // bmi in the server layout — a classic mid-session insert.
        let live = [overview, energy, pulse, bmi]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: current, live: live, settledAtOverview: false, requiredTargets: [bmi]
        )
        #expect(result == current) // unchanged — no yank under the swipe
    }

    /// A pure suffix-append (new pages only at the tail) is safe even mid-swipe:
    /// appending after the last page cannot move any already-shown page.
    @Test("pure suffix-append is adopted even mid-swipe")
    func suffixAppendIsAdopted() {
        let current = [overview, bmi]
        let live = [overview, bmi, weight, pulse]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: current, live: live, settledAtOverview: false, requiredTargets: [bmi]
        )
        #expect(result == live)
    }

    /// Settled back at overview (index 0): a reorder there cannot move a non-zero
    /// anchor, so the full live list is adopted — the deferred growth folds in.
    @Test("settled at overview adopts the full live order")
    func settledAtOverviewAdoptsLive() {
        let current = [overview, bmi]
        let live = [overview, energy, pulse, bmi]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: current, live: live, settledAtOverview: true, requiredTargets: [overview]
        )
        #expect(result == live)
    }

    /// A required target (deep link / current selection) absent from the kept
    /// order is tail-appended so the pager can always show it — without reordering
    /// the existing prefix (the anchor stays put).
    @Test("required target absent from kept order is tail-appended")
    func requiredTargetIsAppended() {
        let current = [overview, bmi]
        // weight lit up and is the deep-link target; energy also lit (before bmi)
        // but is NOT required, so it must NOT be inserted.
        let live = [overview, energy, bmi, weight]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: current, live: live, settledAtOverview: false, requiredTargets: [weight]
        )
        #expect(result == [overview, bmi, weight]) // weight appended, energy deferred
    }

    /// Idempotent: when live == current, the same identity is returned (no churn).
    @Test("no change when live equals current")
    func noChangeWhenEqual() {
        let order = [overview, bmi, weight]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: order, live: order, settledAtOverview: false, requiredTargets: [bmi]
        )
        #expect(result == order)
    }

    /// Selection stability across repeated latch growth while away from overview:
    /// the page the operator is on (bmi) stays at its index through several
    /// hydration steps, so `selection` never gets yanked.
    @Test("selection page index is stable across repeated latch growth")
    func selectionStableUnderRepeatedGrowth() {
        var current = [overview, bmi]
        let growthSteps = [
            [overview, energy, bmi],
            [overview, energy, pulse, bmi],
            [overview, energy, pulse, weight, bmi]
        ]
        for live in growthSteps {
            current = InsightsPagerModel.reconciledPagerOrder(
                current: current, live: live, settledAtOverview: false, requiredTargets: [bmi]
            )
            // bmi must remain present at the SAME index it had (1) — never shifted.
            #expect(current.firstIndex(of: bmi) == 1)
        }
    }

    // Two `.heart` siblings (resting pulse + pulse) — used to exercise the reconcile
    // paths: rule 3 (pure suffix) stays verbatim; rule 4 (required-target append)
    // re-clusters (v0153 restored after `c8f1aa3b`).
    private let restingPulse = InsightsTabSelection.metric(.restingHeartRate)
    private let pulse2 = InsightsTabSelection.metric(.pulse)

    /// Rule 3 (pure suffix-append) adopts `live` VERBATIM — it does NOT recluster.
    /// This preserves the V0150 anchor: because `ordered(...)` now returns a
    /// category-contiguous order, a mid-session grouped member is INSERTED into its
    /// category block in the live list (not appended at the tail), so it is never a
    /// pure suffix-append and never reaches this branch — it falls to rule 4/5 and
    /// defers until the operator returns to Übersicht. Only genuine trailing pages
    /// take this fast path, and they are adopted at the tail, unmoved.
    @Test("pure suffix-append is adopted verbatim — no reclustering under the live anchor")
    func suffixAppendIsNotReclustered() {
        let current = [overview, restingPulse, weight]
        // A genuine trailing page appears (pure suffix-append of `current`).
        let live = [overview, restingPulse, weight, pulse2]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: current, live: live, settledAtOverview: false, requiredTargets: [restingPulse]
        )
        // Verbatim — the new page stays at the tail, weight keeps its slot, the
        // anchor (restingPulse at index 1) never moves.
        #expect(result == live)
        #expect(result.firstIndex(of: restingPulse) == 1)
    }

    /// INVERTED (was `requiredTargetAppendIsNotReclustered`, added by `c8f1aa3b` to
    /// cement the removal of v0153's clustering). Rule 4 restored: a required
    /// deep-link target appended via the keep-current branch re-clusters into its
    /// category block rather than trailing as a stray page. A deep-link is an
    /// instant jump, so the relayout is invisible; the payoff is that the target
    /// sits adjacent to its siblings, so a subsequent swipe walks the category
    /// cleanly (pill N ↔ page N) instead of jumping out.
    @Test("required-target append re-clusters into its category block (v0153 restored)")
    func requiredTargetAppendReclusters() {
        let current = [overview, restingPulse, bmi]
        // Pulse lit up (a heart sibling) AND is the deep-link target; energy also
        // lit before bmi but is not required, so it stays deferred.
        let live = [overview, energy, restingPulse, bmi, pulse2]
        let result = InsightsPagerModel.reconciledPagerOrder(
            current: current, live: live, settledAtOverview: false, requiredTargets: [pulse2]
        )
        // pulse2 (heart) clusters up next to its sibling restingPulse; bmi shifts
        // right; energy stays deferred (not required).
        #expect(result == [overview, restingPulse, pulse2, bmi])
        #expect(!result.contains(energy))
    }
}

/// v0152 I1 (operator-confirmed reversal of the b198 grouped pager) — the FLAT
/// category-aware pager. The b198/V0151 grouped pager made a category ONE swipe
/// stop with an in-page member switch; the operator rejected it. The replacement:
/// the pager is a single continuous flat sequence over EVERY metric (one page per
/// metric, in category order), while the STRIP stays category-aware (a category
/// pill that highlights for any of its members; a tap jumps to its FIRST member).
///
/// These lock the contract:
///   - the pager is FLAT (one page per metric — vitals members are NOT folded);
///   - the strip FOLDS a multi-member category into ONE category pill (presentation);
///   - the ACTIVE strip pill is derived from the current metric's owning category,
///     so it stays highlighted while swiping through that category's members;
///   - tapping a category pill jumps to the category's FIRST member;
///   - swiping past a category's last member advances to the next pill's metric.
@Suite("Insights flat category-aware pager (v0152 I1)")
struct InsightsFlatCategoryPagerTests {
    private let overview = InsightsTabSelection.overview
    /// Parity Build 4 — `weight` is one of the web's five PINNED slugs, so it is
    /// the flat standalone here (BMI moved into the `body` group).
    private let weight = InsightsTabSelection.metric(.weight)
    /// Three `.heart` members, consecutive in the fixture order.
    private let restingPulse = InsightsTabSelection.metric(.restingHeartRate)
    private let hrv = InsightsTabSelection.metric(.hrv)
    private let pulse = InsightsTabSelection.metric(.pulse)
    private let workouts = InsightsTabSelection.special(.workouts)

    /// overview · Gewicht (pinned/standalone) · 3 heart members · Workouts.
    private var ordered: [InsightsTabSelection] {
        [overview, weight, restingPulse, hrv, pulse, workouts]
    }

    /// THE PAGER IS FLAT: the three vitals members are THREE pages, NOT one group
    /// page. The pager `ForEach` walks every metric, so a swipe is metric-by-metric.
    @Test("the pager is flat — every metric is its own page (no group fold)")
    func pagerIsFlat() {
        let pages = InsightsPagerPage.pages(from: ordered)
        #expect(pages == [
            .overview, .flat(.weight), .flat(.restingHeartRate),
            .flat(.hrv), .flat(.pulse), .special(.workouts)
        ])
        #expect(pages.count == ordered.count)
    }

    /// Swiping RIGHT from Gewicht walks the heart members IN ORDER (resting → hrv
    /// → pulse), one page each, then Workouts — the operator's confirmed sequence.
    @Test("swipe right from Gewicht walks heart members in order, then Workouts")
    func swipeFromStandaloneWalksMembersInOrder() {
        let pages = InsightsPagerPage.pages(from: ordered)
        guard let weightPage = InsightsPagerPage.page(for: weight, in: pages),
              let i = pages.firstIndex(of: weightPage) else
        { Issue.record("Gewicht page missing")
            return
        }
        #expect(pages[i + 1] == .flat(.restingHeartRate)) // first heart member
        #expect(pages[i + 2] == .flat(.hrv))
        #expect(pages[i + 3] == .flat(.pulse)) // last heart member
        #expect(pages[i + 4] == .special(.workouts)) // crosses into the next pill
    }

    /// The STRIP folds the 3 heart members into ONE "Herz" category pill
    /// (presentation), while Gewicht stays a pinned standalone pill and Workouts —
    /// activity's only available member here — collapses back to a special pill.
    @Test("the strip folds a multi-member category into one pill; standalones stay flat")
    func stripFoldsCategoryPill() {
        let strip = InsightsStripEntry.strip(from: ordered)
        // overview · Gewicht(flat) · Herz(group) · Workouts(special) — 4 pills.
        #expect(strip.count == 4)
        #expect(strip[0] == .overview)
        #expect(strip[1] == .flat(.weight))
        guard case let .group(category, members) = strip[2] else {
            Issue.record("expected a category pill at index 2, got \(strip[2])")
            return
        }
        #expect(category == .heart)
        #expect(members == [.metric(.restingHeartRate), .metric(.hrv), .metric(.pulse)])
        #expect(strip[3] == .special(.workouts))
    }

    /// The ACTIVE strip pill is the owning CATEGORY of the current metric — so it
    /// stays "Vitalwerte" the WHOLE time the operator swipes through resting →
    /// active → spo2, and only flips when crossing into another pill's metric. This
    /// is what fixes the b198 strip/pager divergence (both are category-aware over
    /// ONE flat sequence).
    @Test("the active strip pill follows the current metric's owning category")
    func activePillFollowsCurrentMetricCategory() {
        // Every heart member maps to the SAME owning category → the Herz pill
        // stays highlighted across the whole swipe through the category.
        for member: MetricKind in [.restingHeartRate, .hrv, .pulse] {
            #expect(InsightsCategoryGroups.category(for: member) == .heart)
        }
        // Gewicht is pinned (no category) → its own pill, never the Herz pill.
        #expect(InsightsCategoryGroups.category(for: .weight) == nil)
    }

    /// Tapping a category pill jumps to that category's FIRST member (the strip's
    /// category pill selects `members.first`). The pager then lands on that metric's
    /// own flat page. This is the operator's "tap Vitalwerte → Sauerstoffsättigung"
    /// when SpO₂ is first, or resting-pulse here (first vitals member in order).
    @Test("tapping a category pill targets the category's first member")
    func categoryPillTargetsFirstMember() {
        let strip = InsightsStripEntry.strip(from: ordered)
        guard case let .group(_, members) = strip[2] else {
            Issue.record("expected a category pill at index 2")
            return
        }
        // The pill's tap target is the first member, and that member has its OWN
        // flat pager page (1:1).
        #expect(members.first == .metric(.restingHeartRate))
        let pages = InsightsPagerPage.pages(from: ordered)
        #expect(InsightsPagerPage.page(for: .metric(.restingHeartRate), in: pages) == .flat(.restingHeartRate))
    }

    /// A single-member category does NOT fold to a category pill — it stays a flat
    /// (standalone) pill, and its single flat page (operator doctrine: no 1-item
    /// menus / category pills). The pager stays flat either way.
    @Test("a one-member category stays a flat standalone pill + page")
    func singleMemberCategoryStaysFlat() {
        let single: [InsightsTabSelection] = [overview, weight, hrv, workouts]
        let strip = InsightsStripEntry.strip(from: single)
        // hrv is the only heart member → a flat pill, not a category pill.
        #expect(strip.contains(.flat(.hrv)))
        #expect(!strip.contains { if case .group = $0 { true } else { false } })
        let pages = InsightsPagerPage.pages(from: single)
        #expect(pages.contains(.flat(.hrv)))
        #expect(pages.count == 4)
    }
}
