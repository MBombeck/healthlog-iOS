import Foundation
@testable import HealthLog
import Testing

/// P8 — the ECG special page's place in the strip + pager.
///
/// ECG is the one special that is DATA-gated (not module-only like Recovery):
/// with no recordings there must be no pill and no page, because the surface
/// has nothing honest to show and a dead pill is the failure mode this project
/// keeps re-learning. It also is not a server layout tile, so its placement
/// runs through the category fold rather than `visibleTiles` — the sensitive
/// pager machinery, hence the invariant coverage here.
@Suite("Insights ECG page — data gate + strip/pager placement")
struct InsightsEcgSpecialPageTests {
    private func model(
        visibleSlugs: [String],
        availableKinds: Set<MetricKind> = [],
        availableSpecials: Set<InsightsSpecialPage> = []
    ) -> (flat: [InsightsTabSelection], strip: [InsightsStripEntry]) {
        let tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
            + visibleSlugs.enumerated().map { idx, slug in
                InsightsLayoutTile(id: slug, visible: true, order: idx + 1)
            }
        let flat = InsightsTabSelection.ordered(
            layout: InsightsLayout(tiles: tiles),
            availableKinds: availableKinds,
            availableSpecials: availableSpecials
        )
        return (flat, InsightsStripEntry.strip(from: flat))
    }

    // MARK: - Data gate

    @Test("no recordings → no ECG pill and no ECG page")
    func noRecordingsNoPill() {
        let (flat, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.pulse],
            availableKinds: [.pulse],
            availableSpecials: []
        )
        #expect(!flat.contains(.special(.ecg)))
        for entry in strip {
            if case .special(.ecg) = entry { Issue.record("a dead ECG pill must never render") }
        }
    }

    @Test("module `insights` off → no pill even WITH recordings")
    func moduleOffSuppressesPill() {
        // `availableSpecials` is the post-module-filter set; the container drops
        // `.ecg` there when the module is off, so `ordered` never places it.
        let (flat, _) = model(
            visibleSlugs: [InsightsLayoutTileId.pulse],
            availableKinds: [.pulse],
            availableSpecials: []
        )
        #expect(flat == [.overview, .metric(.pulse)])
        #expect(InsightsSpecialPage.ecg.moduleKey == .insights)
    }

    // MARK: - Placement

    @Test("with recordings the ECG page joins the flat swipe list exactly once")
    func ecgAppearsOnce() {
        let (flat, _) = model(
            visibleSlugs: [InsightsLayoutTileId.weight],
            availableKinds: [.weight],
            availableSpecials: [.ecg]
        )
        #expect(flat.filter { $0 == .special(.ecg) }.count == 1)
    }

    @Test("ECG folds into the Heart group alongside the heart metrics")
    func ecgFoldsIntoHeart() {
        let (flat, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse],
            availableKinds: [.weight, .pulse],
            availableSpecials: [.ecg]
        )
        // The fold pulls ECG up to the heart block's slot (the web injects it
        // into the Heart popover for the same reason).
        #expect(flat == [
            .overview,
            .metric(.weight),
            .metric(.pulse),
            .special(.ecg)
        ])
        #expect(strip == [
            .overview,
            .flat(.weight),
            .group(.heart, members: [.metric(.pulse), .special(.ecg)])
        ])
    }

    @Test("ECG alone still reads as a Heart entry (no other heart metric needed)")
    func ecgAloneStaysReachable() {
        let (flat, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.weight],
            availableKinds: [.weight],
            availableSpecials: [.ecg]
        )
        #expect(flat == [.overview, .metric(.weight), .special(.ecg)])
        // A one-member category collapses back to a direct pill.
        #expect(strip == [.overview, .flat(.weight), .special(.ecg)])
    }

    @Test("a stale layout tile carrying `ecg` never produces a second pill")
    func staleLayoutTileNotDuplicated() {
        let (flat, _) = model(
            visibleSlugs: [InsightsLayoutTileId.weight, InsightsLayoutTileId.ecg],
            availableKinds: [.weight],
            availableSpecials: [.ecg]
        )
        #expect(flat.filter { $0 == .special(.ecg) }.count == 1)
    }

    // MARK: - Invariants

    @Test("INVARIANT: the ECG pill and the ECG page exist together or not at all")
    func pillPageLockstep() {
        for specials in [Set<InsightsSpecialPage>(), [.ecg]] {
            let (flat, strip) = model(
                visibleSlugs: [InsightsLayoutTileId.pulse, InsightsLayoutTileId.hrv],
                availableKinds: [.pulse, .hrv],
                availableSpecials: specials
            )
            let pageHasEcg = flat.contains(.special(.ecg))
            let pillHasEcg = strip.contains { entry in
                switch entry {
                case .special(.ecg): true
                case let .group(_, members): members.contains(.special(.ecg))
                default: false
                }
            }
            #expect(pageHasEcg == pillHasEcg, "a pill with no page (or vice-versa) is forbidden")
            #expect(pageHasEcg == specials.contains(.ecg))
        }
    }

    @Test("`ecg` stays OUT of serverKnownIds — a layout PUT carrying it would 422")
    func ecgIsNotAServerTile() {
        #expect(!InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.ecg))
        // …and it is deliberately absent from the slug→category map too (the web
        // keeps it out of SUB_PAGE_GROUP); the fold resolves it by page instead.
        #expect(InsightsCategoryGroups.slugToCategory[InsightsLayoutTileId.ecg] == nil)
        #expect(InsightsCategoryGroups.category(for: InsightsSpecialPage.ecg) == .heart)
    }

    @MainActor
    @Test("MONOTONE: once the ECG pill is seen it cannot vanish mid-session")
    func monotoneLatch() {
        // A single SWR revalidation blip must not collapse the ordered list and
        // snap the operator off a page they are standing on (the v0153
        // regression class the latch exists for).
        let pager = InsightsPagerModel()
        pager.mergeSeenSpecials([.ecg])
        #expect(pager.seenSpecials.contains(.ecg))
        pager.mergeSeenSpecials([])
        #expect(pager.seenSpecials.contains(.ecg), "the availability latch only ever grows")
    }

    @Test("the ECG slug round-trips to its special page")
    func slugRoundTrip() {
        #expect(InsightsSpecialPage.page(forSlug: InsightsLayoutTileId.ecg) == .ecg)
        #expect(InsightsSpecialPage.ecg.slug == "ecg")
    }
}
