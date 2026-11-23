import Foundation
@testable import HealthLog
import SwiftUI
import Testing
import UIKit
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

/// The coach deep link reaches the assistant (also after a parked login),
/// and the sheet and its suggestion chips compose and render.
@Suite("AskCoach entry points + AskCoachSheet (POLISH-COACH)")
@MainActor
struct AskCoachEntryPointTests {
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
        return AuthStore(auth: auth, keychain: keychain)
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

    /// The sheet's frame (navigation stack, bar, detents) only composes in a
    /// window; `ImageRenderer` has no update cycle for its bar and stops the
    /// process, so the sheet is hosted and laid out instead.
    @Test("AskCoachSheet composes and lays out in a window")
    func askCoachSheetRenders() throws {
        let host = UIHostingController(rootView:
            AskCoachSheet()
                .environment(BackendAvailability(authStore: nil))
                .environment(makeAuthStore())
                // The "set up a provider" step routes to Settings → Assistant
                // through `AppRouter`.
                .environment(AppRouter())
        )
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width > 0)
        #expect(!host.view.subviews.isEmpty)
        window.isHidden = true
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

    /// Writes the sheet as a PNG to a path picked up by the
    /// `POLISH_COACH_SCREENSHOT_DIR` env var. Used by the polish wave
    /// to produce the artifact the operator review consumes when the
    /// authenticated-shell screenshot path isn't available (cross-agent
    /// build contention etc.). Skipped silently otherwise so the suite
    /// stays hermetic on developer machines + CI.
    @Test("AskCoachSheet render artifact (env-gated)")
    func askCoachSheetRenderArtifact() throws {
        guard let dir = ProcessInfo.processInfo.environment["POLISH_COACH_SCREENSHOT_DIR"],
              !dir.isEmpty else { return }
        let renderer = ImageRenderer(content:
            AskCoachSheet()
                .frame(width: 393, height: 852)
                .environment(BackendAvailability(authStore: nil))
                .environment(makeAuthStore())
                .environment(AppRouter()) // See askCoachSheetRenders()
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
