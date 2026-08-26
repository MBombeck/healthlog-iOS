import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.1 — strip-customise contract: the operator can reorder the Insights
/// top tab-strip + show/hide individual metric tabs, and "Übersicht" stays the
/// mandatory, always-first pill. Pure value-type math over `InsightsLayout` +
/// `InsightsTabSelection.ordered` — no view, no store.
@Suite("Insights tab-strip customisation — reorder / show-hide / overview-pinned")
struct InsightsStripCustomizationTests {
    /// Layout with overview first (visible) + the given slugs in order. Every
    /// slug visible unless listed in `hidden`.
    private func layout(_ slugs: [String], hidden: Set<String> = []) -> InsightsLayout {
        var tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
        for (offset, slug) in slugs.enumerated() {
            tiles.append(InsightsLayoutTile(id: slug, visible: !hidden.contains(slug), order: offset + 1))
        }
        return InsightsLayout(tiles: tiles)
    }

    /// Every kind available, so these tests exercise the LAYOUT-driven sequence
    /// alone. Parity Build 4 removed the `.steps` tail-append (steps is a real
    /// layout slug now), so no kind needs excluding any more — an available kind
    /// appears if and only if the layout carries a visible tile for it.
    private let allKinds: Set<MetricKind> = Set(MetricKind.allCases)

    // MARK: - Reorder persists into the strip order

    @Test("reorder of layout reflects in the strip ordered selections")
    func reorderReflectsInStrip() {
        let start = layout([
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.pulse
        ])
        // Operator drags pulse before weight (overview force-prepended, as the
        // customise screen's moveTiles does).
        let reordered = start.reordering([
            InsightsLayoutTileId.overview,
            InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.weight
        ])
        let ordered = InsightsTabSelection.ordered(
            layout: reordered,
            availableKinds: allKinds
        )
        #expect(ordered == [.overview, .metric(.pulse), .metric(.weight)])
    }

    // MARK: - Hiding a metric removes it from strip + pager

    @Test("hiding a metric removes it from the strip + the pager order")
    func hidingRemovesFromStrip() {
        let start = layout([
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.pulse
        ])
        let hidden = start.togglingVisibility(forId: InsightsLayoutTileId.weight)
        let ordered = InsightsTabSelection.ordered(
            layout: hidden,
            availableKinds: allKinds
        )
        #expect(!ordered.contains(.metric(.weight)))
        #expect(ordered.contains(.metric(.pulse)))
    }

    // MARK: - Overview stays first + cannot be hidden

    @Test("overview is always the first pill, even if the layout reorders it")
    func overviewAlwaysFirst() {
        // A malformed/stale layout that puts overview LAST.
        let stale = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: true, order: 1),
            InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 2)
        ])
        let ordered = InsightsTabSelection.ordered(layout: stale, availableKinds: allKinds)
        #expect(ordered.first == .overview)
    }

    @Test("overview cannot be hidden — it is never a customisable strip row")
    func overviewNotCustomisable() {
        let start = layout([InsightsLayoutTileId.weight])
        // Even if the layout marks overview hidden, the strip still renders it.
        let overviewHidden = start.togglingVisibility(forId: InsightsLayoutTileId.overview)
        let ordered = InsightsTabSelection.ordered(layout: overviewHidden, availableKinds: allKinds)
        #expect(ordered.first == .overview)
        // And the customise rows never include overview.
        #expect(!start.stripCustomizableTiles.contains { $0.id == InsightsLayoutTileId.overview })
    }

    // MARK: - New unknown metric defaults visible at the end

    @Test("a new metric appended at the tail defaults visible + lands last in the strip")
    func newMetricDefaultsVisibleAtEnd() {
        // Existing curated layout, then the defaults-merge appends a new slug
        // at the tail with its default visibility (true).
        let existing = layout([
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.pulse
        ])
        let newSlug = InsightsLayoutTileId.bmi
        let appended = InsightsLayout(tiles: existing.tiles + [
            InsightsLayoutTile(id: newSlug, visible: true, order: 99)
        ])
        let ordered = InsightsTabSelection.ordered(layout: appended, availableKinds: allKinds)
        #expect(ordered.last == .metric(.bmi))
        #expect(ordered.first == .overview)
    }

    // MARK: - stripCustomizableTiles excludes overview, keeps the rest in order

    @Test("stripCustomizableTiles drops overview + preserves order")
    func customizableTilesDropOverview() {
        let start = layout([
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.sleep
        ])
        let rows = start.stripCustomizableTiles.map(\.id)
        #expect(rows == [
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.sleep
        ])
    }
}
