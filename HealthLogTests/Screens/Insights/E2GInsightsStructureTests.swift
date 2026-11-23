import Foundation
import SwiftUI
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Insights in one logic: Recovery is a category like Heart, the health
/// score is a card beside the other scores, and a swipe chooses its page once
/// the pager rests. Pure value and model checks, no view.
@Suite("E2G — Insights structure and paging")
@MainActor
struct E2GInsightsStructureTests {
    private static let whoopFamily: [MetricKind] = [.recoveryScore, .dayStrain, .averageHeartRate, .energyExpenditureKJ]

    private func layout(_ slugs: [String]) -> InsightsLayout {
        let tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
            + slugs.enumerated().map { InsightsLayoutTile(id: $1, visible: true, order: $0 + 1) }
        return InsightsLayout(tiles: tiles)
    }

    // MARK: - Recovery as a category

    @Test("the recovery family stands right after Übersicht, folded into one Recovery pill")
    func recoveryIsACategoryAfterOverview() {
        let flat = InsightsTabSelection.ordered(
            layout: layout([InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse, InsightsLayoutTileId.restingPulse]),
            availableKinds: [.weight, .pulse, .restingHeartRate],
            recoveryKinds: Self.whoopFamily
        )
        let members = Self.whoopFamily.map(InsightsTabSelection.metric)
        #expect(flat == [.overview] + members + [.metric(.weight), .metric(.pulse), .metric(.restingHeartRate)])
        let strip = InsightsStripEntry.strip(from: flat)
        #expect(strip == [
            .overview,
            .group(.recovery, members: members),
            .flat(.weight),
            .group(.heart, members: [.metric(.pulse), .metric(.restingHeartRate)])
        ])
        // One page per member, exactly like the heart pages.
        #expect(InsightsPagerPage.pages(from: flat).count == flat.count)
    }

    @Test("every recovery member belongs to the Recovery category, with the pill's own identifier")
    func recoveryMembersResolveToTheCategory() {
        for kind in RecoveryInsightsRepository.familyOrder {
            #expect(InsightsCategoryGroups.category(for: .metric(kind)) == .recovery)
        }
        #expect(InsightsCategoryGroups.category(for: .metric(.weight)) == nil)
        #expect(InsightsMetricCategory.recovery.tabStripPillIdentifier == "insights.tabStrip.pill.group.recovery")
        #expect(InsightsMetricCategory.recovery.label == String(localized: "Recovery"))
    }

    @Test("a single current recovery member is a plain pill, no current member is no pill")
    func recoveryWithOneOrNoMember() {
        let one = InsightsTabSelection.ordered(layout: layout([]), availableKinds: [], recoveryKinds: [.dayStrain])
        #expect(InsightsStripEntry.strip(from: one) == [.overview, .flat(.dayStrain)])
        let none = InsightsTabSelection.ordered(layout: layout([]), availableKinds: [], recoveryKinds: [])
        #expect(none == [.overview])
    }

    @Test("a kind outside the recovery family is never placed as a recovery page")
    func onlyFamilyKindsArePlaced() {
        let flat = InsightsTabSelection.ordered(layout: layout([]), availableKinds: [], recoveryKinds: [.weight, .dayStrain, .dayStrain])
        #expect(flat == [.overview, .metric(.dayStrain)])
    }

    /// The update path: an installation that cached a layout before this
    /// build, in the old German vocabulary and with a stray `recovery` row,
    /// opens on the new structure without a dead pill and without a duplicate.
    @Test("an old cached layout opens on the Recovery category, without a dead recovery page")
    func oldCachedLayoutMigrates() throws {
        let json = Data("""
        {"version":1,"tiles":[
          {"id":"overview","visible":true,"order":0},
          {"id":"recovery","visible":true,"order":1},
          {"id":"gewicht","visible":true,"order":2},
          {"id":"puls","visible":true,"order":3},
          {"id":"stimmung","visible":true,"order":4}
        ]}
        """.utf8)
        let cached = try JSONDecoder().decode(InsightsLayout.self, from: json)
        let flat = InsightsTabSelection.ordered(
            layout: cached,
            availableKinds: [.weight, .pulse],
            availableSpecials: [.mood],
            recoveryKinds: Self.whoopFamily
        )
        let members = Self.whoopFamily.map(InsightsTabSelection.metric)
        #expect(flat == [.overview] + members + [.metric(.weight), .metric(.pulse), .special(.mood)])
        #expect(InsightsSpecialPage.page(forSlug: InsightsLayoutTileId.recovery) == nil)
        #expect(!InsightsSpecialPage.allCases.map(\.slug).contains(InsightsLayoutTileId.recovery))
    }

    // MARK: - The old recovery address

    @Test("the old recovery link opens the first recovery page")
    func recoveryLinkOpensFirstMember() {
        let pager = InsightsPagerModel()
        let live = InsightsTabSelection.ordered(layout: layout([]), availableKinds: [], recoveryKinds: Self.whoopFamily)
        let router = AppRouter()
        router.apply(.insights(metric: InsightsLayoutTileId.recovery), isAuthenticated: true)
        pager.stageInsightsMetricIfRequested(router: router, liveOrderedSelections: live, pages: InsightsPagerPage.pages(from: live))
        #expect(pager.selection == .metric(.recoveryScore))
        #expect(pager.pendingCategoryTarget == nil)
    }

    @Test("a recovery link that arrives before the family waits for it, and lands on Übersicht if none comes")
    func recoveryLinkWaitsThenFallsBack() {
        let pager = InsightsPagerModel()
        let router = AppRouter()
        router.apply(.insights(metric: InsightsLayoutTileId.recovery), isAuthenticated: true)
        pager.stageInsightsMetricIfRequested(router: router, liveOrderedSelections: [.overview], pages: [.overview])
        #expect(pager.pendingCategoryTarget == .recovery)
        #expect(pager.selection == .overview)

        // The family answers with members: the link lands on the first.
        let live = InsightsTabSelection.ordered(layout: layout([]), availableKinds: [], recoveryKinds: [.dayStrain, .averageHeartRate])
        pager.tryApplyStagedMetric(liveOrderedSelections: live, pages: InsightsPagerPage.pages(from: live))
        #expect(pager.selection == .metric(.dayStrain))

        // Another link, and the family answers empty: Übersicht.
        let empty = InsightsPagerModel()
        empty.selection = .metric(.weight)
        empty.pendingCategoryTarget = .recovery
        empty.abandonStagedCategoryIfEmpty(.recovery, liveOrderedSelections: [.overview, .metric(.weight)])
        #expect(empty.pendingCategoryTarget == nil)
        #expect(empty.selection == .overview)
    }

    // MARK: - A swipe chooses its page at rest

    @Test("while the pager moves, a passing page does not become the selection; at rest it does")
    func swipeAdoptsAtRest() {
        let pager = InsightsPagerModel()
        let live: [InsightsTabSelection] = [.overview, .metric(.weight), .metric(.pulse)]
        let pages = InsightsPagerPage.pages(from: live)
        pager.pagerOrder = live
        pager.pagerScrollPhaseChanged(isIdle: false, pages: pages, liveOrderedSelections: live)
        pager.scrolledID = .metric(.weight)
        pager.adoptScrolledPage(.metric(.weight), pages: pages, liveOrderedSelections: live)
        #expect(pager.selection == .overview)

        pager.pagerScrollPhaseChanged(isIdle: true, pages: pages, liveOrderedSelections: live)
        #expect(pager.selection == .metric(.weight))
    }

    @Test("the strip's pill follows the page a swipe passes at once, the selection only at rest")
    func stripFollowsThePassingPage() {
        let pager = InsightsPagerModel()
        let live: [InsightsTabSelection] = [.overview, .metric(.weight), .metric(.pulse)]
        let pages = InsightsPagerPage.pages(from: live)
        pager.pagerOrder = live
        pager.pagerScrollPhaseChanged(isIdle: false, isUserDriven: true, pages: pages, liveOrderedSelections: live)
        pager.scrolledID = .metric(.weight)
        pager.adoptScrolledPage(.metric(.weight), pages: pages, liveOrderedSelections: live)
        #expect(pager.stripSelection == .metric(.weight))
        #expect(pager.selection == .overview)

        // Back over the start before the finger lets go: the pill comes back.
        pager.adoptScrolledPage(.overview, pages: pages, liveOrderedSelections: live)
        #expect(pager.stripSelection == .overview)
        pager.adoptScrolledPage(.metric(.weight), pages: pages, liveOrderedSelections: live)

        pager.pagerScrollPhaseChanged(isIdle: true, pages: pages, liveOrderedSelections: live)
        #expect(pager.selection == .metric(.weight))
        #expect(pager.passingSelection == nil)
        #expect(pager.stripSelection == .metric(.weight))
    }

    @Test("a pill tap's scroll passes pages without moving the pill")
    func programmaticScrollLeavesThePill() {
        let pager = InsightsPagerModel()
        let live: [InsightsTabSelection] = [.overview, .metric(.weight), .metric(.pulse)]
        let pages = InsightsPagerPage.pages(from: live)
        pager.pagerOrder = live
        pager.selection = .metric(.pulse)
        pager.mirrorSelectionIntoScroll(.metric(.pulse), pages: pages, reduceMotion: true)
        pager.pagerScrollPhaseChanged(isIdle: false, pages: pages, liveOrderedSelections: live)
        pager.adoptScrolledPage(.metric(.weight), pages: pages, liveOrderedSelections: live)
        #expect(pager.passingSelection == nil)
        #expect(pager.stripSelection == .metric(.pulse))
    }

    @Test("a write while the pager rests follows at once, a programmatic echo never moves the selection")
    func restingWritesAndEchoes() {
        let pager = InsightsPagerModel()
        let live: [InsightsTabSelection] = [.overview, .metric(.weight), .metric(.pulse)]
        let pages = InsightsPagerPage.pages(from: live)
        pager.adoptScrolledPage(.metric(.pulse), pages: pages, liveOrderedSelections: live)
        #expect(pager.selection == .metric(.pulse))

        pager.programmaticScrollTarget = .metric(.weight)
        pager.adoptScrolledPage(.overview, pages: pages, liveOrderedSelections: live)
        #expect(pager.selection == .metric(.pulse))
        #expect(pager.programmaticScrollTarget == .metric(.weight))
        pager.adoptScrolledPage(.metric(.weight), pages: pages, liveOrderedSelections: live)
        #expect(pager.programmaticScrollTarget == nil)
    }

    // MARK: - One strip moves

    @Test("only the strip in view slides to a new selection, and not with reduced motion")
    func onlyTheVisibleStripSlides() {
        #expect(InsightsMetricTabStrip.slidesToSelection(isOnVisiblePage: true, reduceMotion: false))
        #expect(!InsightsMetricTabStrip.slidesToSelection(isOnVisiblePage: false, reduceMotion: false))
        #expect(!InsightsMetricTabStrip.slidesToSelection(isOnVisiblePage: true, reduceMotion: true))
    }

    @Test("two strip contexts with the same values are equal whatever their actions")
    func stripContextComparesValues() {
        func context(_ selected: InsightsTabSelection, note: String? = nil) -> InsightsStripContext {
            InsightsStripContext(
                selection: .constant(selected),
                selected: selected,
                orderedSelections: [.overview, .metric(.weight)],
                onPillTap: { _ in },
                onCustomize: {},
                availabilityNote: note
            )
        }
        #expect(context(.overview) == context(.overview))
        #expect(context(.overview) != context(.metric(.weight)))
        #expect(context(.overview) != context(.overview, note: "x"))
    }

    // MARK: - The health score card

    @Test("the health score card stands first, or after the rings the hero order puts before it")
    func healthScoreCardPosition() {
        let visible = ["READINESS", "SLEEP_SCORE", "STRAIN_SCORE"]
        #expect(InsightsScoreCardResolution.healthScoreIndex(in: visible, heroOrder: []) == 0)
        #expect(InsightsScoreCardResolution.healthScoreIndex(in: visible, heroOrder: [.healthScore, .readiness]) == 0)
        #expect(InsightsScoreCardResolution.healthScoreIndex(in: visible, heroOrder: [.readiness, .healthScore, .sleepScore]) == 1)
        #expect(InsightsScoreCardResolution.healthScoreIndex(in: visible, heroOrder: [.readiness, .sleepScore, .healthScore]) == 2)
        // A ring before it in the order that has no card here moves nothing.
        #expect(InsightsScoreCardResolution.healthScoreIndex(in: visible, heroOrder: [.medCompliance, .healthScore]) == 0)
    }

    @Test("the score grid's one sheet tells the health score from a derived score")
    func scoreDetailIdentity() {
        #expect(InsightsScoreCardDetail.healthScore.id == "HEALTH_SCORE")
    }

    @Test("the health score detail says the week's change, or why there is none")
    func healthScoreComparison() {
        let up = HealthScore(score: 72, band: .green, delta: 3)
        let line = InsightsHealthScoreContent.comparisonLine(up)
        #expect(line?.contains("3") == true)
        #expect(line?.contains("+") == true)

        let changed = HealthScore(score: 72, band: .green, delta: nil, deltaReason: .algorithmChanged)
        #expect(InsightsHealthScoreContent.comparisonLine(changed) == HealthScorePresentation.shortLabel(for: .algorithmChanged))

        let bare = HealthScore(score: 72, band: nil, delta: nil)
        #expect(InsightsHealthScoreContent.comparisonLine(bare) == nil)
    }

    @Test("the notes under the pillars come only from what the server sent")
    func healthScorePillarNotes() {
        let plain = HealthScore(score: 60, band: .yellow, delta: nil, composition: [.sleep, .activity, .bloodPressure])
        #expect(InsightsHealthScoreContent.pillarNotes(plain).isEmpty)

        let narrow = HealthScore(
            score: 60,
            band: .yellow,
            delta: nil,
            composition: [.activity, .wellbeing, .sleep],
            configured: true,
            scoreBasis: HealthScoreBasis(domains: 2, recommended: 4, tier: .partial, physiological: false)
        )
        let notes = InsightsHealthScoreContent.pillarNotes(narrow)
        #expect(notes.contains(HealthScorePresentation.chosenCompositionExplanation))
        #expect(notes.contains(HealthScorePresentation.basisWithoutPhysiology))
    }
}
