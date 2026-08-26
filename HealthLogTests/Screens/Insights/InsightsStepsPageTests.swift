import Foundation
@testable import HealthLog
import Testing

/// v0152 I2 — the missing Steps Insights detail page. The Home dashboard renders a
/// distinct `MetricKind.steps` tile, but tapping it dead-ended: `.steps` had no
/// Insights slug, so `AppRouter.selectInsightsMetric(.steps)` no-op'd and no Steps
/// subpage existed. The fix maps the `steps` slug ↔ `.steps` end-to-end.
///
/// **Parity Build 4 / 4.1** — the tail-append is gone: `steps` is a first-class
/// `SUB_PAGE_METRIC` key on the web (since v1.12) and therefore part of the
/// server's `INSIGHTS_TILE_IDS`, so it is in `serverKnownIds` and reaches the
/// strip through its curated layout slot. That also restores the operator's
/// order/visibility choice for Steps, which `filteringForServer()` used to strip
/// out of every PUT.
@Suite("Insights Steps page resolves (v0152 I2, rewired in Build 4)")
struct InsightsStepsPageTests {
    /// The `steps` slug maps to `.steps` (forward + reverse) — so the Home steps
    /// tile's deep link (`selectInsightsMetric(.steps)` → `slug(forKind:)`) resolves
    /// and the parked slug rehydrates onto a `.metric(.steps)` selection.
    @Test("the steps slug maps to MetricKind.steps both ways")
    func stepsSlugMapsBothWays() {
        #expect(InsightsTabSlug.metricKind(forSlug: InsightsLayoutTileId.steps) == .steps)
        #expect(InsightsTabSlug.metricKind(forSlug: "steps") == .steps)
        #expect(InsightsTabSlug.slug(forKind: .steps) == InsightsLayoutTileId.steps)
        #expect(InsightsLayoutTileId.steps == "steps")
    }

    /// b215 IC — Steps folds into the `activity` category (it used to render as its
    /// own standalone top-level pill). The pager stays flat (one page per metric),
    /// so the Steps page is unaffected; only the strip now folds it under the
    /// Aktivität group pill instead of showing a separate "Schritte" item.
    @Test("steps belongs to the activity category")
    func stepsIsInActivity() {
        #expect(InsightsCategoryGroups.category(for: .steps) == .activity)
    }

    /// Build 4 — `steps` is server-known, so a layout PUT carries it and the
    /// operator's Steps order/visibility survives the round-trip. Keeping it out
    /// of `serverKnownIds` was what made `filteringForServer()` drop it.
    @Test("the steps slug is server-known and survives a PUT filter")
    func stepsIsServerKnown() {
        #expect(InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.steps))
        let layout = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.steps, visible: true, order: 1)
        ])
        #expect(layout.filteringForServer().tiles.contains { $0.id == InsightsLayoutTileId.steps })
    }

    /// Steps now reaches the strip through its curated layout slot — no append.
    @Test("ordered() places Steps at its layout slot, gated on data")
    func orderedPlacesStepsAtLayoutSlot() {
        let layout = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.steps, visible: true, order: 1),
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 2)
        ])
        // No step data → no Steps selection (never a dead pill).
        let withoutSteps = InsightsTabSelection.ordered(layout: layout, availableKinds: [.weight])
        #expect(withoutSteps == [.overview, .metric(.weight)])

        // Step data present → Steps sits at its curated slot, BEFORE weight.
        let withSteps = InsightsTabSelection.ordered(layout: layout, availableKinds: [.weight, .steps])
        #expect(withSteps == [.overview, .metric(.steps), .metric(.weight)])
    }

    /// A layout that does NOT enumerate `steps` no longer synthesises a pill. The
    /// server's resolver auto-merges the tile onto older saved layouts
    /// (`src/lib/insights-layout.ts:229-243`), so on a real account this case only
    /// arises offline against the local bootstrap default.
    @Test("a layout without a steps tile produces no Steps pill")
    func orderedOmitsStepsWithoutTile() {
        let layout = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 1)
        ])
        let ordered = InsightsTabSelection.ordered(layout: layout, availableKinds: [.weight, .steps])
        #expect(ordered == [.overview, .metric(.weight)])
    }

    /// The Steps selection resolves to a real flat pager page (so the Home tile +
    /// the pager both land on a Steps `InsightsMetricScreen`).
    @Test("the Steps selection resolves to a flat pager page")
    func stepsResolvesToFlatPage() {
        let layout = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.steps, visible: true, order: 1)
        ])
        let ordered = InsightsTabSelection.ordered(layout: layout, availableKinds: [.steps])
        let pages = InsightsPagerPage.pages(from: ordered)
        #expect(InsightsPagerPage.page(for: .metric(.steps), in: pages) == .flat(.steps))
    }
}
