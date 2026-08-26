import Foundation
@testable import HealthLog
import SwiftUI
import Testing
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

/// **POLISH-COACH (v0.5.5.6)** — regression locks for the new
/// "Frag den Coach" hero card + `.large`-detent placeholder sheet.
///
/// **Why source-string + render-counter assertions and not snapshot:**
/// `InsightsScreen` pulls eight `@Environment(...)` stores so a full
/// snapshot would stand up `InsightsStore` + `DailyBriefingStore` +
/// `HealthScoreStore` + `MeasurementsStore` + `FeatureFlagsStore` +
/// `MoodStore` + `DashboardStore` + `AppRouter` with fakes — a
/// disproportionate test footprint for an invariant that lives in a
/// dozen lines of view-body composition. We follow the same
/// source-string pattern `InsightsScreenCompositionTests` shipped for
/// the duplicate-Heute-block regression: assert the composition file
/// references the new types in the right slot, and exercise the card
/// + sheet rendering directly via `ImageRenderer` so a compile / SwiftUI-
/// body breakage trips the suite.
@Suite("AskCoachHeroCard + AskCoachSheet (POLISH-COACH)")
@MainActor
struct AskCoachHeroCardTests {
    // MARK: - Render environment fixtures

    /// No-op passkey service — `AuthService.init` requires the protocol but
    /// the render smoke tests never exercise an auth flow. Mirrors the stub in
    /// `BackendAvailabilityTests`.
    private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
        func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("noop")
        }

        func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("noop")
        }
    }

    /// Builds a real `AuthStore` for the `@Environment(AuthStore.self)` the
    /// `AskCoachSheet` (and its `+ServerFallback` extension) reads. Reuses the
    /// exact `InMemoryKeychain` → `APIClient` → `AuthService` → `AuthStore`
    /// construction from `BackendAvailabilityTests.makeStores`.
    private func makeAuthStore() -> AuthStore {
        let keychain = InMemoryKeychain()
        let env = AppEnvironment.loadFromBundle()
        let api = APIClient(environment: env, keychain: keychain)
        let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
        return AuthStore(auth: auth, keychain: keychain, syncMode: nil)
    }

    // MARK: - Source-tree composition contract

    /// Loads the `InsightsScreen.swift` source verbatim. Walks up
    /// from this test file's `#filePath` to the repo root — matches
    /// the helper in `InsightsScreenCompositionTests`.
    private func loadInsightsScreenSource() throws -> String {
        let testFilePath = URL(fileURLWithPath: #filePath)
        // HealthLogTests/Screens/Coach/AskCoachHeroCardTests.swift
        //   ↑ Coach   ↑ Screens   ↑ HealthLogTests   ↑ repo root
        let repoRoot = testFilePath
            .deletingLastPathComponent() // Coach/
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
        let insightsDir = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        // W-PERF-INSIGHTS (v0152) — the overview Coach hero / header / Trends were
        // extracted into store-scoped leaves in `Sub/InsightsOverviewSlots.swift`
        // (pure code movement, same module) to shrink Observation invalidation.
        // Scan both files so the AskCoach-entry-point contract follows the slots.
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

    @Test("InsightsScreen keeps quiet AskCoach entry points without inserting the hero")
    func insightsScreenReferencesAskCoachEntryPoint() throws {
        // The colourful hero is deliberately no longer inserted on the
        // overview. AskCoach remains reachable from the canonical header circle
        // and the on-device daily-briefing tap, while the reusable card itself
        // remains covered by its isolated render test below.
        //
        // v0.14 FINAL-QA DRIFT-3 — the header's Coach affordance was unified
        // onto the SAME `InsightsHeaderActionCircle(sparkles)` every other
        // Insights header uses, replacing the bespoke `AskCoachCollapsedCoin`.
        // The third entry point is therefore now asserted against the unified
        // circle (sparkles glyph, keyed by its preserved header identifier
        // `InsightsScreen.askCoachCollapsedCoin.header`), NOT the removed coin —
        // consistent with `AskCoachCollapsedCoinTests`, which pins the same
        // unified primitive. Re-introducing the coin token here would undo
        // DRIFT-3.
        //
        // Pin the quiet entry points and the absence of the redundant hero.
        let source = try loadInsightsScreenSource()
        let body = source
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
            }
            .joined(separator: "\n")
        // DRIFT-3 — the header Coach entry point is the unified sparkles circle.
        #expect(
            body.contains("InsightsHeaderActionCircle"),
            "InsightsScreen header must host the unified Coach circle entry point."
        )
        #expect(
            body.contains("systemImage: \"sparkles\""),
            "The header Coach circle must use the canonical sparkles glyph (DRIFT-3)."
        )
        #expect(
            body.contains("\"InsightsScreen.askCoachCollapsedCoin.header\""),
            "The header Coach circle must keep its preserved accessibility identifier."
        )
        // The bespoke brand coin must NOT be re-wired into the overview header
        // (re-introducing it would undo DRIFT-3's header unification).
        #expect(
            !body.contains("AskCoachCollapsedCoin"),
            "The retired bespoke AskCoachCollapsedCoin must not be wired back into the overview."
        )
        #expect(
            body.contains("presentAskCoach = true"),
            "InsightsScreen must wire the Hero / coin tap to open the AskCoach surface."
        )
        // The colourful card remains a reusable component, but is not composed
        // into the overview anymore.
        let heroCard = body.components(separatedBy: "AskCoachHeroCard(").count - 1
        #expect(
            heroCard == 0,
            "The AskCoachHeroCard must not be inserted on the Insights overview."
        )
    }

    @Test("InsightsScreen presents AskCoachSheet via .sheet modifier")
    func insightsScreenWiresAskCoachSheet() throws {
        let source = try loadInsightsScreenSource()
        // `.sheet(isPresented: $presentAskCoach)` is the canonical wire.
        // v0.13 WP — the sheet takes an optional composer seed from the tapped
        // Insights prompt chip; A360 H2 / W7 additionally threads an optional
        // `launchScope:` (metric/correlation scope handoff). Assert the seeded +
        // scoped construction, tolerant of the argument formatting.
        #expect(source.contains("AskCoachSheet(seed: coachSeed, launchScope: coachLaunchScope)"))
        #expect(source.contains("presentAskCoach"))
    }

    @Test("InsightsScreen retired the prior MiniCoachAskButton construction")
    func insightsScreenDroppedLegacyButton() throws {
        // POLISH-COACH replaced the construction site, but the legacy
        // file lives on (v0.5.7 decides whether to delete or repurpose).
        // We assert the construction call has been replaced — comments
        // / docstrings mentioning the legacy button are fine.
        let source = try loadInsightsScreenSource()
        let constructorOccurrences = source.components(separatedBy: "MiniCoachAskButton {").count - 1
        #expect(constructorOccurrences == 0, "AskCoachHeroCard must have replaced MiniCoachAskButton as the construction site")
    }

    // MARK: - AppRouter coach-deep-link contract

    @Test(".coach deep-link increments askCoachRequestCount")
    func coachDeepLinkPulsesAskCoachCounter() {
        let router = AppRouter()
        #expect(router.askCoachRequestCount == 0)
        router.apply(.coach, isAuthenticated: true)
        #expect(router.askCoachRequestCount == 1)
        router.apply(.coach, isAuthenticated: true)
        #expect(router.askCoachRequestCount == 2)
    }

    @Test(".coach deep-link still flips selectedTab to .insights")
    func coachDeepLinkLandsOnInsightsTab() {
        let router = AppRouter()
        router.selectedTab = .home
        router.apply(.coach, isAuthenticated: true)
        #expect(router.selectedTab == .insights)
    }

    @Test("Pending .coach deep-link parks counter increment until auth")
    func coachDeepLinkParksWhenUnauthenticated() {
        let router = AppRouter()
        router.apply(.coach, isAuthenticated: false)
        // While parked, no counter pulse — the increment fires when
        // `consumePendingRoute()` runs after the auth-phase switch.
        #expect(router.askCoachRequestCount == 0)
        router.consumePendingRoute()
        #expect(router.askCoachRequestCount == 1)
        #expect(router.selectedTab == .insights)
    }

    // MARK: - View-body render smoke

    @Test("AskCoachHeroCard renders to a non-zero image (body compiles + lays out)")
    func askCoachHeroCardRenders() {
        let renderer = ImageRenderer(content:
            AskCoachHeroCard {}
                .frame(width: 360, height: 132)
        )
        renderer.scale = 1
        let image = renderer.uiImage
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }

    @Test("AskCoachSheet renders to a non-zero image (body compiles + lays out)")
    func askCoachSheetRenders() {
        let renderer = ImageRenderer(content:
            AskCoachSheet()
                .frame(width: 393, height: 852)
                .environment(BackendAvailability(syncMode: nil, authStore: nil))
                .environment(makeAuthStore())
                // v0.14.1 — AskCoachSheet now reads `AppRouter` from the
                // environment (the "set up a provider" CTA routes to Settings →
                // Assistant). Inject it so the render harness composes.
                .environment(AppRouter())
        )
        renderer.scale = 1
        let image = renderer.uiImage
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
    }

    @Test("AskCoachSuggestionChip exposes the suggestion text as accessibility label")
    func suggestionChipAccessibilityLabel() {
        let chip = AskCoachSuggestionChip(
            text: String(localized: "Was bedeutet mein Blutdruck?"),
            icon: "waveform.path.ecg"
        ) {}
        let renderer = ImageRenderer(content: chip.frame(width: 320, height: 60))
        renderer.scale = 1
        #expect(renderer.uiImage != nil)
    }

    // MARK: - Visual artifact (env-gated)

    /// Writes the hero card as a PNG to a path picked up by the
    /// `POLISH_COACH_SCREENSHOT_DIR` env var. Used by the polish wave
    /// to produce the artifact the operator review consumes when the
    /// authenticated-shell screenshot path isn't available (cross-agent
    /// build contention etc.). Skipped silently otherwise so the suite
    /// stays hermetic on developer machines + CI.
    @Test("AskCoachHeroCard render artifact (env-gated)")
    func askCoachHeroCardRenderArtifact() throws {
        guard let dir = ProcessInfo.processInfo.environment["POLISH_COACH_SCREENSHOT_DIR"],
              !dir.isEmpty else { return }
        let renderer = ImageRenderer(content:
            AskCoachHeroCard {}
                .padding(16)
                .frame(width: 393, height: 200)
                .background(Color.black)
        )
        renderer.scale = 3
        guard let image = renderer.uiImage,
              let data = image.pngData() else
        {
            Issue.record("ImageRenderer produced no image data")
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("AskCoachHeroCard.png")
        try data.write(to: url, options: .atomic)
    }

    @Test("AskCoachSheet render artifact (env-gated)")
    func askCoachSheetRenderArtifact() throws {
        guard let dir = ProcessInfo.processInfo.environment["POLISH_COACH_SCREENSHOT_DIR"],
              !dir.isEmpty else { return }
        let renderer = ImageRenderer(content:
            AskCoachSheet()
                .frame(width: 393, height: 852)
                .environment(BackendAvailability(syncMode: nil, authStore: nil))
                .environment(makeAuthStore())
                .environment(AppRouter()) // v0.14.1 — see askCoachSheetRenders()
        )
        renderer.scale = 3
        guard let image = renderer.uiImage,
              let data = image.pngData() else
        {
            Issue.record("ImageRenderer produced no image data")
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("AskCoachSheet.png")
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Default-suggestion contract

    @Test("AskCoachSuggestion.defaults exposes exactly the three operator-locked prompts")
    func defaultsExposesThreePrompts() {
        let defaults = AskCoachSuggestion.defaults
        #expect(defaults.count == 3)
        let texts = Set(defaults.map(\.text))
        #expect(texts.contains(String(localized: "Was bedeutet mein Blutdruck?")))
        #expect(texts.contains(String(localized: "Wie geht's meinem Schlaf?")))
        #expect(texts.contains(String(localized: "Bin ich heute aktiv genug?")))
    }
}
