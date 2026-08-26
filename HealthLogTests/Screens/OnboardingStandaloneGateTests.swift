@testable import HealthLog
import Testing

/// v0.15 — server-connect-mandatory gate.
///
/// Locks the pure routing decision behind `FeatureFlags.standaloneModeAvailable`:
/// when standalone is unavailable, the step after Welcome bypasses the
/// `ModeSelectionStep` fork and goes straight to the server-connect path, so
/// no "use without a server" affordance is ever offered. When available, the
/// fork is shown. We test the pure decision, not the SwiftUI view.
@Suite("Onboarding — standalone availability gate")
struct OnboardingStandaloneGateTests {
    @Test("standalone unavailable → Welcome routes straight to server (no mode fork)")
    func serverMandatorySkipsModeFork() {
        let next = OnboardingFlow.stepAfterWelcome(standaloneModeAvailable: false)
        #expect(next == .serverURL)
        #expect(next != .mode)
    }

    @Test("standalone available → Welcome shows the mode-selection fork")
    func standaloneEnabledShowsModeFork() {
        let next = OnboardingFlow.stepAfterWelcome(standaloneModeAvailable: true)
        #expect(next == .mode)
    }

    @Test("shipping default keeps server-connect mandatory")
    func shippingDefaultIsServerMandatory() {
        // Guards against an accidental flip of the product stance.
        #expect(FeatureFlags.standaloneModeAvailable == false)
        let next = OnboardingFlow.stepAfterWelcome(
            standaloneModeAvailable: FeatureFlags.standaloneModeAvailable
        )
        #expect(next == .serverURL)
    }
}
