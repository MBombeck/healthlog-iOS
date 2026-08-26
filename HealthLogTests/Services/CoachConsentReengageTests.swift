import Foundation
@testable import HealthLog
import Testing

/// **b182 (AUDIT-COACH-PARITY F1 + F2) — Coach re-engage + onboarding carry-through.**
///
/// Pins the `AIConsentStore` state machine that backs:
///   - **F1 re-engage:** a prior decline silences the shell auto-gate
///     (`wasDeclined == true`), but the explicit-CTA path
///     (`requestExplicitPrompt`) must still be reachable, and accepting it
///     (a `grant`) must clear the silenced state + flip `aiMode` to `.online`
///     so the Insights Coach surface stops being a dead end.
///   - **F2 carry-through:** the onboarding online pick (`setMode(.online,
///     requestOnlineConsent: false)` with a *configured* provider) records an
///     intent only, and a later `grant` fulfils it (intent cleared, `.online`).
@MainActor
@Suite("Coach consent re-engage + carry-through (b182)")
struct CoachConsentReengageTests {
    private func makeStore() throws -> AIConsentStore {
        let keychain = InMemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test.coach.reengage.\(UUID().uuidString)"))
        return AIConsentStore(keychain: keychain, defaults: defaults)
    }

    // MARK: - F1 — declined Coach has a path back

    @Test("a decline silences the auto-gate but leaves aiMode .none (no surface)")
    func declineSilencesButStaysNone() throws {
        let store = try makeStore()
        store.decline(for: .anthropic)
        #expect(store.wasDeclined(for: .anthropic))
        #expect(store.aiMode == .none)
        #expect(store.hasConsent(for: .anthropic) == false)
    }

    @Test("requestExplicitPrompt bumps the token so the shell can re-present after a decline")
    func explicitPromptReengagesAfterDecline() throws {
        let store = try makeStore()
        store.decline(for: .anthropic)
        let before = store.explicitPromptToken
        // The Insights F1 affordance routes here — the shell's explicit-CTA path
        // bypasses the `wasDeclined` auto-suppression.
        store.requestExplicitPrompt()
        #expect(store.explicitPromptToken == before + 1)
        // Still declined until the user actually accepts — the prompt only re-opens
        // the choice; it doesn't itself grant.
        #expect(store.wasDeclined(for: .anthropic))
        #expect(store.aiMode == .none)
    }

    @Test("granting after a decline clears the silenced state and flips aiMode to .online")
    func grantAfterDeclineClearsAndEnables() throws {
        let store = try makeStore()
        store.decline(for: .anthropic)
        let revBefore = store.revision
        store.grant(for: .anthropic)
        #expect(store.wasDeclined(for: .anthropic) == false) // decline cleared
        #expect(store.aiMode == .online) // Coach appears
        #expect(store.hasConsent(for: .anthropic))
        #expect(store.revision > revBefore) // body re-renders
    }

    // MARK: - F2 — onboarding online pick carries through to a grant

    @Test("onboarding online pick with a configured provider records an intent (stays .none)")
    func onboardingOnlinePickRecordsIntent() throws {
        let store = try makeStore()
        // Mirrors AISourceStep.commit(.online) — onboarding can't host the sheet.
        store.setMode(.online, activeProvider: .anthropic, requestOnlineConsent: false)
        #expect(store.isOnlineIntentPending) // the pick survives navigation
        #expect(store.aiMode == .none) // never an empty box — no grant yet
        #expect(store.wasDeclined(for: .anthropic) == false) // not a decline
    }

    @Test("the carried-through grant fulfils the intent and flips to .online")
    func carryThroughGrantFulfilsIntent() throws {
        let store = try makeStore()
        store.setMode(.online, activeProvider: .anthropic, requestOnlineConsent: false)
        #expect(store.isOnlineIntentPending)
        // The SettingsAIScreen one-shot routes to requestExplicitPrompt → the
        // shell sheet's accept → grant(for:). Simulate the grant landing.
        store.grant(for: .anthropic)
        #expect(store.isOnlineIntentPending == false) // intent fulfilled + cleared
        #expect(store.aiMode == .online) // Coach now visible
        #expect(store.hasConsent(for: .anthropic))
    }

    @Test("the .unconfigured guard holds — no grant against a managed/null provider (GH #24)")
    func unconfiguredNeverGrants() throws {
        let store = try makeStore()
        // The admin/server-managed case resolves .unconfigured; granting it is a
        // no-op (GH #24 is out of scope — we must never claim a working Coach).
        store.grant(for: .unconfigured)
        #expect(store.aiMode == .none)
        #expect(store.isAnyProviderGranted() == false)
    }
}
