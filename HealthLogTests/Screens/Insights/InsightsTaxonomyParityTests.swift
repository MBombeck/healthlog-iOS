import Foundation
@testable import HealthLog
import Testing

/// Parity Build 4 / items 4.1 + 4.4 — the Insights taxonomy + routing contract.
///
/// The audit (`.planning/parity/audit/02-insights.md` §B) found the most
/// embarrassing class of bug in the app: the Dashboard renders a "Schmerz" tile,
/// the operator taps it, and nothing happens — because `MetricKind.painNRS` had
/// no Insights slug, so `AppRouter.selectInsightsMetric` had nothing to route to.
/// Four kinds were in that state (`pain` / `waist` / `waist-to-height` /
/// `grip-strength`).
///
/// The guard below is deliberately derived from `MetricKind.allCases` rather than
/// a hand-written list: it is what keeps the bug class closed as kinds are added.
/// A new kind that ships a Dashboard tile without an Insights slug fails this
/// suite unless it is added to the small, documented `noInsightsPageByDesign`
/// allowlist — which forces the decision to be made and written down instead of
/// shipping silently as a dead tap.
@MainActor
@Suite("Insights taxonomy + routing parity (Build 4)")
struct InsightsTaxonomyParityTests {
    // MARK: - The dead-tap guard

    /// Kinds that legitimately have a Dashboard tile and NO Insights sub-page,
    /// because the web has no sub-page for them either. Keep this list tiny and
    /// justified — every entry is a tile whose tap falls back to the values table.
    ///
    /// - `bodyFat`: the web has no `body-fat` sub-page at all. `sub-page-metric.ts:390`
    ///   names `BODY_FAT` explicitly as a type with no sub-page; body composition
    ///   is charted through `fat-mass` / `fat-free-mass` instead.
    private static let noInsightsPageByDesign: Set<MetricKind> = [
        .bodyFat,
        // Build 7.3 — the mood dashboard tile has no dedicated Insights page; a tap
        // falls back to the values table (verified by the "no Insights slug falls
        // back to the values table" test), not a dead no-op. A dedicated mood
        // Insights route is out of scope for 7.3.
        .mood
    ]

    @Test("every MetricKind with a Dashboard tile resolves to an Insights slug")
    func everyDashboardTileHasASlug() {
        for kind in MetricKind.allCases {
            // A kind is tile-capable iff the Dashboard widget catalogue has an id
            // for it — the same table `DashboardWidgetLayout` renders from.
            guard DashboardWidgetId.id(forMetricKind: kind) != nil else { continue }
            guard !Self.noInsightsPageByDesign.contains(kind) else { continue }
            #expect(
                InsightsTabSlug.slug(forKind: kind) != nil,
                "Dashboard tile for MetricKind.\(kind.rawValue) has no Insights slug — dead tap. Wire kindToSlug + serverKnownIds + InsightsCategoryGroups, or allowlist it."
            )
        }
    }

    @Test("the four v1.25 clinical kinds now resolve, both ways")
    func clinicalKindsResolve() {
        let pairs: [(MetricKind, String)] = [
            (.painNRS, InsightsLayoutTileId.pain),
            (.waistCircumference, InsightsLayoutTileId.waist),
            (.waistToHeight, InsightsLayoutTileId.waistToHeight),
            (.gripStrength, InsightsLayoutTileId.gripStrength)
        ]
        for (kind, slug) in pairs {
            #expect(InsightsTabSlug.slug(forKind: kind) == slug)
            #expect(InsightsTabSlug.metricKind(forSlug: slug) == kind)
            #expect(InsightsLayoutTileId.serverKnownIds.contains(slug))
        }
        // And the slug spellings match the web routes verbatim.
        #expect(InsightsLayoutTileId.pain == "pain")
        #expect(InsightsLayoutTileId.waist == "waist")
        #expect(InsightsLayoutTileId.waistToHeight == "waist-to-height")
        #expect(InsightsLayoutTileId.gripStrength == "grip-strength")
    }

    @Test("the four clinical kinds land in their web group")
    func clinicalKindsAreGrouped() {
        #expect(InsightsCategoryGroups.category(for: .painNRS) == .vitals)
        #expect(InsightsCategoryGroups.category(for: .waistCircumference) == .body)
        #expect(InsightsCategoryGroups.category(for: .waistToHeight) == .body)
        #expect(InsightsCategoryGroups.category(for: .gripStrength) == .activity)
    }

    @Test("a tile tap for a wired clinical kind now lands in the Insights tab")
    func clinicalTileTapRoutesToInsights() {
        let router = AppRouter()
        router.selectInsightsMetric(.painNRS)
        #expect(router.selectedTab == .insights)
        #expect(router.pendingInsightsMetricSlug == InsightsLayoutTileId.pain)
        #expect(router.insightsMetricRequestCount == 1)
    }

    // MARK: - The fallback net still guards the class

    @Test("the AppRouter fallback still fires for a kind with no slug")
    func fallbackNetStillWorks() {
        // Build 1's safety net must survive the real fix: a kind with no Insights
        // slug still lands the operator on the per-kind values table (Mehr stack)
        // rather than no-opping. `.bodyFat` is the live example — it has a
        // Dashboard tile and, by web parity, no Insights sub-page.
        #expect(InsightsTabSlug.slug(forKind: .bodyFat) == nil, "fixture kind must stay slug-less")
        let router = AppRouter()
        router.selectInsightsMetric(.bodyFat)
        #expect(router.selectedTab == .more, "no-slug tap must land on the Mehr stack, not no-op")
        #expect(router.morePath.count == 1, "the per-kind values table must be pushed")
        // And it must NOT have parked an Insights slug / bumped the counter.
        #expect(router.pendingInsightsMetricSlug == nil)
        #expect(router.insightsMetricRequestCount == 0)
    }

    // MARK: - Every grouped slug is routable

    @Test("every slug in the taxonomy is server-known (a PUT can never 422)")
    func groupedSlugsAreServerKnown() {
        for slug in InsightsCategoryGroups.slugToCategory.keys {
            #expect(
                InsightsLayoutTileId.serverKnownIds.contains(slug),
                "grouped slug \(slug) is not server-known — a layout PUT carrying it would 422"
            )
        }
        for slug in InsightsCategoryGroups.pinnedSlugs {
            #expect(InsightsLayoutTileId.serverKnownIds.contains(slug))
        }
    }
}
