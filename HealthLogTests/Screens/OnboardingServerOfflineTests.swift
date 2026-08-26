@testable import HealthLog
import Testing

/// audit 02 · C-2 — locks the "no hard block on reachability" invariant.
///
/// A server connection stays MANDATORY (a syntactically valid URL is still
/// required), but a momentarily-unreachable server must not trap the user: once
/// the reachability probe fails, onboarding offers a "Continue anyway" path that
/// proceeds with the typed URL and lets SWR/Outbox reconcile when connectivity
/// returns. We test the pure decision that gates that affordance.
@Suite("Onboarding — offline tolerance")
struct OnboardingServerOfflineTests {
    @Test("failed probe + a valid staged URL → offline proceed is offered")
    @MainActor
    func offlineProceedOffered() {
        #expect(ServerURLStep.allowsOfflineProceed(probeFailed: true, hasValidatedURL: true))
    }

    @Test("no proceed path without a validated URL (server requirement intact)")
    @MainActor
    func noProceedWithoutURL() {
        #expect(!ServerURLStep.allowsOfflineProceed(probeFailed: true, hasValidatedURL: false))
    }

    @Test("no offline affordance while the probe has not failed")
    @MainActor
    func noProceedWhenProbeHealthy() {
        #expect(!ServerURLStep.allowsOfflineProceed(probeFailed: false, hasValidatedURL: true))
    }
}
