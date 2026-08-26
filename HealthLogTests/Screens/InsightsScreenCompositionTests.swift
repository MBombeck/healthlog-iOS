import Foundation
import Testing

/// Visual-Polish-1 (2026-05-16) — locks the Insights surface composition
/// against the duplicate-Heute-Block regression flagged by operator
/// real-device walkthrough on `v0.5.3.5-rc-theme-2.0`.
///
/// **Why source-string assertions:** `InsightsScreen` is composed of many
/// `@Environment(...)` stores so a full SwiftUI render-test would have to
/// stand up `InsightsStore` + `DailyBriefingStore` + `HealthScoreStore` +
/// `MeasurementsStore` with fake repos — a 200-line test setup for an
/// invariant that lives in 3 lines of view-body code. Source-string
/// assertions catch the regression at the same place the bug lives (the
/// view-body composition) without that infra. The trade-off: changing the
/// `InsightsScreen.swift` file path or adding a comment that mentions
/// `DailyBriefingCard()` will trip the test. Both are explicit + traceable.
///
/// **v0.11 #6 Insights rebuild (post-layout):** the screen was decomposed
/// into ordered zones under `HealthLog/Screens/Insights/`. The hero wrapper
/// (`InsightsBriefingHero` → `OnDeviceBriefingHero(`) moved to
/// `Sub/InsightsBriefingHero.swift`; the `AlertsList(` Hinweise surface moved
/// into `Zones/InsightsDynamicsZone.swift`. The *gates* (`assistant.briefing`
/// flag + the `briefingObservationsEnabled` kill-switch) still live at the
/// call site in `InsightsScreen.swift`. These tests now scan the whole
/// Insights module for the relocated construction sites and keep the gate
/// assertions pinned to the call-site file, so the invariants survive the
/// relocation without going brittle on a single hard-coded path.
@Suite("Insights surface composition")
struct InsightsScreenCompositionTests {
    /// Repo-root anchor — walks up from this test file's `#filePath`.
    /// HealthLogTests/Screens/InsightsScreenCompositionTests.swift
    ///   ↑ Screens  ↑ HealthLogTests   ↑ repo root
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
    }

    /// The `InsightsScreen.swift` source — the screen body + call-site gates.
    private func loadInsightsScreenSource() throws -> String {
        let target = Self.repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
            .appendingPathComponent("InsightsScreen.swift")
        return try String(contentsOf: target, encoding: .utf8)
    }

    /// A single relocated Insights source file, by path components under
    /// `HealthLog/Screens/Insights/`.
    private func loadInsightsSource(_ components: String...) throws -> String {
        var target = Self.repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        for component in components {
            target.appendPathComponent(component)
        }
        return try String(contentsOf: target, encoding: .utf8)
    }

    /// Concatenates EVERY `.swift` under `HealthLog/Screens/Insights/` so an
    /// invariant phrased as "anywhere on the Insights surface" survives a
    /// file relocation (the #6 zone decomposition moved several primitives
    /// between files). Used for the cross-file presence / absence checks.
    private func loadInsightsModuleSource() throws -> String {
        let root = Self.repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        let fm = FileManager.default
        var stack = [root.path]
        var merged = ""
        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                let full = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    stack.append(full)
                } else if entry.hasSuffix(".swift") {
                    merged += (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
                    merged += "\n"
                }
            }
        }
        return merged
    }

    /// Strips `//` / `///` comment lines so source-string assertions count
    /// only real construction sites, not doc-rationale mentions.
    private func codeBody(of source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
            }
            .joined(separator: "\n")
    }

    @Test("InsightsScreen renders exactly one Heute-Block (no duplicate)")
    func insightsScreenHasOneHeuteBlock() throws {
        // v0.9.0 W2 — the on-device briefing hero is RE-INTRODUCED on
        // Insights (the "Today at a glance" slot). The earlier v0.5.4.x
        // regression had TWO stacked cards — `OnDeviceBriefingHero` (with
        // on-device content) followed by a redundant empty
        // `DailyBriefingCard()` placeholder. The on-device hero already
        // handles every arm (on-device → floor → server → empty) via its
        // own resolution ladder, so `DailyBriefingCard()` must NOT appear
        // as a second construction site.
        //
        // This test asserts the Insights surface references
        // `OnDeviceBriefingHero(` exactly once and `DailyBriefingCard()` not
        // at all. Reading the types in a comment / docstring is fine — only
        // constructor call sites count.
        //
        // **v0.11 #6:** `OnDeviceBriefingHero(` is now constructed inside the
        // extracted `InsightsBriefingHero` wrapper at
        // `Sub/InsightsBriefingHero.swift` (no longer inline in
        // `InsightsScreen.swift`). We scan the whole Insights module so the
        // "exactly one hero construction site" invariant holds regardless of
        // which file owns it.
        let moduleBody = try codeBody(of: loadInsightsModuleSource())
        let dailyBriefingCardCalls = moduleBody
            .components(separatedBy: "DailyBriefingCard(").count - 1
        #expect(
            dailyBriefingCardCalls == 0,
            """
            The Insights surface should not reference DailyBriefingCard() — \
            the on-device hero handles both paths via serverFallback:
            """
        )
        let heroCalls = moduleBody
            .components(separatedBy: "OnDeviceBriefingHero(").count - 1
        #expect(
            heroCalls == 1,
            """
            The Insights surface must construct OnDeviceBriefingHero exactly \
            once (the single Today-at-a-glance slot), got \(heroCalls). \
            Post-#6 it lives in Sub/InsightsBriefingHero.swift.
            """
        )
    }

    @Test("v0.14.1 §4 — overview drops the briefing hero / prompts / dynamics / long-tail")
    func insightsOverviewDropsRemovedBlocks() throws {
        // v0.14.1 §4 (operator brief, post-b147 walk): the overview was
        // restructured to a calm column. The "Heute auf einen Blick" briefing
        // hero, the "Frag mich" prompt chips, the Dynamics zone, the Vitals
        // dashboard and the long-tail "weitere Werte" block were ALL removed
        // from the overview body. This asserts none of those construction sites
        // remain in `InsightsScreen`'s own body (they may still exist as
        // orphaned components elsewhere in the module — that's fine; the brief
        // only removes them from the overview). The briefing kill-switch gate is
        // gone with the hero.
        //
        // v0.14.3 B1: `coachHeroDismissed` is INTENTIONALLY re-introduced — the
        // Coach hero is dismissible again (close affordance → persisted UI-pref),
        // so it is no longer in the removed-list below.
        //
        // **Parity Build 4 · 4.2 — `InsightsVitalsDashboard(` left this list.**
        // v0.14.1 §4 dropped the Vitals block's only call site and the block was
        // then orphaned for the entire redesign, which is precisely why the
        // operator could no longer see BMI / weight / sleep on the overview. It
        // is remounted as the `vitals` overview SECTION (`InsightsVitalsSlot` in
        // `Sub/InsightsOverviewSlots.swift`), operator-hideable like every other
        // section — so asserting it is absent would now pin the bug, not the
        // intent. The other four removals stand.
        let screenBody = try codeBody(of: loadInsightsScreenSource())
        for removed in [
            "InsightsBriefingHero(",
            "InsightsSuggestedPromptsRow(",
            "InsightsDynamicsZone(",
            "PerKindInsightsBlock(",
            "DataQualityFooter(",
            "briefingObservationsEnabled"
        ] {
            #expect(
                !screenBody.contains(removed),
                "v0.14.1 §4: the overview body must no longer construct/reference \(removed)."
            )
        }
    }

    @Test("Insights overview keeps quiet coach affordances and anchors correlations below sections")
    func insightsOverviewOrder() throws {
        // W-PERF-INSIGHTS (v0152 perf audit C1) — the overview composition was
        // decomposed into store-scoped leaf SLOTS so each `@Observable` store is
        // read by the smallest leaf that needs it (shrinks Observation
        // invalidation scope). The ordered zone composition now lives in
        // `InsightsOverviewBody.loadedContent` (mounting the slots) within
        // `Sub/InsightsOverviewSlots.swift`. The customizable server sections
        // remain intact; correlations are an anchored, collapsed footer below
        // all of them. The colourful Coach hero is removed from this overview,
        // while consent re-engagement and cadence suggestions remain available.
        let overviewBody = try codeBody(of: loadInsightsSource("Sub", "InsightsOverviewSlots.swift"))
        let moduleBody = try codeBody(of: loadInsightsModuleSource())
        let sectionLoop = overviewBody.range(of: "ForEach(layoutStore.layout.visibleSectionIds")
        let correlations = overviewBody.range(of: "InsightsCorrelationsSlot(")
        let trailingState = overviewBody.range(of: "InsightsEmptyErrorSlot()")
        #expect(sectionLoop != nil, "The server-owned overview section loop must remain mounted.")
        #expect(correlations != nil, "Correlations must remain available on the overview.")
        #expect(trailingState != nil, "The anchored empty/error state must remain last.")
        if let sectionLoop, let correlations, let trailingState {
            #expect(
                sectionLoop.lowerBound < correlations.lowerBound,
                "Correlations must sit below all customizable sections, including Vitalwerte."
            )
            #expect(
                correlations.lowerBound < trailingState.lowerBound,
                "Correlations must remain above the terminal empty/error state."
            )
        }
        #expect(
            overviewBody.contains("InsightsCoachSlot(appContainer:"),
            "The quiet Coach re-engagement and cadence slot must remain mounted."
        )
        #expect(
            !overviewBody.contains("AskCoachHeroCard("),
            "The colourful Ask Coach hero must not be inserted on this overview."
        )
        #expect(moduleBody.contains("CoachReengageCard("), "Coach consent re-engagement must remain reusable.")
        #expect(
            moduleBody.contains("CoachCadenceSuggestionsSection("),
            "Coach cadence suggestions must remain reusable."
        )
        #expect(
            moduleBody.contains("InsightsServerDerivedOverview("),
            "Wellness scores (InsightsServerDerivedOverview) must exist."
        )
        #expect(moduleBody.contains("InsightsTrendsRow("), "Trends (InsightsTrendsRow) must exist.")
        // v0.14.9 §1 — the "Rückblick" retrospective card was removed from the
        // overview (operator: "doesn't fit, too much"). It must NOT be mounted.
        #expect(
            !overviewBody.contains("InsightsRetrospectiveCard"),
            "v0.14.9 §1: the Rückblick card must no longer be on the overview."
        )
        // The Einschätzung reads a REAL server field (NOT fabricated).
        // v0.14.6 H3 rebound it from `store.comprehensive?.summary` (the
        // comprehensive digest never emits `summary`) to the AI briefing summary;
        // v0.14.7 A3 added a deterministic narrative fallback so prose appears for
        // provider-less accounts too. Pin both real sources (B4). Post-W-PERF-INSIGHTS
        // they live in `InsightsDailyBriefingSlot` (still in the Insights module).
        // 2026-07-18 (parity Wave 1 · 1.2): rebound from `briefingStore.summary`
        // to `briefingStore.paragraphContent`. Reading `summary` DIRECTLY skipped
        // `briefing?.paragraph`, so the "Tagesbriefing" heading rendered the weekly
        // narrative (web's "Rückblick diese Woche") instead of the real daily
        // briefing. `paragraphContent` == `briefing?.paragraph ?? summary`, so the
        // H3 intent (read a REAL server field, never a fabricated one) is preserved
        // AND the true daily text now wins. Both real sources stay pinned.
        #expect(
            moduleBody.contains("briefingStore.paragraphContent"),
            "The Einschätzung must read briefingStore.paragraphContent (H3, rebound 2026-07-18 — it prefers briefing?.paragraph and still falls back to summary)."
        )
        #expect(
            !moduleBody.contains("briefingStore.summary"),
            "The Einschätzung must NOT read briefingStore.summary directly — that skips the daily briefing paragraph and surfaces the weekly narrative (b227 bug)."
        )
        #expect(
            moduleBody.contains("narrativeStore.narrative(for:"),
            "The Einschätzung must fall back to the deterministic period narrative (A3)."
        )
        // v0.14.3 E4: the overview must NOT keep the dead-end trendChartMetric
        // navigation seam (a bare InsightsMetricScreen push with no tab strip).
        let screenBody = try codeBody(of: loadInsightsScreenSource())
        #expect(
            !screenBody.contains("$trendChartMetric"),
            "E4: the dead-end .navigationDestination(item: $trendChartMetric) must be removed."
        )
        // E4: the Trends row must route through the navigable router seam.
        #expect(
            screenBody.contains("router.selectInsightsMetric"),
            "E4: the Trends row must route via router.selectInsightsMetric (tab strip + swipe + back)."
        )
    }

    // MARK: - v0.14.1 D — pin affordance guard

    /// Guards the regression the v0.14 Insights redesign introduced: the
    /// `.pinToHomeContextMenu` long-press affordance was silently dropped from
    /// the canonical per-metric primary card, so long-pressing a metric in
    /// Insights did nothing. There was NO test asserting the affordance was
    /// attached — which is exactly why the redesign could drop it unnoticed.
    ///
    /// **v0.14.3 C4:** the old `kind == .bloodPressure` fork (rich `BPStatusCard`
    /// vs thin `InsightsPrimaryTile`) was collapsed into ONE canonical
    /// `InsightsMetricStatusCard` (`statusBlock`), so there is now exactly ONE
    /// pin attachment — the single canonical 30-day card every metric routes
    /// through. This guard fails the build if a future redesign detaches it again.
    @Test("pin-to-home affordance is attached to the canonical Insights metric card")
    func pinAffordanceOnPrimaryMetricTile() throws {
        // file_length split: the screen's source spans the screen file plus its
        // `+Sections.swift` sibling (pure code movement) — assert across both.
        let metricScreen = try loadInsightsSource("InsightsMetricScreen.swift")
            + loadInsightsSource("InsightsMetricScreen+Sections.swift")
        #expect(
            metricScreen.contains(".pinToHomeContextMenu(kind: kind, container: appContainer)"),
            """
            InsightsMetricScreen must attach `.pinToHomeContextMenu` to its \
            canonical 30-day status card (InsightsMetricStatusCard) — without it \
            every metric is un-pinnable from Insights.
            """
        )
        // C4: exactly ONE attachment now — the single canonical card replaced the
        // BPStatusCard + InsightsPrimaryTile fork (which carried one each).
        let occurrences = metricScreen.components(
            separatedBy: ".pinToHomeContextMenu(kind: kind, container: appContainer)"
        ).count - 1
        #expect(
            occurrences == 1,
            """
            Expected the pin affordance on exactly the ONE canonical metric card \
            (the v0.14.3 C4 unification); found \(occurrences).
            """
        )
    }

    /// Guards the at-a-glance vital tiles on the overview: each must re-gain the
    /// pin affordance too, so EVERY metric (not just a few) is pinnable.
    @Test("pin-to-home affordance is attached to the overview vital tiles")
    func pinAffordanceOnVitalTiles() throws {
        let vitals = try loadInsightsSource("Sub", "InsightsVitalsDashboard.swift")
        #expect(
            vitals.contains(".pinToHomeContextMenu(kind: tile.kind, container: container)"),
            """
            InsightsVitalsDashboard tiles must carry `.pinToHomeContextMenu` so \
            the overview's at-a-glance vitals are long-press-pinnable to Home.
            """
        )
    }
}

/// v0.5.3 F-2 (operator walkthrough, 2026-05-17) lock-in: the Stimmung-
/// summary card used to prefix each Ø-value with a literal emoji
/// (😞 🙁 😐 🙂 😄). Operator flagged the mismatch against the rest of
/// the Insights surface (tonal-mono charts, monospaced numbers). The
/// card was rewritten to drop emoji literals + render a 1–5 scale rail
/// with `HLChartTints.series` marker.
@Suite("MoodSummaryCard tonal-mono composition")
struct MoodSummaryCardCompositionTests {
    private func loadMoodSummarySource() throws -> String {
        let testFilePath = URL(fileURLWithPath: #filePath)
        let repoRoot = testFilePath
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
        let target = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
            .appendingPathComponent("InsightsDigestComponents.swift")
        return try String(contentsOf: target, encoding: .utf8)
    }

    @Test("MoodSummaryCard renders no emoji literals in the value columns")
    func moodSummaryDropsEmojiPrefix() throws {
        let source = try loadMoodSummarySource()
        // The historic prefix glyphs — none of them may appear inside
        // the rendered body. We allow them in comments (doc-rationale
        // references the dropped behaviour) but not in code.
        let codeLines = source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        let codeBody = codeLines.joined(separator: "\n")
        for glyph in ["😞", "🙁", "😐", "🙂", "😄"] {
            #expect(
                !codeBody.contains(glyph),
                """
                MoodSummaryCard code body must not contain the \(glyph) glyph — \
                emoji prefixes were removed in v0.5.3 F-2.
                """
            )
        }
    }

    @Test("MoodSummaryCard wires its scale marker to HLChartTints.series")
    func moodSummaryUsesChartTintsForMarker() throws {
        // The marker must read its colour from the shared chart-tint
        // palette so the Stimmung card sits visually next to the BMI /
        // BP cards (which sample HLColor.statusOK etc.) and the dashboard
        // sparklines (`HLChartTints.series`).
        let source = try loadMoodSummarySource()
        #expect(
            source.contains("HLChartTints.series"),
            """
            MoodSummaryCard must reference HLChartTints.series — the \
            scale-rail marker has to track the global chart tint.
            """
        )
    }
}
