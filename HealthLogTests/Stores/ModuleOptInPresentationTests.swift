import Foundation
@testable import HealthLog
import Testing

/// **Audit A-7 — a "turn it on" button that the server would refuse.**
///
/// Labs, Illness and Documents are user-switchable modules, so a switched-off
/// surface offers an enable CTA rather than the operator-gated
/// `FeatureDisabledCard`. That is right for `disabled` — the person's own
/// switch — and wrong for every other off-state. Under `not_granted`,
/// `unavailable` or a state this build cannot name, the module is off because
/// somebody else decided so, and the CTA invites a `PATCH` the server answers
/// with a refusal the person then has to interpret.
///
/// The rule lives in one place for all three screens, and this is it.
@MainActor
@Suite("Audit A-7 — the module-off CTA only where the switch is the person's")
struct ModuleOptInPresentationTests {
    // MARK: - The rule

    @Test("The person's own switch keeps the CTA")
    func disabledKeepsTheCallToAction() {
        #expect(ModuleOptInPresentation.resolve(state: .disabled) == .offerOptIn)
        // …and so does a surface with no verdict at all: no map (server older
        // than v1.38.15), or a key the map does not mention. That is exactly
        // today's behaviour, which A-7 must not change where it knows nothing.
        #expect(ModuleOptInPresentation.resolve(state: nil) == .offerOptIn)
    }

    @Test("Somebody else's decision replaces the CTA with the server's sentence")
    func foreignStatesExplainInstead() {
        for state in [ModuleAccessState.notGranted, .unavailable, .unknown] {
            let resolved = ModuleOptInPresentation.resolve(state: state)
            guard case let .explain(reason) = resolved else {
                Issue.record("\(state) must explain itself instead of offering a switch")
                continue
            }
            #expect(!reason.isEmpty)
            #expect(reason == state.offReason)
            #expect(resolved != .offerOptIn)
        }
    }

    @Test("An enabled module has nothing to explain and nothing to offer")
    func enabledKeepsTodaysRender() {
        // The surface is not in its off branch at all when the module is on;
        // resolving it must not manufacture a reason for the render that is.
        #expect(ModuleOptInPresentation.resolve(state: .enabled) == .offerOptIn)
    }

    // MARK: - Through the gate, for one real screen

    @Test("Labs: not_granted replaces the enable card with the reason")
    func labsSurfaceExplainsInsteadOfInviting() {
        let gate = ModuleGate(modules: ["labs": false], moduleAccess: ["labs": .notGranted])

        let resolved = gate.optInPresentation(.labs)

        guard case let .explain(reason) = resolved else {
            Issue.record("a labs module the grant does not cover must not offer a flip")
            return
        }
        #expect(reason == ModuleAccessState.notGranted.offReason)
    }

    @Test("Labs: the person's own switch still offers the enable card")
    func labsSurfaceKeepsTheCardWhenDisabledByTheViewer() {
        let gate = ModuleGate(modules: ["labs": false], moduleAccess: ["labs": .disabled])
        #expect(gate.optInPresentation(.labs) == .offerOptIn)
    }

    @Test("Illness and Documents resolve through the same helper")
    func theOtherTwoUseTheSameRule() {
        let gate = ModuleGate(
            modules: ["illness": false, "inboundDocuments": false],
            moduleAccess: ["illness": .unavailable, "inboundDocuments": .notGranted]
        )
        #expect(gate.optInPresentation(.illness) != .offerOptIn)
        #expect(gate.optInPresentation(.inboundDocuments) != .offerOptIn)
    }

    @Test("A disagreeing key falls back to the CTA, not to a contradicting reason")
    func disagreementFallsBackToTheCallToAction() {
        // Fix round 1 — `optInPresentation` reads the RECONCILED state, so a
        // stale reason beside a contradicting boolean cannot lock a surface out
        // of its own opt-in either.
        let gate = ModuleGate(modules: ["labs": true], moduleAccess: ["labs": .notGranted])
        #expect(gate.optInPresentation(.labs) == .offerOptIn)
    }
}
