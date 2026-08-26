import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.11 W28c — the three special Insights pages (mood / medications / workouts)
/// as pager destinations. Pure value-type math over the selection model: no view,
/// no store. Verifies the W29 single-source-of-truth contract holds for the new
/// `.special` entries — every special pill in the strip has a `.special` page in
/// the flat ordered swipe list (and vice-versa), data-availability gates them,
/// and they sit at their server-layout slot.
@Suite("Insights special pages — selection model + strip lockstep")
struct InsightsSpecialPagesTests {
    /// Builds a layout with the given visible slugs (overview implied), then the
    /// flat ordered swipe list + the strip render model for the supplied
    /// availability.
    private func model(
        visibleSlugs: [String],
        availableKinds: Set<MetricKind> = [],
        availableSpecials: Set<InsightsSpecialPage> = []
    ) -> (flat: [InsightsTabSelection], strip: [InsightsStripEntry]) {
        let tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
            + visibleSlugs.enumerated().map { idx, slug in
                InsightsLayoutTile(id: slug, visible: true, order: idx + 1)
            }
        let layout = InsightsLayout(tiles: tiles)
        let flat = InsightsTabSelection.ordered(
            layout: layout,
            availableKinds: availableKinds,
            availableSpecials: availableSpecials
        )
        return (flat, InsightsStripEntry.strip(from: flat))
    }

    // MARK: - Slug ↔ special-page mapping

    @Test("each special page round-trips through its layout slug")
    func specialSlugRoundTrip() {
        for page in InsightsSpecialPage.allCases {
            #expect(InsightsSpecialPage.page(forSlug: page.slug) == page)
        }
        // German legacy slugs normalize to the English special pages too.
        #expect(InsightsSpecialPage.page(forSlug: "stimmung") == .mood)
        #expect(InsightsSpecialPage.page(forSlug: "medikamente") == .medications)
    }

    @Test("a non-special slug never resolves to a special page")
    func nonSpecialSlugIsNil() {
        #expect(InsightsSpecialPage.page(forSlug: InsightsLayoutTileId.weight) == nil)
        #expect(InsightsSpecialPage.page(forSlug: InsightsLayoutTileId.overview) == nil)
    }

    // MARK: - Availability gating (self-suppress empty)

    @Test("a special slug with NO data produces neither a page nor a pill")
    func emptySpecialSuppressed() {
        // mood + medications + workouts visible in layout, but no data for any.
        let (flat, strip) = model(
            visibleSlugs: [
                InsightsLayoutTileId.mood,
                InsightsLayoutTileId.medications,
                InsightsLayoutTileId.workouts
            ],
            availableSpecials: []
        )
        #expect(flat == [.overview])
        #expect(strip == [.overview])
        for entry in strip {
            if case .special = entry { Issue.record("no special pill expected when no data") }
        }
    }

    @Test("a special slug WITH data produces exactly one page + one flat pill")
    func availableSpecialAppears() {
        let (flat, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.mood],
            availableSpecials: [.mood]
        )
        #expect(flat == [.overview, .special(.mood)])
        #expect(strip == [.overview, .special(.mood)])
    }

    @Test("only the special pages WITH data appear (partial availability)")
    func partialAvailability() {
        // All three in layout; only medications + workouts have data.
        let (flat, _) = model(
            visibleSlugs: [
                InsightsLayoutTileId.mood,
                InsightsLayoutTileId.medications,
                InsightsLayoutTileId.workouts
            ],
            availableSpecials: [.medications, .workouts]
        )
        #expect(flat == [.overview, .special(.medications), .special(.workouts)])
    }

    // MARK: - Server-layout slot + ordering

    @Test("special pages sit at their server-layout slot, interleaved with metrics")
    func specialsAtLayoutSlot() {
        // weight (metric) · mood (special) · pulse (metric) · medications (special)
        let (flat, _) = model(
            visibleSlugs: [
                InsightsLayoutTileId.weight,
                InsightsLayoutTileId.mood,
                InsightsLayoutTileId.pulse,
                InsightsLayoutTileId.medications
            ],
            availableKinds: [.weight, .pulse],
            availableSpecials: [.mood, .medications]
        )
        #expect(flat == [
            .overview,
            .metric(.weight),
            .special(.mood),
            .metric(.pulse),
            .special(.medications)
        ])
    }

    // MARK: - W29 lockstep invariant

    @Test("INVARIANT: every special pill has a page and every special page has a pill")
    func specialPillPageLockstep() {
        let (flat, strip) = model(
            visibleSlugs: [
                InsightsLayoutTileId.weight,
                InsightsLayoutTileId.workouts,
                InsightsLayoutTileId.hrv,
                InsightsLayoutTileId.mood
            ],
            availableKinds: [.weight, .hrv],
            availableSpecials: [.workouts, .mood]
        )
        // Specials present in the flat (pager) list.
        let pagePages = Set(flat.compactMap { entry -> InsightsSpecialPage? in
            if case let .special(page) = entry { return page }
            return nil
        })
        // Specials present as strip pills. 4.4 — a special CAN now be folded into
        // a group (workouts → activity), so collect from both shapes; here
        // workouts is activity's only available member, so it collapses back to a
        // direct pill.
        let pillPages = Set(strip.flatMap { entry -> [InsightsSpecialPage] in
            switch entry {
            case let .special(page): [page]
            case let .group(_, members): members.compactMap {
                    if case let .special(page) = $0 { return page }
                    return nil
                }
            default: []
            }
        })
        #expect(pagePages == pillPages, "a special pill with no page (or vice-versa) is forbidden")
        #expect(pagePages == [.workouts, .mood])
    }

    // MARK: - Parity Build 4 / 4.4: Recovery is the FIXED second pill

    @Test("Recovery is the fixed second entry, immediately after Übersicht")
    func recoveryIsFixedSecondPill() {
        // Web parity: the tab strip pushes Recovery as a hard-coded entry right
        // after Overview, before any layout-driven pill
        // (`insights-tab-strip.tsx:540-548`). It used to be tail-appended on iOS.
        let (flat, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.weight],
            availableKinds: [.weight],
            availableSpecials: [.recovery]
        )
        #expect(flat == [.overview, .special(.recovery), .metric(.weight)])
        #expect(strip == [.overview, .special(.recovery), .flat(.weight)])
    }

    @Test("Recovery keeps its fixed slot even if a stale layout also carries the tile")
    func recoveryNotDuplicatedByLayoutTile() {
        // `recovery` is not a server tile id, but a stale cache could carry one —
        // it must not produce a second pill.
        let (flat, _) = model(
            visibleSlugs: [InsightsLayoutTileId.weight, InsightsLayoutTileId.recovery],
            availableKinds: [.weight],
            availableSpecials: [.recovery]
        )
        #expect(flat == [.overview, .special(.recovery), .metric(.weight)])
        #expect(flat.filter { $0 == .special(.recovery) }.count == 1)
    }

    @Test("Recovery absent from availableSpecials (module off) produces no pill")
    func recoveryModuleOffSuppressed() {
        // 4.4 dropped the DATA gate, not the module gate: `availableSpecials`
        // still filters on the `recovery` module toggle upstream.
        let (flat, _) = model(
            visibleSlugs: [InsightsLayoutTileId.weight],
            availableKinds: [.weight],
            availableSpecials: []
        )
        #expect(flat == [.overview, .metric(.weight)])
    }

    @Test("pinned specials stay flat pills, never folded into a category group")
    func pinnedSpecialsNeverGrouped() {
        // 4.4 — `workouts` DOES fold into activity now, but the pinned specials
        // (mood / medications) never do; nor does the fixed Recovery pill.
        let (_, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.mood, InsightsLayoutTileId.medications],
            availableSpecials: [.mood, .medications, .recovery]
        )
        for entry in strip {
            if case let .group(_, members) = entry {
                Issue.record("a pinned special must never appear inside a group pill: \(members)")
            }
        }
        #expect(strip == [.overview, .special(.recovery), .special(.mood), .special(.medications)])
    }

    @Test("4.4: workouts folds into the Aktivität group alongside activity metrics")
    func workoutsFoldsIntoActivity() {
        let (flat, strip) = model(
            visibleSlugs: [
                InsightsLayoutTileId.walkingSpeed,
                InsightsLayoutTileId.workouts
            ],
            availableKinds: [.walkingSpeed],
            availableSpecials: [.workouts]
        )
        // The flat pager order is untouched — grouping is presentation only.
        #expect(flat == [.overview, .metric(.walkingSpeed), .special(.workouts)])
        // The strip folds both into ONE activity pill at the first member's slot.
        #expect(strip == [
            .overview,
            .group(.activity, members: [.metric(.walkingSpeed), .special(.workouts)])
        ])
    }

    @Test("4.4: workouts alone collapses to a flat pill (no 1-item menu)")
    func workoutsAloneStaysFlat() {
        let (_, strip) = model(
            visibleSlugs: [InsightsLayoutTileId.workouts],
            availableSpecials: [.workouts]
        )
        #expect(strip == [.overview, .special(.workouts)])
    }

    @Test("INVARIANT: the flat swipe list keeps every entry (metrics + specials) in layout order")
    func flatSwipeOrderPreservedWithSpecials() {
        let slugs = [
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.workouts,
            InsightsLayoutTileId.hrv,
            InsightsLayoutTileId.oxygen,
            InsightsLayoutTileId.mood,
            InsightsLayoutTileId.medications
        ]
        let (flat, strip) = model(
            visibleSlugs: slugs,
            availableKinds: [.weight, .hrv, .spo2],
            availableSpecials: [.workouts, .mood, .medications]
        )
        // The PAGER order is the curated layout order, verbatim.
        #expect(flat == [
            .overview, .metric(.weight), .special(.workouts),
            .metric(.hrv), .metric(.spo2), .special(.mood), .special(.medications)
        ])
        // The strip carries the SAME selections (flat pills + specials + group
        // members) with no additions and no drops.
        var stripSelections: [InsightsTabSelection] = []
        for entry in strip {
            switch entry {
            case .overview: stripSelections.append(.overview)
            case let .flat(kind): stripSelections.append(.metric(kind))
            case let .special(page): stripSelections.append(.special(page))
            case let .group(_, members): stripSelections.append(contentsOf: members)
            }
        }
        // Parity Build 4 — folding a category at its FIRST member's slot pulls that
        // category's later members forward, so the strip is not order-identical to
        // the flat pager list any more (it wasn't on the web either). What must
        // hold is that the strip neither adds nor drops a selection.
        #expect(Set(stripSelections) == Set(flat), "grouping/specials must neither add nor drop a page")
        #expect(stripSelections.count == flat.count, "grouping/specials must not duplicate a page")
    }
}
