import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **COACH-COIN (v0.5.5.7)** — regression locks for the dismissible Hero
/// flag + the collapsed coin that replaces it in the InsightsScreen
/// inline header trailing slot.
///
/// v0.6.1.8 Y7.1 moved the Coin from the body's inline-scrolling tile-row
/// slot into the inline screen header (handbook §3.1 Flavour B, mirrors
/// MoreScreen gear / MedicationsScreen plus / Home Gravatar). The
/// source-tree contract below asserts the new location.
///
/// Mirrors the source-tree + render-counter pattern from
/// `AskCoachHeroCardTests` — full snapshots would stand up eight
/// `@Environment` stores for an invariant that lives in a dozen lines
/// of view-body composition.
@Suite("AskCoachCollapsedCoin + coachHeroDismissed (COACH-COIN)")
@MainActor
struct AskCoachCollapsedCoinTests {
    // MARK: - Render smoke

    @Test("AskCoachCollapsedCoin renders to a non-zero image (body compiles + lays out)")
    func collapsedCoinRenders() {
        let renderer = ImageRenderer(content:
            AskCoachCollapsedCoin {}
                .frame(width: 40, height: 40)
        )
        renderer.scale = 1
        let image = renderer.uiImage
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
    }

    @Test("AskCoachCollapsedCoin fires its tap action exactly once per tap")
    func collapsedCoinTapFiresAction() {
        var tapCount = 0
        let coin = AskCoachCollapsedCoin {
            tapCount += 1
        }
        // We can't synthesize a real SwiftUI tap from a unit-test host —
        // but we can invoke the closure the view captures by forcing
        // the body to render (compile-time wiring check) and then
        // calling the action directly via Mirror reflection of the
        // stored `action` property.
        let mirror = Mirror(reflecting: coin)
        let actionChild = mirror.children.first(where: { $0.label == "action" })
        #expect(actionChild != nil)
        if let action = actionChild?.value as? () -> Void {
            action()
            action()
        }
        #expect(tapCount == 2)
    }

    // MARK: - SettingsStore flag contract

    private func makeSettingsStore(suiteName: String? = nil) throws -> SettingsStore {
        let suite = suiteName ?? "coach-coin-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let api = StubAPIClient()
        let repo = SettingsRepository(api: api)
        return SettingsStore(repo: repo, defaults: defaults)
    }

    @Test("coachHeroDismissed defaults to false on a fresh install")
    func coachHeroDismissedDefaultsFalse() throws {
        let store = try makeSettingsStore()
        #expect(store.coachHeroDismissed == false)
    }

    @Test("coachHeroDismissed persists across SettingsStore instances")
    func coachHeroDismissedPersists() throws {
        let suite = "coach-coin-tests-persist-\(UUID().uuidString)"
        let first = try makeSettingsStore(suiteName: suite)
        first.coachHeroDismissed = true
        let second = try makeSettingsStore(suiteName: suite)
        #expect(second.coachHeroDismissed == true)
    }

    @Test("clearOnLogout wipes coachHeroDismissed back to false")
    func clearOnLogoutResetsHeroDismissed() throws {
        let store = try makeSettingsStore()
        store.coachHeroDismissed = true
        store.clearOnLogout()
        #expect(store.coachHeroDismissed == false)
    }

    // MARK: - InsightsScreen composition contract

    private func loadInsightsScreenSource() throws -> String {
        let testFilePath = URL(fileURLWithPath: #filePath)
        let repoRoot = testFilePath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let insightsDir = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        // W-PERF-INSIGHTS (v0152) — the inline header was extracted into the
        // store-scoped `InsightsOverviewHeader` leaf in `Sub/InsightsOverviewSlots
        // .swift` (pure code movement, same module) to shrink Observation
        // invalidation. Scan both files so the header-wiring contract follows it.
        let screen = try String(
            contentsOf: insightsDir.appendingPathComponent("InsightsScreen.swift"),
            encoding: .utf8
        )
        let slots = try String(
            contentsOf: insightsDir
                .appendingPathComponent("Sub")
                .appendingPathComponent("InsightsOverviewSlots.swift"),
            encoding: .utf8
        )
        return screen + "\n" + slots
    }

    @Test("InsightsScreen surfaces the unified Coach circle in the inline header trailing slot")
    func insightsScreenWiresCollapsedCoinInHeader() throws {
        // v0.6.1.8 Y7.1 — the Coach affordance lives in the inline screen header
        // trailing slot, mirroring the Home Gravatar / MoreScreen gear /
        // MedicationsScreen plus pattern (handbook §3.1 Flavour B).
        //
        // v0.14 FINAL-QA DRIFT-3 — the overview Coach affordance was unified onto
        // the SAME `InsightsHeaderActionCircle(sparkles)` every other Insights
        // header uses, replacing the bespoke `AskCoachCollapsedCoin`. This
        // contract now pins the unified circle (`sparkles` glyph) in the header.
        let source = try loadInsightsScreenSource()
        let codeLines = source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        let codeBody = codeLines.joined(separator: "\n")
        // DRIFT-3 — the Coach affordance is the unified header circle now.
        #expect(codeBody.contains("InsightsHeaderActionCircle"))
        #expect(codeBody.contains("systemImage: \"sparkles\""))
        // The bespoke brand coin is no longer wired into the overview header.
        #expect(!codeBody.contains("AskCoachCollapsedCoin"))
        // Task #53 — the header Coach is no longer `coachHeroDismissed`-gated
        // (W22 made it always-present when the assistant flag is on). Its live
        // gate is now the three-way AI-source choice: it surfaces in `.onDevice`
        // and `.online` via `aiSurfacesVisible`, AND the `assistantCoach` flag.
        // (The prior `coachHeroDismissed` assertion was obsolete — that token now
        // appears only inside an explanatory comment, which this source-grep
        // strips, so it asserted a contract the screen had already retired.)
        #expect(codeBody.contains("aiSurfacesVisible"))
        // The Coin must not sit in the legacy topBarTrailing toolbar slot.
        #expect(
            !codeBody.contains("topBarTrailing"),
            """
            InsightsScreen.swift should not pin the Coin into the trailing \
            toolbar slot — the Coin lives in the inline header now (Y7.1).
            """
        )
        // The Coin is hosted by the inline header, not by a
        // dismiss-state inline-scrolling tile row.
        #expect(
            codeBody.contains("InsightsOverviewHeader"),
            """
            The Insights overview should declare an `InsightsOverviewHeader` view \
            hosting the Coin in its trailing slot (Y7.1 inline header; extracted to \
            a store-scoped leaf in W-PERF-INSIGHTS).
            """
        )
        #expect(
            !codeBody.contains("inlineCoachCoin"),
            """
            The Y3-era `inlineCoachCoin` body row was retired in Y7.1; the \
            Coin now lives in the inline screen header.
            """
        )
        // navigationTitle is replaced by the inline-header large title;
        // the navbar is hidden so two titles don't stack.
        #expect(
            !codeBody.contains("navigationTitle"),
            """
            InsightsScreen.swift should rely on the inline-header large \
            title (handbook §3.1 Flavour B), not a separate \
            `.navigationTitle` modifier.
            """
        )
    }

    @Test("InsightsScreen exposes the header Coin via the Y7.1 accessibility identifier")
    func insightsScreenCoinHasHeaderAccessibilityIdentifier() throws {
        // v0.6.1.8 Y7.1 — the Coin's host gets a distinct
        // accessibility identifier so XCUI walkthroughs can resolve the
        // header instance without coupling to the legacy inline-row id.
        let source = try loadInsightsScreenSource()
        #expect(source.contains("\"InsightsScreen.askCoachCollapsedCoin.header\""))
    }

    @Test("Y9-E: header Coach circle opens AskCoachSheet instead of restoring the Hero")
    func insightsScreenCoinOpensChatSheetOnTap() throws {
        // v0.6.1.10 Y9-E — operator-revised contract: the Coach affordance's tap
        // handler sets `presentAskCoach = true` rather than flipping
        // `coachHeroDismissed`. v0.14 DRIFT-3 — the affordance is now the unified
        // `InsightsHeaderActionCircle`, keyed by its preserved header identifier;
        // anchor the closure assertion on that identifier.
        let source = try loadInsightsScreenSource()
        // The Coach circle's closure body must NOT reset coachHeroDismissed.
        // W-PERF-INSIGHTS — the circle now lives in the extracted
        // `InsightsOverviewHeader` leaf and fires the injected `onAskCoach()`
        // closure, which the host (`InsightsScreen`) wires to `presentAskCoach =
        // true`. Assert the indirection: the circle fires `onAskCoach()`, and the
        // host wires it to `presentAskCoach = true`.
        let coinBlockStart = source.range(of: "\"InsightsScreen.askCoachCollapsedCoin.header\"")
        #expect(coinBlockStart != nil)
        if let coinBlockStart {
            // Look at the next ~20 lines after the identifier (the action closure).
            let afterCoin = source[coinBlockStart.upperBound...]
            let snippet = String(afterCoin.prefix(800))
            #expect(snippet.contains("onAskCoach()"))
            #expect(!snippet.contains("coachHeroDismissed = false"))
        }
        // The host wires the header's `onAskCoach` to open the AskCoach sheet.
        #expect(source.contains("onAskCoach: { presentAskCoach = true }"))
        // matchedGeometryEffect tying the Coin to the Hero is removed.
        #expect(!source.contains("matchedGeometryEffect(id: \"insights.coach.row\""))
    }
}
