import Foundation
@testable import HealthLog
import Testing

/// 1.4 C1 — a deep link to a data-gated special page (mood / medications /
/// ECG) on an account without that data.
///
/// The sweep walk `test_14` opened `healthlog://insights/mood` and `/ecg` right
/// after `/workouts` and photographed two blank pages without a header or an
/// empty state. The link could never land (the strip offers no such page), yet
/// the staged retry forced the frozen pager order onto the live one while the
/// pager stood on Workouts. Pages inserted before Workouts moved under the
/// scroll offset, which then rested on an unrealized metric placeholder.
@MainActor
@Suite("Insights deep link to an empty special page")
struct InsightsDeepLinkEmptySpecialTests {
    private let workouts = InsightsTabSelection.special(.workouts)
    private let mood = InsightsTabSelection.special(.mood)

    private var layout: InsightsLayout {
        let slugs = [
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.mood,
            InsightsLayoutTileId.medications,
            InsightsLayoutTileId.workouts
        ]
        let tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
            + slugs.enumerated().map { idx, slug in
                InsightsLayoutTile(id: slug, visible: true, order: idx + 1)
            }
        return InsightsLayout(tiles: tiles)
    }

    private func order(
        kinds: Set<MetricKind>,
        specials: Set<InsightsSpecialPage>
    ) -> [InsightsTabSelection] {
        InsightsTabSelection.ordered(layout: layout, availableKinds: kinds, availableSpecials: specials)
    }

    private let specials: Set<InsightsSpecialPage> = [.recovery, .medications, .workouts]

    /// The order the pager froze when Insights first opened on a special page,
    /// before the measurement kinds hydrated.
    private var frozen: [InsightsTabSelection] {
        order(kinds: [], specials: specials)
    }

    /// The live order since: metric pages grown in front of Workouts.
    private var live: [InsightsTabSelection] {
        order(kinds: [.weight, .pulse], specials: specials)
    }

    /// The sweep's state: the pager stands on Workouts over the frozen order.
    private func modelOnWorkouts() -> InsightsPagerModel {
        let model = InsightsPagerModel()
        model.pagerOrder = frozen
        model.seenSpecials = specials
        model.selection = workouts
        model.scrolledID = .special(.workouts)
        return model
    }

    @Test("an unreachable deep-link target leaves the frozen order under the pager alone")
    func unreachableTargetKeepsFrozenOrder() throws {
        let model = modelOnWorkouts()
        let workoutsIndex = try #require(frozen.firstIndex(of: workouts))
        #expect(live.firstIndex(of: workouts) != workoutsIndex, "the live order must shift Workouts")

        model.pendingMetricTarget = mood
        model.tryApplyStagedMetric(liveOrderedSelections: live, pages: InsightsPagerPage.pages(from: frozen))

        // Adopting `live` here would shift every page from Workouts on to the
        // right under an unchanged scroll offset: the blank page of the sweep.
        #expect(model.pagerOrder == frozen)
        #expect(model.selection == workouts)
        #expect(model.pendingMetricTarget == mood)
    }

    @Test("the link waits while the page's source has not answered")
    func unsettledSourceKeepsLinkStaged() {
        let model = modelOnWorkouts()
        model.pendingMetricTarget = mood
        #expect(model.admitStagedSpecialIfSettled() == false)
        #expect(!model.seenSpecials.contains(.mood))
        #expect(model.pendingMetricTarget == mood)
    }

    @Test("once the source answered empty the link lands on the page")
    func settledEmptySourceLandsOnPage() {
        let model = modelOnWorkouts()
        model.pendingMetricTarget = mood
        model.markSpecialSettled(.mood)

        #expect(model.admitStagedSpecialIfSettled())
        #expect(model.seenSpecials.contains(.mood))

        // The container recomputes the live order from the grown latch.
        let live = order(kinds: [.weight, .pulse], specials: model.seenSpecials)
        model.tryApplyStagedMetric(liveOrderedSelections: live, pages: InsightsPagerPage.pages(from: live))

        #expect(model.selection == mood)
        #expect(model.pagerOrder.contains(mood))
        #expect(model.pendingMetricTarget == nil)
        // The selection change is a deep-link jump; the container's mirror
        // then scrolls by page id, so the reordered pages cannot strand it.
        #expect(model.pendingDeepLinkJump)
    }

    @Test("the same holds for ECG, which no layout tile places")
    func settledEmptyEcgLandsOnPage() {
        let model = modelOnWorkouts()
        model.pendingMetricTarget = .special(.ecg)
        model.markSpecialSettled(.ecg)
        #expect(model.admitStagedSpecialIfSettled())

        let live = order(kinds: [.weight, .pulse], specials: model.seenSpecials)
        model.tryApplyStagedMetric(liveOrderedSelections: live, pages: InsightsPagerPage.pages(from: live))
        #expect(model.selection == .special(.ecg))
    }

    @Test("admission touches only a staged special target whose source answered")
    func admissionIsNarrow() {
        let model = InsightsPagerModel()
        model.markSpecialSettled(.mood)
        // No staged link.
        #expect(model.admitStagedSpecialIfSettled() == false)
        // A staged metric link.
        model.pendingMetricTarget = .metric(.weight)
        #expect(model.admitStagedSpecialIfSettled() == false)
        // A staged special whose source has not answered.
        model.pendingMetricTarget = .special(.ecg)
        #expect(model.admitStagedSpecialIfSettled() == false)
        #expect(model.seenSpecials.isEmpty)
    }
}
