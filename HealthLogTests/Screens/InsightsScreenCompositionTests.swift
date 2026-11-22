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
/// moved to its own file (1.4 B4 deleted it with the on-device hero); the
/// `AlertsList(` Hinweise surface moved
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
        #expect(sectionLoop != nil, "The server-owned overview section loop must remain mounted.")
        #expect(correlations != nil, "Correlations must remain available on the overview.")
        if let sectionLoop, let correlations {
            #expect(
                sectionLoop.lowerBound < correlations.lowerBound,
                "Correlations must sit below all customizable sections, including Vitalwerte."
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
        // The "Trends" row repeated Vitalwerte and the Heute tiles; its section id renders nothing on iOS.
        #expect(!moduleBody.contains("InsightsTrendsRow(") && !moduleBody.contains("InsightsTrendsSlot("), "1.4 B4: Trends is gone.")
        // The "Rückblick" retrospective card was removed from the
        // overview (operator: "doesn't fit, too much"). It must NOT be mounted.
        #expect(
            !overviewBody.contains("InsightsRetrospectiveCard"),
            "v0.14.9 §1: the Rückblick card must no longer be on the overview."
        )
        // The Einschätzung reads a REAL server field (NOT fabricated).
        // v0.14.6 H3 rebound it from `store.comprehensive?.summary` (the
        // comprehensive digest never emits `summary`) to the AI briefing summary;
        // v0.14.7 A3 added a deterministic narrative fallback so prose appears for
        // provider-less accounts too. Pin both real sources. Post-W-PERF-INSIGHTS
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
        // The overview must NOT keep the dead-end trendChartMetric
        // navigation seam (a bare InsightsMetricScreen push with no tab strip).
        let screenBody = try codeBody(of: loadInsightsScreenSource())
        #expect(
            !screenBody.contains("$trendChartMetric"),
            "E4: the dead-end .navigationDestination(item: $trendChartMetric) must be removed."
        )
        // The Trends row must route through the navigable router seam.
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
    /// The old `kind == .bloodPressure` fork (rich `BPStatusCard`
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
        // Exactly ONE attachment now — the single canonical card replaced the
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
