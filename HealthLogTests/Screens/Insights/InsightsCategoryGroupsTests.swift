import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.11 W28 — the Insights tab-strip **category grouping** taxonomy + the
/// strip render model (`InsightsStripEntry`). Pure value-type math: no view, no
/// store. Verifies web parity (every grouped slug → exactly one category; the
/// category union == the grouped slug set; flat/primary slugs excluded) and the
/// invariant that the grouping is presentation-only — it folds pills but never
/// reorders or drops the flat swipe sequence.
@Suite("Insights category grouping — taxonomy + strip render model")
struct InsightsCategoryGroupsTests {
    // MARK: - Taxonomy

    @Test("every grouped slug maps to a real chartable MetricKind or a special page")
    func groupedSlugsAreChartable() {
        for slug in InsightsCategoryGroups.slugToCategory.keys {
            // 4.4 — `workouts` is a special page, not a chartable kind, but it is
            // a legitimate group member now.
            let resolves = InsightsTabSlug.metricKind(forSlug: slug) != nil
                || InsightsSpecialPage.page(forSlug: slug) != nil
            #expect(
                resolves,
                "grouped slug \(slug) resolves to neither a kind nor a special page — it would never produce a pill"
            )
        }
    }

    @Test("each grouped slug belongs to exactly one category")
    func eachSlugOneCategory() {
        // The dictionary keying already enforces uniqueness; assert the reverse
        // resolution (kind → category) is single-valued and consistent.
        for (slug, category) in InsightsCategoryGroups.slugToCategory {
            if let kind = InsightsTabSlug.metricKind(forSlug: slug) {
                #expect(InsightsCategoryGroups.category(for: kind) == category)
            } else if let page = InsightsSpecialPage.page(forSlug: slug) {
                #expect(InsightsCategoryGroups.category(for: page) == category)
            } else {
                Issue.record("grouped slug \(slug) resolves to nothing")
            }
        }
    }

    @Test("category membership mirrors the web SUB_PAGE_GROUP 1:1")
    func webParityMembership() {
        // Parity Build 4 / 4.1 — a verbatim mirror of `SUB_PAGE_GROUP`
        // (`src/lib/insights/sub-page-metric.ts:195-256`). The only omission is
        // `audio-events`, which has no iOS `MetricKind` (HK category type) and so
        // could never render a pill.
        let expected: [InsightsMetricCategory: Set<String>] = [
            .vitals: [
                InsightsLayoutTileId.oxygen, InsightsLayoutTileId.bodyTemperature,
                InsightsLayoutTileId.respiratoryRate,
                // v1.25 — pain rides the vitals popover.
                InsightsLayoutTileId.pain
            ],
            .body: [
                InsightsLayoutTileId.bmi,
                InsightsLayoutTileId.bodyWater, InsightsLayoutTileId.boneMass,
                InsightsLayoutTileId.fatFreeMass, InsightsLayoutTileId.fatMass,
                InsightsLayoutTileId.muscleMass, InsightsLayoutTileId.visceralFat,
                InsightsLayoutTileId.leanBodyMass,
                // v1.25 — waist + waist-to-height sit with body composition.
                InsightsLayoutTileId.waist, InsightsLayoutTileId.waistToHeight
            ],
            .activity: [
                InsightsLayoutTileId.steps, InsightsLayoutTileId.activeEnergy,
                // 4.4 — the workouts SPECIAL page folds in here too.
                InsightsLayoutTileId.workouts,
                InsightsLayoutTileId.flightsClimbed, InsightsLayoutTileId.walkingDistance,
                InsightsLayoutTileId.walkingSteadiness,
                InsightsLayoutTileId.walkingHeartRate, InsightsLayoutTileId.walkingAsymmetry,
                InsightsLayoutTileId.doubleSupportTime, InsightsLayoutTileId.stepLength,
                InsightsLayoutTileId.walkingSpeed,
                InsightsLayoutTileId.cardioFitness, InsightsLayoutTileId.falls,
                InsightsLayoutTileId.sixMinuteWalk, InsightsLayoutTileId.stairAscentSpeed,
                InsightsLayoutTileId.stairDescentSpeed,
                // v1.25 — grip strength sits with activity / fitness.
                InsightsLayoutTileId.gripStrength
            ],
            .heart: [
                // 4.1 — pulse / resting-pulse / HRV moved in from vitals.
                InsightsLayoutTileId.pulse, InsightsLayoutTileId.restingPulse,
                InsightsLayoutTileId.hrv,
                InsightsLayoutTileId.pulseWaveVelocity, InsightsLayoutTileId.vascularAge,
                InsightsLayoutTileId.cardioRecovery
            ],
            .hearing: [
                InsightsLayoutTileId.environmentalAudio, InsightsLayoutTileId.headphoneAudio
            ],
            .environment: [InsightsLayoutTileId.daylight],
            .metabolic: [
                InsightsLayoutTileId.bloodGlucose,
                // 4.1 — the b215 divergence is resolved: skin + wrist temperature
                // live in Stoffwechsel, as on the web.
                InsightsLayoutTileId.skinTemperature, InsightsLayoutTileId.wristTemperature
            ]
        ]
        for category in InsightsMetricCategory.allCases {
            let actual = Set(
                InsightsCategoryGroups.slugToCategory
                    .filter { $0.value == category }
                    .map(\.key)
            )
            #expect(actual == expected[category], "category \(category) membership drift")
        }
    }

    @Test("the union of all categories equals the grouped slug set")
    func categoryUnionEqualsGroupedSet() {
        let union = InsightsMetricCategory.allCases.reduce(into: Set<String>()) { acc, category in
            acc.formUnion(InsightsCategoryGroups.slugToCategory.filter { $0.value == category }.map(\.key))
        }
        #expect(union == Set(InsightsCategoryGroups.slugToCategory.keys))
    }

    @Test("the pinned set is exactly the web's five")
    func pinnedSetMatchesWeb() {
        // `PINNED_SUB_PAGE_SLUGS` (`sub-page-metric.ts:187-193`). iOS pinned three
        // too many before Build 4 (pulse, bmi, and the workouts special).
        #expect(InsightsCategoryGroups.pinnedSlugs == [
            InsightsLayoutTileId.bloodPressure,
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.sleep,
            InsightsLayoutTileId.medications,
            InsightsLayoutTileId.mood
        ])
        // A pinned slug never resolves to a category — it is always a flat pill.
        for slug in InsightsCategoryGroups.pinnedSlugs {
            #expect(InsightsCategoryGroups.category(forSlug: slug) == nil)
        }
        for kind in [MetricKind.bloodPressure, .weight, .sleep] {
            #expect(InsightsCategoryGroups.category(for: kind) == nil)
        }
        for page in [InsightsSpecialPage.mood, .medications] {
            #expect(InsightsCategoryGroups.category(for: page) == nil)
        }
    }

    @Test("the three formerly-flat metrics now resolve to their web group")
    func unpinnedMetricsAreGrouped() {
        #expect(InsightsCategoryGroups.category(for: .pulse) == .heart)
        #expect(InsightsCategoryGroups.category(for: .bmi) == .body)
        #expect(InsightsCategoryGroups.category(for: InsightsSpecialPage.workouts) == .activity)
    }

    @Test("breathing-disturbances is flat (the web leaves it ungrouped)")
    func breathingDisturbancesIsFlat() {
        #expect(InsightsCategoryGroups.category(for: .breathingDisturbances) == nil)
    }

    @Test("Recovery is never a group member — it is the fixed second pill")
    func recoveryUngrouped() {
        #expect(InsightsCategoryGroups.category(for: InsightsSpecialPage.recovery) == nil)
    }

    // MARK: - Strip render model (presentation, not swipe order)

    /// Builds a layout with the given visible slugs (overview implied), then the
    /// flat ordered swipe list + the strip render model. By default every slug's
    /// kind/special is available; `availableKinds` / `availableSpecials` override
    /// the gate so a test can drop a metric (module-disabled / no data) or add the
    /// fixed `recovery` pill.
    private func model(
        visibleSlugs: [String],
        availableKinds: Set<MetricKind>? = nil,
        availableSpecials: Set<InsightsSpecialPage>? = nil
    ) -> (flat: [InsightsTabSelection], strip: [InsightsStripEntry]) {
        let tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
            + visibleSlugs.enumerated().map { idx, slug in
                InsightsLayoutTile(id: slug, visible: true, order: idx + 1)
            }
        let layout = InsightsLayout(tiles: tiles)
        let kinds = availableKinds ?? Set(visibleSlugs.compactMap { InsightsTabSlug.metricKind(forSlug: $0) })
        let specials = availableSpecials ?? Set(visibleSlugs.compactMap { InsightsSpecialPage.page(forSlug: $0) })
        let flat = InsightsTabSelection.ordered(
            layout: layout,
            availableKinds: kinds,
            availableSpecials: specials
        )
        return (flat, InsightsStripEntry.strip(from: flat))
    }

    /// Expand the strip render model back into the flat selection order it folds:
    /// each direct pill covers its own selection; a group pill covers its members
    /// in order. The v0152 flat-pager contract (`InsightsCategoryGroups.swift:322`)
    /// is that this expansion is EXACTLY `ordered(...)` — pill N ↔ page N.
    private func expanded(_ strip: [InsightsStripEntry]) -> [InsightsTabSelection] {
        strip.flatMap { entry -> [InsightsTabSelection] in
            switch entry {
            case .overview: [.overview]
            case let .flat(kind): [.metric(kind)]
            case let .special(page): [.special(page)]
            case let .group(_, members): members
            }
        }
    }

    /// Does a strip pill highlight for the given page's selection?
    private func covers(_ entry: InsightsStripEntry, _ selection: InsightsTabSelection) -> Bool {
        switch entry {
        case .overview: selection == .overview
        case let .flat(kind): selection == .metric(kind)
        case let .special(page): selection == .special(page)
        case let .group(_, members): members.contains(selection)
        }
    }

    /// The index of the strip pill that highlights when the pager rests on `page`.
    private func stripIndex(hosting page: InsightsPagerPage, in strip: [InsightsStripEntry]) -> Int {
        let target: InsightsTabSelection = switch page {
        case .overview: .overview
        case let .flat(kind): .metric(kind)
        case let .special(sp): .special(sp)
        }
        return strip.firstIndex { covers($0, target) } ?? -1
    }

    /// Are these ascending indices a single consecutive run (no gaps)? An empty or
    /// single-element run is trivially contiguous.
    private func isContiguousRun(_ positions: [Int]) -> Bool {
        guard let first = positions.first, let last = positions.last else { return true }
        return positions == Array(first ... last)
    }

    @Test("strip folds a multi-member category into one group pill at its first slot")
    func groupFoldsAtFirstSlot() {
        // weight (pinned/flat) · hrv (heart) · pulse (heart) · glucose (metabolic, 1)
        let (_, strip) = model(visibleSlugs: [
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.hrv,
            InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.bloodGlucose
        ])
        // overview · weight(flat) · heart(group: hrv,pulse) · metabolic→1 member→flat(glucose)
        #expect(strip.count == 4)
        #expect(strip[0] == .overview)
        #expect(strip[1] == .flat(.weight))
        guard case let .group(category, members) = strip[2] else {
            Issue.record("expected a heart group pill at index 2")
            return
        }
        #expect(category == .heart)
        #expect(members == [.metric(.hrv), .metric(.pulse)])
        // A single-member category collapses to a flat pill (no 1-item menu).
        #expect(strip[3] == .flat(.glucose))
    }

    @Test("a single-member category renders as a flat pill, never a 1-item menu")
    func singleMemberCategoryIsFlat() {
        let (_, strip) = model(visibleSlugs: [InsightsLayoutTileId.daylight])
        #expect(strip == [.overview, .flat(.timeInDaylight)])
    }

    @Test("an empty/availability-gated category produces no pill")
    func emptyCategoryNoPill() {
        // Only flat pills available → no group entries at all.
        let (_, strip) = model(visibleSlugs: [
            InsightsLayoutTileId.weight, InsightsLayoutTileId.bloodPressure
        ])
        #expect(strip == [.overview, .flat(.weight), .flat(.bloodPressure)])
        for entry in strip {
            if case .group = entry { Issue.record("no group pill expected") }
        }
    }

    @Test("INVARIANT: expanding the strip render model reproduces the flat pager order (pill N ↔ page N)")
    func flatSwipeOrderIsCategoryContiguous() {
        // HISTORY: this test used to assert that the RAW interleaved layout order was
        // returned verbatim — the state after `c8f1aa3b` deleted `categoryContiguous`,
        // which reintroduced the v0153 swipe-order bug (a swipe through "Vitalwerte"
        // jumps ~3 pills forward then snaps back, because the flat pager pages a
        // scattered category 1:1 while the strip folds it to one pill). It is now
        // INVERTED to the v0152/v0153 contract: `ordered(...)` folds each category's
        // members contiguous, so the strip's presentation fold expands EXACTLY back
        // to the flat pager order — one pill ↔ one page.
        //
        // The slugs are deliberately INTERLEAVED across categories in the input; the
        // contract holds regardless of the curated interleave.
        let slugs = [
            InsightsLayoutTileId.weight, InsightsLayoutTileId.hrv,
            InsightsLayoutTileId.bodyWater, InsightsLayoutTileId.oxygen,
            InsightsLayoutTileId.skinTemperature, InsightsLayoutTileId.fatMass,
            InsightsLayoutTileId.walkingSpeed, InsightsLayoutTileId.bloodGlucose
        ]
        let (flat, strip) = model(visibleSlugs: slugs)

        // 1. The strip neither adds, drops, nor reorders relative to the pager:
        //    expanding the pills in strip order reproduces the flat pager order.
        #expect(expanded(strip) == flat, "strip expansion must equal the flat pager order")

        // 2. Every category's members are consecutive in the flat pager order.
        for category in InsightsMetricCategory.allCases {
            let positions = flat.enumerated().compactMap { idx, sel in
                InsightsCategoryGroups.category(for: sel) == category ? idx : nil
            }
            #expect(
                isContiguousRun(positions),
                "\(category) members must be contiguous in the flat pager order"
            )
        }

        // 3. No metric is added or dropped by the fold.
        let flatKinds = flat.compactMap { entry -> MetricKind? in
            if case let .metric(kind) = entry { return kind }
            return nil
        }
        let expectedKinds = slugs.compactMap { InsightsTabSlug.metricKind(forSlug: $0) }
        #expect(Set(flatKinds) == Set(expectedKinds), "clustering must neither add nor drop a metric")
        #expect(flatKinds.count == expectedKinds.count, "clustering must not duplicate a metric")
    }

    @Test(
        "INVARIANT (parametrized): strip expansion == flat pager order, incl. interleaved + workouts",
        arguments: [
            // Interleaved metric-only layout (the c8f1aa3b regression repro).
            [
                InsightsLayoutTileId.weight, InsightsLayoutTileId.hrv,
                InsightsLayoutTileId.bodyWater, InsightsLayoutTileId.oxygen,
                InsightsLayoutTileId.skinTemperature, InsightsLayoutTileId.fatMass,
                InsightsLayoutTileId.walkingSpeed, InsightsLayoutTileId.bloodGlucose
            ],
            // The workouts SPECIAL page interleaved into the activity block: it must
            // cluster with the chartable activity metrics (Parity 4.4 member).
            [
                InsightsLayoutTileId.steps, InsightsLayoutTileId.weight,
                InsightsLayoutTileId.workouts, InsightsLayoutTileId.hrv,
                InsightsLayoutTileId.walkingSpeed
            ],
            // Two heart members split by a pinned pill.
            [
                InsightsLayoutTileId.hrv, InsightsLayoutTileId.weight,
                InsightsLayoutTileId.pulse, InsightsLayoutTileId.sleep
            ]
        ]
    )
    func stripExpansionEqualsFlatOrder(slugs: [String]) {
        let (flat, strip) = model(visibleSlugs: slugs)
        #expect(expanded(strip) == flat)
        for category in InsightsMetricCategory.allCases {
            let positions = flat.enumerated().compactMap { idx, sel in
                InsightsCategoryGroups.category(for: sel) == category ? idx : nil
            }
            #expect(isContiguousRun(positions))
        }
    }

    @Test(
        "monotone pill-walk: advancing one page moves the highlighted pill by ≤ 1 (never i+3, never back)",
        arguments: [
            [
                InsightsLayoutTileId.weight, InsightsLayoutTileId.hrv,
                InsightsLayoutTileId.bodyWater, InsightsLayoutTileId.oxygen,
                InsightsLayoutTileId.skinTemperature, InsightsLayoutTileId.fatMass,
                InsightsLayoutTileId.walkingSpeed, InsightsLayoutTileId.bloodGlucose
            ],
            [
                InsightsLayoutTileId.steps, InsightsLayoutTileId.weight,
                InsightsLayoutTileId.workouts, InsightsLayoutTileId.hrv,
                InsightsLayoutTileId.walkingSpeed
            ]
        ]
    )
    func monotonePillWalk(slugs: [String]) {
        let (flat, strip) = model(visibleSlugs: slugs)
        let pages = InsightsPagerPage.pages(from: flat)
        let pillIndices = pages.map { stripIndex(hosting: $0, in: strip) }

        #expect(!pillIndices.contains(-1), "every page must resolve to a strip pill")
        // Non-decreasing, step ≤ 1 — a single swipe moves the highlight one pill.
        for (prev, next) in zip(pillIndices, pillIndices.dropFirst()) {
            #expect(next - prev >= 0 && next - prev <= 1, "pill walk must not jump or go back: \(pillIndices)")
        }
        // The walk starts at the first pill, ends at the last, and reaches each.
        #expect(pillIndices.first == 0)
        #expect(pillIndices.last == strip.count - 1)
        #expect(Set(pillIndices).count == strip.count, "every pill must be reached exactly by some page")
    }

    @Test("a gated/absent member keeps the pager mapping contiguous — no index holes")
    func gatedMemberStaysContiguous() throws {
        // Layout: oxygen(vitals) · hrv(heart) · resting-pulse(heart) · pulse(heart) ·
        // weight(pinned). resting-pulse is NOT available (module-disabled / no data),
        // so it drops out of `ordered` entirely. Recovery is on → fixed slot 1.
        let slugs = [
            InsightsLayoutTileId.oxygen, InsightsLayoutTileId.hrv,
            InsightsLayoutTileId.restingPulse, InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.weight
        ]
        let gatedKind = try #require(InsightsTabSlug.metricKind(forSlug: InsightsLayoutTileId.restingPulse))
        let allKinds = Set(slugs.compactMap { InsightsTabSlug.metricKind(forSlug: $0) })
        let (flat, strip) = model(
            visibleSlugs: slugs,
            availableKinds: allKinds.subtracting([gatedKind]),
            availableSpecials: [.recovery]
        )

        // The gated member is gone; no page/pill for it, no hole in the mapping.
        #expect(!flat.contains(.metric(gatedKind)))
        #expect(expanded(strip) == flat, "expansion stays hole-free after a member is gated out")
        // Recovery stays the fixed second entry (Slot 1).
        #expect(flat.first == .overview)
        #expect(flat[1] == .special(.recovery))
        // The two REMAINING heart members are still consecutive.
        let heartPositions = flat.enumerated().compactMap { idx, sel in
            InsightsCategoryGroups.category(for: sel) == .heart ? idx : nil
        }
        #expect(heartPositions.count == 2)
        #expect(isContiguousRun(heartPositions))
    }

    @Test("group members are listed in flat-swipe order")
    func groupMembersInSwipeOrder() {
        // Provide body members out of canonical order via layout order; the group
        // must list them in the order they appear in the flat list.
        let (_, strip) = model(visibleSlugs: [
            InsightsLayoutTileId.muscleMass,
            InsightsLayoutTileId.bodyWater,
            InsightsLayoutTileId.fatMass
        ])
        guard case let .group(category, members) = strip[1] else {
            Issue.record("expected a body group pill")
            return
        }
        #expect(category == .body)
        #expect(members == [.metric(.muscleMass), .metric(.bodyWater), .metric(.fatMass)])
    }

    @Test("the flat pager order clusters each category's members (v0153 contiguity restored)")
    func layoutOrderIsClusteredContiguous() {
        // HISTORY: `c8f1aa3b` removed v0153's `categoryContiguous` and rewrote this
        // test (then `layoutOrderIsNotResorted`) to assert the raw interleaved order
        // hrv · weight · pulse · sleep was returned VERBATIM — cementing the
        // swipe-order regression (the flat pager pages the scattered heart members
        // 1:1 while the strip folds them to one pill, so a swipe jumps out then back).
        // It is INVERTED here: `ordered(...)` pulls `pulse` up next to `hrv` (both
        // heart) at hrv's slot, so a swipe through the heart pill walks its members
        // in one continuous run. The pill SLOTS are unchanged (the strip still folds
        // heart to one pill at hrv's position) — only the pager traversal is fixed.
        let slugs = [
            InsightsLayoutTileId.hrv, // heart
            InsightsLayoutTileId.weight, // pinned
            InsightsLayoutTileId.pulse, // heart — pulled up next to hrv
            InsightsLayoutTileId.sleep // pinned
        ]
        let (flat, _) = model(visibleSlugs: slugs)
        #expect(flat == [
            .overview, .metric(.hrv), .metric(.pulse), .metric(.weight), .metric(.sleep)
        ])
    }
}

/// v0153 restored (after `c8f1aa3b` reverted it) + Parity 4.4 widened — unit tests
/// for `InsightsTabSelection.categoryContiguous`, the pure clustering pass applied
/// as the LAST step of `ordered(...)`. It pulls each category's members to sit
/// immediately after that category's first member, so the flat pager traversal
/// walks a category cleanly (pill N ↔ page N) instead of jumping across scattered
/// members. Widened from `MetricKind` to whole selections so the `workouts` special
/// page clusters into Aktivität too.
@Suite("Insights categoryContiguous — the flat-pager clustering pass")
struct InsightsCategoryContiguityTests {
    @Test("clusters interleaved members at each category's first slot")
    func clustersAtFirstSlot() {
        // hrv(heart) · bmi(body) · pulse(heart) · weight(pinned): pulse pulls up to
        // hrv's slot; bmi and weight keep their positions.
        let input: [InsightsTabSelection] = [
            .overview, .metric(.hrv), .metric(.bmi), .metric(.pulse), .metric(.weight)
        ]
        #expect(InsightsTabSelection.categoryContiguous(input) == [
            .overview, .metric(.hrv), .metric(.pulse), .metric(.bmi), .metric(.weight)
        ])
    }

    @Test("clusters the workouts special into the activity block")
    func clustersWorkouts() {
        // Parity 4.4 — the workouts SPECIAL page is an activity member and MUST
        // cluster with the chartable activity metrics (widened from `MetricKind`).
        // steps(activity) · bmi(body) · workouts(→activity) · walkingSpeed(activity).
        let input: [InsightsTabSelection] = [
            .overview, .metric(.steps), .metric(.bmi),
            .special(.workouts), .metric(.walkingSpeed)
        ]
        #expect(InsightsTabSelection.categoryContiguous(input) == [
            .overview, .metric(.steps), .special(.workouts),
            .metric(.walkingSpeed), .metric(.bmi)
        ])
    }

    @Test("is idempotent")
    func idempotent() {
        let input: [InsightsTabSelection] = [
            .overview, .metric(.hrv), .metric(.bmi), .metric(.pulse),
            .special(.workouts), .metric(.steps)
        ]
        let once = InsightsTabSelection.categoryContiguous(input)
        #expect(InsightsTabSelection.categoryContiguous(once) == once)
    }

    @Test("leaves overview, pinned/flat metrics, and recovery/mood/medications verbatim")
    func leavesUngroupedVerbatim() {
        // None of these carry a category (recovery is the fixed pill, mood/medications
        // are pinned, weight/sleep are flat) → the order is returned unchanged.
        let input: [InsightsTabSelection] = [
            .overview, .special(.recovery), .metric(.weight),
            .special(.mood), .metric(.sleep), .special(.medications)
        ]
        #expect(InsightsTabSelection.categoryContiguous(input) == input)
    }
}
