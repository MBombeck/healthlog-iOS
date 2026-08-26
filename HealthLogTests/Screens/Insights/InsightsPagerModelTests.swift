import Foundation
@testable import HealthLog
import Testing

/// v0152 I1 — unit tests for the FLAT category-aware pager state machine. The
/// b198 grouped pager (one category = one page with an in-page member switch) was
/// reversed: the pager is now a single continuous flat sequence over EVERY metric
/// in category order, one page per metric. The strip stays category-aware (a
/// category pill highlights for any of its members) — but that is a presentation
/// layer; the pager and its `InsightsPagerModel` are purely flat.
///
/// These drive the INSTANCE methods directly (the pure static policy lives in
/// `InsightsPagerTransitionTests`). They lock: ±1 monotonic realization over the
/// flat pages, monotonic availability latches, and the landed-page → selection
/// fold (now 1:1 per metric — no group-member resolution).
@MainActor
@Suite("Insights pager model (flat state machine)")
struct InsightsPagerModelTests {
    private let overview = InsightsTabSelection.overview
    private let bmi = InsightsTabSelection.metric(.bmi)
    private let workouts = InsightsTabSelection.special(.workouts)
    // Three vitals members — in the FLAT pager each is its OWN page.
    private let restingPulse = InsightsTabSelection.metric(.restingHeartRate)
    private let activeEnergy = InsightsTabSelection.metric(.activeEnergy)
    private let oxygen = InsightsTabSelection.metric(.spo2)

    /// overview · BMI · resting · active · spo2 · Workouts — a flat sequence with
    /// the three vitals members consecutive (category order), each its own page.
    private var ordered: [InsightsTabSelection] {
        [overview, bmi, restingPulse, activeEnergy, oxygen, workouts]
    }

    private var pages: [InsightsPagerPage] {
        InsightsPagerPage.pages(from: ordered)
    }

    // MARK: - flat pages: one per metric, 1:1

    @Test("pages are flat — one page per selection, no group fold")
    func pagesAreFlat() {
        #expect(pages.count == ordered.count)
        #expect(pages == [
            .overview, .flat(.bmi), .flat(.restingHeartRate),
            .flat(.activeEnergy), .flat(.spo2), .special(.workouts)
        ])
        // No grouping: every vitals member resolves to its OWN distinct page id.
        let ids = [restingPulse, activeEnergy, oxygen].compactMap {
            InsightsPagerPage.page(for: $0, in: pages)?.scrollIdentity
        }
        #expect(ids == [.metric(.restingHeartRate), .metric(.activeEnergy), .metric(.spo2)])
        #expect(Set(ids).count == 3) // all distinct (no shared category id)
    }

    // MARK: - realizeWindow: ±1, monotonic, flat

    @Test("realizeWindow realizes only the ±1 metric pages and stays monotonic")
    func realizeWindowIsPlusMinusOneAndMonotonic() {
        let model = InsightsPagerModel()
        // Center on resting (page index 2). Neighbours: BMI(1) + active(3). overview
        // has no kind. So: {.bmi, .restingHeartRate, .activeEnergy}.
        model.realizeWindow(around: restingPulse, pages: pages)
        #expect(model.realizedMetrics == [.bmi, .restingHeartRate, .activeEnergy])

        // Move to active (3): window resting(2) · active(3) · spo2(4). resting stays
        // (monotonic), spo2 added. Nothing removed.
        model.realizeWindow(around: activeEnergy, pages: pages)
        #expect(model.realizedMetrics.contains(.restingHeartRate)) // never reverts
        #expect(model.realizedMetrics.contains(.activeEnergy))
        #expect(model.realizedMetrics.contains(.spo2))
        // BMI stays realized too (monotonic — it left the window but was visited).
        #expect(model.realizedMetrics.contains(.bmi))
    }

    @Test("realizeWindow skips overview + special pages (no chart store)")
    func realizeWindowSkipsNonMetricPages() {
        let model = InsightsPagerModel()
        // Center on overview (0): neighbour is BMI(1). overview carries no kind.
        model.realizeWindow(around: overview, pages: pages)
        #expect(model.realizedMetrics == [.bmi])
        // Center on spo2 (4): neighbours active(3) + Workouts(5, special → no kind).
        model.realizeWindow(around: oxygen, pages: pages)
        #expect(model.realizedMetrics.contains(.activeEnergy))
        #expect(model.realizedMetrics.contains(.spo2))
    }

    // MARK: - availability latches: monotonic union only

    @Test("mergeSeenKinds only grows the latched union")
    func mergeSeenKindsIsMonotonic() {
        let model = InsightsPagerModel()
        model.mergeSeenKinds([.bmi, .weight])
        #expect(model.seenKinds == [.bmi, .weight])
        // A transient revalidation that drops weight must NOT shrink the latch.
        model.mergeSeenKinds([.bmi])
        #expect(model.seenKinds == [.bmi, .weight])
        // New kinds still get added.
        model.mergeSeenKinds([.pulse])
        #expect(model.seenKinds == [.bmi, .weight, .pulse])
    }

    @Test("mergeSeenSpecials only grows the latched union")
    func mergeSeenSpecialsIsMonotonic() {
        let model = InsightsPagerModel()
        model.mergeSeenSpecials([.mood, .workouts])
        #expect(model.seenSpecials == [.mood, .workouts])
        model.mergeSeenSpecials([.mood]) // workouts briefly empty → stays latched
        #expect(model.seenSpecials == [.mood, .workouts])
    }

    // MARK: - selectionForLandedPage: flat 1:1

    @Test("selectionForLandedPage maps each flat page id to its own selection")
    func selectionForLandedPageIs1to1() {
        let model = InsightsPagerModel()
        // Every metric page id maps to its own metric selection (no group fold).
        #expect(model.selectionForLandedPage(.metric(.restingHeartRate), pages: pages) == .metric(.restingHeartRate))
        #expect(model.selectionForLandedPage(.metric(.spo2), pages: pages) == .metric(.spo2))
        #expect(model.selectionForLandedPage(.metric(.bmi), pages: pages) == .metric(.bmi))
        // overview maps to overview; special maps to special.
        #expect(model.selectionForLandedPage(.overview, pages: pages) == .overview)
        #expect(model.selectionForLandedPage(.special(.workouts), pages: pages) == .special(.workouts))
        // A page id absent from the flat list → nil.
        #expect(model.selectionForLandedPage(.metric(.weight), pages: pages) == nil)
    }

    @Test("selectionForLandedPage round-trips each neighbour page (±1) back to its own selection")
    func selectionForLandedPageRoundtripsNeighbours() {
        // A neighbour swipe from page i lands on page i±1, whose scroll id must fold
        // back to exactly ordered[i±1] — one swipe = exactly one step (pill N ↔ page
        // N). Guards the swipe-order contract restored after `c8f1aa3b`.
        let model = InsightsPagerModel()
        let sels = ordered
        let ps = pages
        for i in sels.indices {
            if i > 0 {
                #expect(model.selectionForLandedPage(ps[i - 1].scrollIdentity, pages: ps) == sels[i - 1])
            }
            if i < sels.count - 1 {
                #expect(model.selectionForLandedPage(ps[i + 1].scrollIdentity, pages: ps) == sels[i + 1])
            }
        }
    }

    // MARK: - W-RECONCILE H-1: programmatic-scroll latch self-clear

    @Test("mirrorSelectionIntoScroll arms the latch and bumps the generation")
    func mirrorArmsLatchAndBumpsGeneration() {
        let model = InsightsPagerModel()
        let before = model.programmaticScrollGeneration
        model.mirrorSelectionIntoScroll(bmi, pages: pages, reduceMotion: true)
        #expect(model.programmaticScrollTarget != nil)
        #expect(model.programmaticScrollGeneration == before + 1)
    }

    @Test("clearStaleProgrammaticScroll clears a stuck latch for the same generation")
    func timeoutBackstopClearsStuckLatch() {
        let model = InsightsPagerModel()
        model.mirrorSelectionIntoScroll(bmi, pages: pages, reduceMotion: true)
        let armed = model.programmaticScrollGeneration
        #expect(model.programmaticScrollTarget != nil)
        // The settle write never landed the exact target id → the backstop fires.
        #expect(model.clearStaleProgrammaticScroll(generation: armed) == true)
        #expect(model.programmaticScrollTarget == nil)
    }

    @Test("clearStaleProgrammaticScroll is a no-op for a stale generation")
    func timeoutBackstopIgnoresSupersededArming() {
        let model = InsightsPagerModel()
        model.mirrorSelectionIntoScroll(bmi, pages: pages, reduceMotion: true)
        let firstArming = model.programmaticScrollGeneration
        // A newer programmatic scroll re-arms before the first backstop deadline.
        model.mirrorSelectionIntoScroll(oxygen, pages: pages, reduceMotion: true)
        // The first backstop must NOT un-latch the fresh in-flight scroll.
        #expect(model.clearStaleProgrammaticScroll(generation: firstArming) == false)
        #expect(model.programmaticScrollTarget != nil)
    }

    @Test("clearStaleProgrammaticScroll is a no-op when no latch is armed")
    func timeoutBackstopNoOpWhenUnlatched() {
        let model = InsightsPagerModel()
        #expect(model.clearStaleProgrammaticScroll(generation: model.programmaticScrollGeneration) == false)
        #expect(model.programmaticScrollTarget == nil)
    }

    // MARK: - W-RECONCILE M-2: deep-link to the already-selected metric re-aligns

    @Test("deep-link to the already-selected metric forces a scroll re-align")
    func deepLinkToCurrentSelectionReAlignsScroll() {
        let model = InsightsPagerModel()
        // Land on BMI as the current selection, then drift the scroll away.
        model.selection = bmi
        model.scrolledID = .overview
        model.programmaticScrollTarget = nil
        // Stage a deep link to the SAME metric that is already the selection.
        model.pendingMetricTarget = bmi
        model.tryApplyStagedMetric(liveOrderedSelections: ordered, pages: pages)
        // The mirror must have re-armed the scroll toward BMI even though
        // `selection` did not change (the M-2 silent no-op is fixed).
        #expect(model.scrolledID == .metric(.bmi))
        #expect(model.pendingMetricTarget == nil)
    }
}
