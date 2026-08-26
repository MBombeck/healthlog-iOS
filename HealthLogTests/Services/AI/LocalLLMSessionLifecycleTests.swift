import Foundation
@testable import HealthLog
import Testing

/// **Issue #14 — hoisted `LanguageModelSession` lifecycle.** The session is
/// created lazily on the first turn, reused across turns for the store's
/// lifetime (so the model carries the conversation context), and dropped on:
///
/// 1. conversation-clear (`CoachConversationStore.reset()`),
/// 2. logout (`CoachConversationStore.clearOnLogout`),
/// 3. an actual model-availability change (`applyAvailability`).
///
/// The CI simulator cannot construct a real `LanguageModelSession`
/// (FoundationModels resolves `.unsupported` / no model assets), so these
/// tests drive the `cachedSession(create:)` seam the production iOS-26
/// `session()` accessor routes through — identity over a stub object proves
/// the create-once / reuse / reset contract without the framework.
@MainActor
@Suite("LocalLLMService — #14 session lifetime")
struct LocalLLMSessionLifecycleTests {
    /// Plain class stand-in for `LanguageModelSession` — only identity
    /// matters for the caching contract.
    private final class StubSession {}

    // MARK: - Reuse across turns

    @Test("session is created once and the SAME instance is reused across two turns")
    func sessionReusedAcrossTurns() {
        let service = LocalLLMService(forcedAvailability: .available)
        var creations = 0
        let first = service.cachedSession {
            creations += 1
            return StubSession()
        }
        let second = service.cachedSession {
            creations += 1
            return StubSession()
        }
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second), "the hoisted session must survive across turns (#14)")
        #expect(creations == 1, "the create closure must run exactly once")
        #expect(service.hasActiveSession)
    }

    @Test("no session exists before the first turn (lazy creation)")
    func lazyCreation() {
        let service = LocalLLMService(forcedAvailability: .available)
        #expect(service.hasActiveSession == false)
    }

    // MARK: - Reset paths

    @Test("resetSession drops the hoisted session; the next turn creates a fresh one")
    func resetSessionDropsAndRecreates() {
        let service = LocalLLMService(forcedAvailability: .available)
        let first = service.cachedSession { StubSession() }
        service.resetSession()
        #expect(service.hasActiveSession == false)
        let second = service.cachedSession { StubSession() }
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second), "post-reset turns must start a fresh session")
    }

    @Test("conversation-clear (store.reset) drops the on-device session")
    func storeResetDropsSession() {
        let service = LocalLLMService(forcedAvailability: .available)
        _ = service.cachedSession { StubSession() }
        let store = CoachConversationStore(service: service)
        store.reset()
        #expect(
            service.hasActiveSession == false,
            "'Neue Unterhaltung' must not leak the cleared transcript into the model context"
        )
    }

    @Test("logout (store.clearOnLogout) drops the on-device session")
    func logoutDropsSession() {
        let service = LocalLLMService(forcedAvailability: .available)
        _ = service.cachedSession { StubSession() }
        let store = CoachConversationStore(service: service)
        store.clearOnLogout(partition: "user-a")
        #expect(
            service.hasActiveSession == false,
            "the next signed-in user must not inherit the prior user's model context"
        )
    }

    // MARK: - Availability-change invalidation

    @Test("an availability CHANGE drops the session")
    func availabilityChangeDropsSession() {
        let service = LocalLLMService(forcedAvailability: .available)
        _ = service.cachedSession { StubSession() }
        service.applyAvailability(.appleIntelligenceNotEnabled)
        #expect(service.hasActiveSession == false)
        #expect(service.availability == .appleIntelligenceNotEnabled)
    }

    @Test("an UNCHANGED availability re-probe keeps the session (no churn per send)")
    func unchangedAvailabilityKeepsSession() {
        let service = LocalLLMService(forcedAvailability: .available)
        let first = service.cachedSession { StubSession() }
        // `respond` / `streamResponse` re-probe before every turn — a same-value
        // write must NOT recycle the session, or cross-turn context dies.
        service.applyAvailability(.available)
        #expect(service.hasActiveSession)
        let second = service.cachedSession { StubSession() }
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
    }

    @Test("availability round-trip (off → on) yields a fresh session for the new model state")
    func availabilityRoundTripRecreates() {
        let service = LocalLLMService(forcedAvailability: .available)
        let first = service.cachedSession { StubSession() }
        service.applyAvailability(.modelNotReady)
        service.applyAvailability(.available)
        let second = service.cachedSession { StubSession() }
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
        #expect(service.availability == .available)
    }
}
