import Foundation
@testable import HealthLog
import Testing

/// v0152 C4 (operator-confirmed) — the INLINE coach button on every Insights
/// metric page. Sits to the RIGHT of that page's edit (gear) button; tapping it
/// opens the canonical `AskCoachSheet`, which routes to the correct arm per user
/// (`prefersServerArm`, fixed in C3 `831665ec`): an External-AI-selected user
/// reaches the EXTERNAL web/server coach, never silently on-device, and never
/// mints an on-device consent receipt (the sheet surfaces the consent CTA when a
/// server grant is pending). An on-device chooser keeps the on-device arm.
///
/// The b198/B2 behaviour where the per-page coach circle FELL BACK to the on-device
/// assistant-insight explainer when no coach flag was set is REMOVED — the button
/// always opens the coach (the sheet decides the arm), so there is no `coachConfigured`
/// fork and no `presentExplainer` fallback on this page any more.
///
/// The view needs many `@Environment` stores to render, so we pin the source-tree
/// contract the way the prior B2 test (and `AskCoachCollapsedCoinTests`) does.
@Suite("InsightsMetric inline Coach button (v0152 C4)")
struct InsightsMetricCoachButtonTests {
    private func loadMetricScreenSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Insights
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        let dir = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        // file_length split: the screen's source spans the screen file plus its
        // `+Sections.swift` sibling (pure code movement) — assert across both.
        return try String(
            contentsOf: dir.appendingPathComponent("InsightsMetricScreen.swift"),
            encoding: .utf8
        ) + String(
            contentsOf: dir.appendingPathComponent("InsightsMetricScreen+Sections.swift"),
            encoding: .utf8
        )
    }

    @Test("the inline coach button always opens AskCoachSheet — no explainer fallback")
    func coachButtonAlwaysOpensAskCoach() throws {
        let source = try loadMetricScreenSource()
        // The coach circle's action sets `presentAskCoach` unconditionally — no
        // `if coachConfigured { … } else { presentExplainer = true }` fork.
        #expect(source.contains("presentAskCoach = true"))
        #expect(!source.contains("if coachConfigured {"))
        #expect(!source.contains("presentExplainer"))
        // The AskCoach sheet must be wired so the button actually presents it.
        #expect(source.contains(".sheet(isPresented: $presentAskCoach"))
        // A360 H2 / W7 scope-handoff — the sheet is now seeded + scoped (metric
        // seed + `CoachLaunchScope`), NOT the bare `AskCoachSheet()`. The CONTRACT
        // (always opens the coach sheet, no explainer fork) is unchanged; only the
        // construction now passes a `seed:` + `launchScope:`.
        #expect(source.contains("AskCoachSheet("))
        #expect(source.contains("seed:"))
        #expect(source.contains("launchScope:"))
        // The bare no-arg construction must NOT be the wiring any more — re-adding
        // it would drop the per-page scope handoff.
        #expect(!source.contains("AskCoachSheet()"))
    }

    @Test("the coach button sits inline in the metric header with a stable identifier + press feedback")
    func coachButtonIsInlineAndPressable() throws {
        let source = try loadMetricScreenSource()
        // Inline header affordance (the `InsightsHeaderActionCircle` next to the
        // gear), with a stable accessibility identifier and `.hlPressable()` feedback.
        #expect(source.contains("insights.metric.coach."))
        #expect(source.contains("InsightsHeaderActionCircle("))
        #expect(source.contains(".hlPressable()"))
    }

    @Test("the on-device assistant-insight explainer is no longer wired on the metric page")
    func explainerSheetIsRemoved() throws {
        let source = try loadMetricScreenSource()
        // C4: no on-device explainer surface — `MetricAIExplainerSheet` is gone from
        // this page (the coach sheet routes correctly per user instead).
        #expect(!source.contains("MetricAIExplainerSheet"))
    }
}
